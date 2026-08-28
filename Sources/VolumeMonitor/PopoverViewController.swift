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
    private var volumeLabel: NSTextField!
    private var levelLabel: NSTextField!
    private var unitLabel: NSTextField!
    private var confidenceLabel: NSTextField!
    private var calibrationLabel: NSTextField!
    private var rmsLabel: NSTextField!
    private var peakLabel: NSTextField!
    private var doseLabel: NSTextField!
    private var doseDetailLabel: NSTextField!
    private var doseTrack: NSView!
    private var doseFill: NSView!
    private var disclaimerLabel: NSTextField!
    private var monitorButton: NSButton!
    private var retryButton: NSButton!

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 430))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        updateCalibrationStatus(
            audio: audio,
            resolution: calibrationResolution
        )
        updateAudio(
            audio,
            device: device,
            profile: profile,
            estimate: estimate,
            calibrationResolution: calibrationResolution
        )
        updateExposure(summary, currentLevel: estimate?.estimatedLevelDBA)
        updateStatusBarPresentation(audio: audio, estimate: estimate, summary: summary)
        monitorButton.title = preferences.monitoringEnabled ? "暂停监测" : "启用监测"
    }

    private func buildUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel = label("🎧 听力暴露监测", size: 16, weight: .semibold)
        stateLabel = label("未启动", size: 11, color: .secondaryLabelColor)
        stateLabel.alignment = .right
        deviceLabel = label("输出设备：—", size: 12, weight: .medium)
        volumeLabel = label("系统音量：—", size: 11, color: .secondaryLabelColor)
        levelLabel = label("—", size: 46, weight: .bold)
        levelLabel.font = .monospacedDigitSystemFont(ofSize: 46, weight: .bold)
        unitLabel = label("≈ dBA", size: 13, color: .secondaryLabelColor)
        confidenceLabel = label("需要先为当前设备创建可信档案", size: 11, color: .systemOrange)
        calibrationLabel = label("○ 未校准 · 当前使用标准估算模式", size: 10, color: .secondaryLabelColor)
        rmsLabel = label("RMS(A) -- dBFS", size: 11, color: .secondaryLabelColor)
        peakLabel = label("Peak -- dBFS", size: 11, color: .secondaryLabelColor)
        peakLabel.alignment = .right
        doseLabel = label("过去 7 天声暴露：0%", size: 14, weight: .semibold)
        doseDetailLabel = label("等待可信估算", size: 11, color: .secondaryLabelColor)
        disclaimerLabel = label("数值为估算，不是专业声级计或医疗结果。", size: 10, color: .tertiaryLabelColor)

        doseTrack = NSView()
        doseTrack.wantsLayer = true
        doseTrack.layer?.cornerRadius = 4
        doseTrack.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        doseFill = NSView()
        doseFill.wantsLayer = true
        doseFill.layer?.cornerRadius = 3
        doseFill.layer?.backgroundColor = NSColor.systemBlue.cgColor
        doseTrack.addSubview(doseFill)

        monitorButton = button("启用监测", action: #selector(toggleMonitoring))
        retryButton = button("重试", action: #selector(retryCapture))
        let settingsButton = button("设置与档案…", action: #selector(showSettings))
        let calibrationButton = button("校准…", action: #selector(showCalibration))
        let quitButton = button("退出", action: #selector(quit))

        [titleLabel, stateLabel, deviceLabel, volumeLabel, levelLabel, unitLabel,
         confidenceLabel, calibrationLabel, rmsLabel, peakLabel, doseLabel, doseDetailLabel,
         doseTrack, disclaimerLabel, monitorButton, retryButton, calibrationButton, settingsButton,
         quitButton].forEach(view.addSubview)

        titleLabel.frame = NSRect(x: 18, y: 390, width: 190, height: 24)
        stateLabel.frame = NSRect(x: 210, y: 392, width: 132, height: 18)
        deviceLabel.frame = NSRect(x: 18, y: 354, width: 324, height: 19)
        volumeLabel.frame = NSRect(x: 18, y: 333, width: 324, height: 17)
        levelLabel.frame = NSRect(x: 18, y: 264, width: 180, height: 60)
        unitLabel.frame = NSRect(x: 200, y: 277, width: 80, height: 20)
        confidenceLabel.frame = NSRect(x: 18, y: 244, width: 324, height: 18)
        calibrationLabel.frame = NSRect(x: 18, y: 226, width: 324, height: 16)
        rmsLabel.frame = NSRect(x: 18, y: 205, width: 150, height: 18)
        peakLabel.frame = NSRect(x: 192, y: 205, width: 150, height: 18)
        doseLabel.frame = NSRect(x: 18, y: 175, width: 324, height: 22)
        doseTrack.frame = NSRect(x: 18, y: 156, width: 324, height: 9)
        doseDetailLabel.frame = NSRect(x: 18, y: 128, width: 324, height: 18)
        disclaimerLabel.frame = NSRect(x: 18, y: 100, width: 324, height: 18)
        monitorButton.frame = NSRect(x: 18, y: 54, width: 88, height: 30)
        retryButton.frame = NSRect(x: 108, y: 54, width: 52, height: 30)
        calibrationButton.frame = NSRect(x: 162, y: 54, width: 60, height: 30)
        settingsButton.frame = NSRect(x: 224, y: 54, width: 76, height: 30)
        quitButton.frame = NSRect(x: 304, y: 54, width: 38, height: 30)
    }

    private func updateDevice(_ device: OutputDeviceSnapshot) {
        deviceLabel.stringValue = "输出设备：\(device.name ?? "不可用")"
        if device.isMuted == true {
            volumeLabel.stringValue = "系统音量：已静音"
        } else if let volume = device.volumeScalar {
            volumeLabel.stringValue = "系统音量：\(Int((volume * 100).rounded()))%"
        } else {
            volumeLabel.stringValue = "系统音量：设备不提供可读数值"
        }
    }

    private func updateAudio(
        _ audio: AudioLevelSnapshot,
        device: OutputDeviceSnapshot,
        profile: TransducerProfile?,
        estimate: LevelEstimate?,
        calibrationResolution: CalibrationResolution
    ) {
        rmsLabel.stringValue = formatDBFS("RMS(A)", audio.rmsAWeightedDBFS)
        peakLabel.stringValue = formatDBFS("Peak", audio.peakUnweightedDBFS)
        retryButton.isHidden = false

        if let estimate {
            levelLabel.stringValue = String(format: "%.1f", estimate.estimatedLevelDBA)
            confidenceLabel.stringValue = "\(estimate.profileName) · \(estimate.confidence.rawValue)"
            confidenceLabel.textColor = estimate.volumeCalibrationApplied ? .systemBlue : .systemOrange
            stateLabel.stringValue = "实时估算"
            retryButton.isHidden = true
            return
        }

        levelLabel.stringValue = "—"
        guard preferences.monitoringEnabled else {
            stateLabel.stringValue = "已暂停"
            confidenceLabel.stringValue = "启用监测后才会读取系统音频"
            retryButton.isHidden = true
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
            confidenceLabel.stringValue = "打开“设置与档案”后绑定当前设备"
            return
        }

        switch calibrationResolution {
        case .outputMismatch:
            confidenceLabel.stringValue = "当前输出设备与校准设备不一致"
        case .invalid(let reason):
            confidenceLabel.stringValue = "校准不可用：\(reason)；使用标准估算模式"
        case .active where !audio.frequencyCalibrationApplied:
            confidenceLabel.stringValue = audio.calibrationFallbackReason
                ?? "FFT 校准正在准备；暂用标准估算模式"
        case .active, .notCalibrated:
            break
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

    private func updateCalibrationStatus(
        audio: AudioLevelSnapshot,
        resolution: CalibrationResolution
    ) {
        if let warning = calibrationStore.lastLoadWarning {
            calibrationLabel.stringValue = "○ \(warning)"
            calibrationLabel.textColor = .systemOrange
            return
        }
        switch resolution {
        case .active where audio.frequencyCalibrationApplied:
            calibrationLabel.stringValue = "● 频响实测 · 音量曲线实测 · 绝对 SPL 估算"
            calibrationLabel.textColor = .systemBlue
        case .active:
            calibrationLabel.stringValue = "● 已校准配置 · FFT 准备中，暂用标准估算"
            calibrationLabel.textColor = .systemOrange
        case .outputMismatch:
            calibrationLabel.stringValue = "○ 当前输出设备与校准设备不一致"
            calibrationLabel.textColor = .systemOrange
        case .invalid(let reason):
            calibrationLabel.stringValue = "○ 校准不可用：\(reason)"
            calibrationLabel.textColor = .systemOrange
        case .notCalibrated:
            calibrationLabel.stringValue = "○ 未校准 · 当前使用标准估算模式"
            calibrationLabel.textColor = .secondaryLabelColor
        }
    }

    private func updateExposure(_ summary: ExposureSummary, currentLevel: Float?) {
        let percent = summary.doseFraction * 100
        doseLabel.stringValue = String(format: "过去 7 天声暴露：%.1f%%", percent)
        let color: NSColor = percent >= 100 ? .systemRed : percent >= 80 ? .systemOrange : .systemBlue
        doseLabel.textColor = color
        doseFill.layer?.backgroundColor = color.cgColor
        let fraction = min(max(summary.doseFraction, 0), 1)
        doseFill.frame = NSRect(x: 1, y: 1, width: max(2, 322 * fraction), height: 7)
        statusBarLevelColor = color

        var details: [String] = []
        if let laeq = summary.sessionLAeq {
            details.append(String(format: "本次 LAeq %.1f dBA", laeq))
        }
        if currentLevel != nil,
           let remaining = summary.remainingTimeAtCurrentLevel {
            details.append("当前水平约剩 \(formatDuration(remaining))")
        }
        doseDetailLabel.stringValue = details.isEmpty ? "等待可信估算" : details.joined(separator: " · ")
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

    private func formatDBFS(_ prefix: String, _ value: Float) -> String {
        value > -95 ? String(format: "\(prefix) %.0f dBFS", value) : "\(prefix) -- dBFS"
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds <= 0 { return "0 分钟" }
        if seconds < 60 { return "<1 分钟" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟" }
        if seconds < 86_400 { return String(format: "%.1f 小时", seconds / 3_600) }
        return String(format: "%.1f 天", seconds / 86_400)
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
        button.font = .systemFont(ofSize: 11)
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
