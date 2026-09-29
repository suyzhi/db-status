import AppKit
import Foundation

/// 弹出面板里的浅色卡片背景；用 updateLayer 保证跟随浅色/深色外观。
private final class PopoverCardView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }
}

@MainActor
final class PopoverViewController: NSViewController {
    private let audioMonitor: SystemAudioLevelMonitor
    private let outputMonitor: OutputDeviceMonitor
    private let profiles: ProfileRepository
    private let exposure: ExposureService
    private let preferences: AppPreferences
    private let calibrationStore: CalibrationStore

    var onShowSettings: (() -> Void)?
    var onShowCalibration: (() -> Void)?
    var onQuit: (() -> Void)?
    var onMonitoringChanged: ((Bool) -> Void)?

    private var titleLabel: NSTextField!
    private var stateLabel: NSTextField!
    private var deviceLabel: NSTextField!
    private var levelLabel: NSTextField!
    private var unitLabel: NSTextField!
    private var confidenceLabel: NSTextField!
    private var doseLabel: NSTextField!
    private var disclaimerLabel: NSTextField!
    private var monitorButton: NSButton!
    private var retryButton: NSButton!
    private var menuButton: NSPopUpButton!

    private static let panelSize = NSSize(width: 348, height: 252)

    private(set) var statusBarLevelText = "--"
    private(set) var statusBarLevelColor = NSColor.systemGray
    private(set) var latestEstimate: LevelEstimate?

    init(
        audioMonitor: SystemAudioLevelMonitor,
        outputMonitor: OutputDeviceMonitor,
        profiles: ProfileRepository,
        exposure: ExposureService,
        preferences: AppPreferences,
        calibrationStore: CalibrationStore
    ) {
        self.audioMonitor = audioMonitor
        self.outputMonitor = outputMonitor
        self.profiles = profiles
        self.exposure = exposure
        self.preferences = preferences
        self.calibrationStore = calibrationStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let background = NSVisualEffectView(
            frame: NSRect(origin: .zero, size: Self.panelSize)
        )
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        view = background
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // NSPopover 以 preferredContentSize 决定弹窗尺寸；
        // 不设置时可能退化为异常大小并导致定位错误。
        preferredContentSize = Self.panelSize
        buildUI()
    }

    func refresh() {
        loadViewIfNeeded()
        let device = outputMonitor.snapshot()
        let profile = profiles.profile(for: device.uid)
        let calibrationResolution = calibrationStore.resolution(
            headphoneProfileID: profile?.id,
            outputDeviceUID: device.uid
        )
        let storedCalibration: CalibrationProfile?
        if case .active(let calibration) = calibrationResolution,
           calibration.frequencyCalibrationUsable {
            storedCalibration = calibration
        } else {
            storedCalibration = nil
        }
        audioMonitor.setCalibrationProfile(storedCalibration)
        let audio = audioMonitor.snapshot()
        // A failed or not-yet-ready FFT must fall back as one complete chain,
        // including the original volume model.
        let runtimeCalibration = audio.frequencyCalibrationApplied ? storedCalibration : nil
        let estimate = audio.hasUsableAudio ? LevelEstimator.estimate(
            volumeScalar: device.volumeScalar,
            isMuted: device.isMuted,
            rmsAWeightedDBFS: audio.rmsAWeightedDBFS,
            profile: profile,
            calibrationProfile: runtimeCalibration,
            frequencyCalibrationApplied: audio.frequencyCalibrationApplied
        ) : nil
        latestEstimate = estimate

        let summary = exposure.ingest(
            levelDBA: preferences.monitoringEnabled ? estimate.map { Double($0.estimatedLevelDBA) } : nil,
            deviceUID: device.uid
        )

        updateDevice(device)
        updateAudio(
            audio,
            device: device,
            profile: profile,
            estimate: estimate
        )
        updateExposure(summary, currentLevel: estimate?.estimatedLevelDBA)
        if MenuBarHostStatus.unhosted {
            // macOS 26+ 系统侧未把本应用的菜单栏项目放上栏（通常需要在
            // 系统设置 → 菜单栏 中允许 VolumeMonitor）。给出明确引导。
            setText(stateLabel, "菜单栏图标未显示")
            setText(confidenceLabel, "打开 系统设置 → 菜单栏，允许 VolumeMonitor 显示后重启应用")
        }
        updateStatusBarPresentation(audio: audio, estimate: estimate, summary: summary)
        monitorButton.title = preferences.monitoringEnabled ? "暂停" : "继续"
        logEstimateDiagnostics(
            audio: audio,
            device: device,
            profile: profile,
            estimate: estimate,
            summary: summary
        )
    }

    private var lastDiagnosticDate = Date.distantPast

    /// 排查「数值不对」类问题时，把内部判断链写进诊断日志（仅 VM_DIAG=1 生效）。
    private func logEstimateDiagnostics(
        audio: AudioLevelSnapshot,
        device: OutputDeviceSnapshot,
        profile: TransducerProfile?,
        estimate: LevelEstimate?,
        summary: ExposureSummary
    ) {
        guard AppDiagnostics.isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticDate) >= 1 else { return }
        lastDiagnosticDate = now

        let estimateText = estimate.map {
            String(
                format: "dBA=%.1f conf=%@ freqApplied=%@ volApplied=%@ absEstimated=%@",
                $0.estimatedLevelDBA,
                $0.confidence.rawValue,
                $0.frequencyCalibrationApplied ? "yes" : "no",
                $0.volumeCalibrationApplied ? "yes" : "no",
                $0.absoluteLevelIsEstimated ? "yes" : "no"
            )
        } ?? "dBA=nil"
        let volumeText = device.volumeScalar.map { String(format: "%.4f", $0) } ?? "-"
        let muteText = device.isMuted.map { String($0) } ?? "-"
        let offsetText = profile?.calibration.map { String(format: "%.1f", $0.offsetDB) } ?? "-"
        AppDiagnostics.log([
            "est \(estimateText)",
            "audio rmsA=\(String(format: "%.1f", audio.rmsAWeightedDBFS)) status=\(audio.status)",
            "device name=\(device.name ?? "-") vol=\(volumeText) muted=\(muteText)",
            "profile id=\(profile?.id.uuidString ?? "-") offset=\(offsetText)",
            "dose=\(String(format: "%.2f%%", summary.doseFraction * 100)) monitoring=\(preferences.monitoringEnabled)"
        ].joined(separator: " | "))
    }

    // MARK: - 布局

    private func buildUI() {
        titleLabel = label("🎧 听力暴露", size: 13, weight: .semibold)
        stateLabel = label("未启动", size: 11, color: .secondaryLabelColor)
        stateLabel.alignment = .right
        deviceLabel = label("输出：—", size: 11, color: .secondaryLabelColor)
        levelLabel = label("--", size: 40, weight: .semibold, color: .tertiaryLabelColor)
        levelLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        unitLabel = label("≈ dBA", size: 13, weight: .medium, color: .secondaryLabelColor)
        confidenceLabel = label("需要先为当前设备创建可信档案", size: 11, color: .systemOrange)
        doseLabel = label("过去 7 天声暴露：0%", size: 15, weight: .semibold)
        disclaimerLabel = label("数值为估算，非专业测量。", size: 10, color: .tertiaryLabelColor)

        monitorButton = button("暂停", action: #selector(toggleMonitoring))
        retryButton = button("重试", action: #selector(retryCapture))
        retryButton.isHidden = true

        menuButton = NSPopUpButton(frame: .zero, pullsDown: false)
        menuButton.addItem(withTitle: "更多")
        menuButton.menu?.addItem(.separator())
        let calibrationItem = NSMenuItem(
            title: "校准…",
            action: #selector(showCalibration),
            keyEquivalent: ""
        )
        calibrationItem.target = self
        menuButton.menu?.addItem(calibrationItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menuButton.menu?.addItem(quitItem)
        menuButton.font = .systemFont(ofSize: 11)
        menuButton.controlSize = .regular

        let settingsButton = button("设置", action: #selector(showSettings))

        let card = PopoverCardView()
        doseLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(doseLabel)
        NSLayoutConstraint.activate([
            doseLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            doseLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            doseLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            doseLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let header = row([titleLabel, flexibleSpacer(), stateLabel], alignment: .firstBaseline)
        let levelRow = row([levelLabel, unitLabel, flexibleSpacer()], alignment: .firstBaseline, spacing: 6)
        let buttonRow = row([
            monitorButton,
            retryButton,
            settingsButton,
            menuButton,
            flexibleSpacer()
        ], spacing: 8)

        let separatorView = separator()
        let stack = NSStackView(views: [
            header,
            separatorView,
            levelRow,
            confidenceLabel,
            card,
            deviceLabel,
            buttonRow,
            disclaimerLabel
        ])
        stack.orientation = .vertical
        // 用 .leading 而不是 .width：.width 会让 NSStackView 把标签文字改成右对齐。
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(9, after: header)
        stack.setCustomSpacing(6, after: levelRow)
        stack.setCustomSpacing(12, after: deviceLabel)
        stack.setCustomSpacing(8, after: confidenceLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // 需要通栏的行显式拉满宽度。
        for fullWidthView in [header, separatorView, card, buttonRow] {
            fullWidthView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -14)
        ])
    }

    private func row(
        _ views: [NSView],
        alignment: NSLayoutConstraint.Attribute = .centerY,
        spacing: CGFloat = 8
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        return button
    }

    /// 明确显示当前走的是哪条估算路径。此前无论校准是否生效都显示"已校准"
    /// （只要档案里有校准偏移记录），因此无法分辨 EM258 曲线是否真的在起作用。
    private static func calibrationPathText(
        _ estimate: LevelEstimate,
        audio: AudioLevelSnapshot
    ) -> String {
        if estimate.volumeCalibrationApplied { return "EM258 校准生效" }
        if estimate.frequencyCalibrationApplied { return "仅频响校准生效" }
        if let reason = audio.calibrationFallbackReason, !reason.isEmpty {
            return "模型估算 · \(reason)"
        }
        return "模型估算 · \(estimate.confidence.rawValue)"
    }

    /// 10 Hz 刷新时只在内容真的变化时写 NSTextField，避免无谓的重绘。
    private func setText(_ field: NSTextField, _ value: String) {
        if field.stringValue != value { field.stringValue = value }
    }

    private func setTextColor(_ field: NSTextField, _ color: NSColor) {
        if field.textColor != color { field.textColor = color }
    }

    // MARK: - 内容更新

    private func updateDevice(_ device: OutputDeviceSnapshot) {
        if let name = device.name, !name.isEmpty {
            setText(deviceLabel, "输出：\(name)")
        } else {
            setText(deviceLabel, "输出：不可用")
        }
    }

    private func updateAudio(
        _ audio: AudioLevelSnapshot,
        device: OutputDeviceSnapshot,
        profile: TransducerProfile?,
        estimate: LevelEstimate?
    ) {
        let needsRetry: Bool
        switch audio.status {
        case .noPermission, .failed: needsRetry = true
        default: needsRetry = false
        }
        retryButton.isHidden = !needsRetry
        monitorButton.isHidden = needsRetry

        if let estimate {
            setTextColor(levelLabel, .labelColor)
            setText(levelLabel, String(format: "%.1f", estimate.estimatedLevelDBA))
            setText(confidenceLabel, "\(estimate.profileName) · \(Self.calibrationPathText(estimate, audio: audio))")
            setTextColor(confidenceLabel, estimate.volumeCalibrationApplied ? .systemBlue : .systemOrange)
            setText(stateLabel, "实时估算")
            return
        }

        setTextColor(levelLabel, .tertiaryLabelColor)
        setText(levelLabel, "--")
        guard preferences.monitoringEnabled else {
            setText(stateLabel, "已暂停")
            setText(confidenceLabel, "启用监测后才会读取系统音频")
            return
        }
        if device.isMuted == true {
            setText(stateLabel, "系统静音")
            setText(confidenceLabel, "静音时不累计声暴露")
            return
        }
        if device.volumeScalar == nil {
            setText(stateLabel, "音量不可读")
            setText(confidenceLabel, "为避免沿用旧数值，已暂停 dBA 估算")
            return
        }
        if profile == nil || profile?.isConfirmed != true {
            setText(stateLabel, "未配置档案")
            setText(confidenceLabel, "打开“设置”一键快速设置")
            return
        }

        switch audio.status {
        case .idle:
            setText(stateLabel, "未启动")
            setText(confidenceLabel, "点击“重试”启动系统音频采集")
        case .starting:
            setText(stateLabel, "正在启动")
            setText(confidenceLabel, "正在连接 CoreAudio 系统音频 tap")
        case .capturing, .noAudio:
            setText(stateLabel, "无音频")
            setText(confidenceLabel, "播放声音后开始估算")
        case .noPermission:
            setText(stateLabel, "需要权限")
            setText(confidenceLabel, "授予系统音频录制权限后点击“重试”")
        case .failed(let message):
            setText(stateLabel, "采集异常")
            setText(confidenceLabel, message)
        }
    }

    private func updateExposure(_ summary: ExposureSummary, currentLevel: Float?) {
        let percent = summary.doseFraction * 100
        setText(doseLabel, String(format: "过去 7 天声暴露：%.1f%%", percent))
        let color: NSColor = percent >= 100 ? .systemRed : percent >= 80 ? .systemOrange : .systemBlue
        setTextColor(doseLabel, color)
        statusBarLevelColor = color
    }

    private func updateStatusBarPresentation(
        audio: AudioLevelSnapshot,
        estimate: LevelEstimate?,
        summary: ExposureSummary
    ) {
        switch preferences.statusBarDisplayMode {
        case .estimatedDBA:
            statusBarLevelText = estimate.map { "\(Int($0.estimatedLevelDBA.rounded()))" } ?? "--"
        case .sevenDayDose:
            statusBarLevelText = "\(Int(min(summary.doseFraction * 100, 999).rounded()))%"
        case .rmsDBFS:
            statusBarLevelText = audio.hasUsableAudio
                ? "\(Int(audio.rmsAWeightedDBFS.rounded()))"
                : "--"
        }
        if statusBarLevelText == "--" { statusBarLevelColor = .systemGray }
    }

    // MARK: - 动作

    @objc private func toggleMonitoring() {
        onMonitoringChanged?(!preferences.monitoringEnabled)
    }

    @objc private func retryCapture() {
        onMonitoringChanged?(true)
    }

    @objc private func showSettings() {
        onShowSettings?()
    }

    @objc private func showCalibration() {
        onShowCalibration?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
