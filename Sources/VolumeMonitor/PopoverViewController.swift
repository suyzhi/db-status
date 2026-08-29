import AppKit
import Foundation

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
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        view = background
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // NSPopover 以 preferredContentSize 决定弹窗尺寸；
        // 不设置时可能退化为异常大小并导致定位错误。
        preferredContentSize = NSSize(width: 340, height: 300)
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
            stateLabel.stringValue = "菜单栏图标未显示"
            confidenceLabel.stringValue = "打开 系统设置 → 菜单栏，允许 VolumeMonitor 显示后重启应用"
        }
        updateStatusBarPresentation(audio: audio, estimate: estimate, summary: summary)
        monitorButton.title = preferences.monitoringEnabled ? "暂停" : "继续"
    }

    private func buildUI() {
        titleLabel = label("🎧 听力暴露", size: 14, weight: .semibold)
        stateLabel = label("未启动", size: 10, color: .secondaryLabelColor)
        stateLabel.alignment = .right
        deviceLabel = label("输出：—", size: 11, color: .secondaryLabelColor)
        levelLabel = label("—", size: 44, weight: .bold)
        levelLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        unitLabel = label("≈ dBA", size: 12, color: .secondaryLabelColor)
        confidenceLabel = label("需要先为当前设备创建可信档案", size: 11, color: .systemOrange)
        doseLabel = label("过去 7 天声暴露：0%", size: 15, weight: .semibold)
        disclaimerLabel = label("数值为估算，非专业测量。", size: 10, color: .tertiaryLabelColor)

        monitorButton = button("暂停", action: #selector(toggleMonitoring))
        retryButton = button("重试", action: #selector(retryCapture))
        retryButton.isHidden = true

        menuButton = NSPopUpButton(frame: .zero, pullsDown: false)
        menuButton.addItem(withTitle: "更多")
        menuButton.menu?.addItem(.separator())
        let calibrationItem = NSMenuItem(title: "校准…", action: #selector(showCalibration), keyEquivalent: "")
        calibrationItem.target = self
        menuButton.menu?.addItem(calibrationItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menuButton.menu?.addItem(quitItem)
        menuButton.font = .systemFont(ofSize: 11)

        let settingsButton = button("设置", action: #selector(showSettings))

        [titleLabel, stateLabel, deviceLabel, levelLabel, unitLabel,
         confidenceLabel, doseLabel, disclaimerLabel, monitorButton, retryButton,
         menuButton, settingsButton].forEach(view.addSubview)

        titleLabel.frame = NSRect(x: 16, y: 266, width: 180, height: 20)
        stateLabel.frame = NSRect(x: 182, y: 268, width: 142, height: 16)
        levelLabel.frame = NSRect(x: 16, y: 190, width: 150, height: 62)
        unitLabel.frame = NSRect(x: 170, y: 206, width: 70, height: 18)
        confidenceLabel.frame = NSRect(x: 16, y: 172, width: 308, height: 17)
        doseLabel.frame = NSRect(x: 16, y: 138, width: 308, height: 22)
        deviceLabel.frame = NSRect(x: 16, y: 112, width: 308, height: 16)
        monitorButton.frame = NSRect(x: 16, y: 62, width: 92, height: 32)
        retryButton.frame = NSRect(x: 16, y: 62, width: 120, height: 32)
        settingsButton.frame = NSRect(x: 114, y: 62, width: 76, height: 32)
        menuButton.frame = NSRect(x: 196, y: 62, width: 56, height: 32)
        disclaimerLabel.frame = NSRect(x: 16, y: 24, width: 308, height: 16)
    }

    private func updateDevice(_ device: OutputDeviceSnapshot) {
        if let name = device.name, !name.isEmpty {
            deviceLabel.stringValue = "输出：\(name)"
        } else {
            deviceLabel.stringValue = "输出：不可用"
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
            levelLabel.stringValue = String(format: "%.1f", estimate.estimatedLevelDBA)
            confidenceLabel.stringValue = "\(estimate.profileName) · \(estimate.confidence.rawValue)"
            confidenceLabel.textColor = estimate.volumeCalibrationApplied ? .systemBlue : .systemOrange
            stateLabel.stringValue = "实时估算"
            return
        }

        levelLabel.stringValue = "—"
        guard preferences.monitoringEnabled else {
            stateLabel.stringValue = "已暂停"
            confidenceLabel.stringValue = "启用监测后才会读取系统音频"
            return
        }
        if device.isMuted == true {
            stateLabel.stringValue = "系统静音"
            confidenceLabel.stringValue = "静音时不累计声暴露"
            return
        }
        if device.volumeScalar == nil {
            stateLabel.stringValue = "音量不可读"
            confidenceLabel.stringValue = "为避免沿用旧数值，已暂停 dBA 估算"
            return
        }
        if profile == nil || profile?.isConfirmed != true {
            stateLabel.stringValue = "未配置档案"
            confidenceLabel.stringValue = "打开“设置”一键快速设置"
            return
        }

        switch audio.status {
        case .idle:
            stateLabel.stringValue = "未启动"
            confidenceLabel.stringValue = "点击“重试”启动系统音频采集"
        case .starting:
            stateLabel.stringValue = "正在启动"
            confidenceLabel.stringValue = "正在连接 CoreAudio 系统音频 tap"
        case .capturing, .noAudio:
            stateLabel.stringValue = "无音频"
            confidenceLabel.stringValue = "播放声音后开始估算"
        case .noPermission:
            stateLabel.stringValue = "需要权限"
            confidenceLabel.stringValue = "授予系统音频录制权限后点击“重试”"
        case .failed(let message):
            stateLabel.stringValue = "采集异常"
            confidenceLabel.stringValue = message
        }
    }

    private func updateExposure(_ summary: ExposureSummary, currentLevel: Float?) {
        let percent = summary.doseFraction * 100
        doseLabel.stringValue = String(format: "过去 7 天声暴露：%.1f%%", percent)
        let color: NSColor = percent >= 100 ? .systemRed : percent >= 80 ? .systemOrange : .systemBlue
        doseLabel.textColor = color
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
