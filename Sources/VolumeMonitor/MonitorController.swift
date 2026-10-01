import AppKit
import Combine
import Foundation

/// 弹窗与主窗口共用的实时状态。由 MonitorController 每次刷新时更新，只在值变化时发布。
@MainActor
final class LiveMonitorModel: ObservableObject {
    enum NoticeAction: Equatable {
        case quickSetup, retry, resume
    }

    struct Notice: Equatable {
        var text: String
        var action: NoticeAction?
    }

    /// 实时声级（Fast 计权，随刷新频率变化），用于电平条和迷你波形。
    @Published var level: Double?
    /// 显示用数字：每秒更新一次的 1 秒等效声级（LAeq,1s），像声级计一样读得清。
    @Published var displayLevel: Double?
    @Published var stateText = "正在启动"
    @Published var isActive = false
    @Published var deviceName = "—"
    @Published var subtitle = ""
    @Published var notice: Notice?
    @Published var warning: String?
    @Published var doseFraction = 0.0
    @Published var mode: ExposureMode = .adult
    @Published var todaySeconds = 0.0
    @Published var todayLevel: Double?
    @Published var days: [DailyExposureStat] = []
    @Published var samples: [LevelSample] = []
    @Published var monitoringEnabled = true

    var zone: LevelZone? { displayLevel.map(LevelZone.init(dBA:)) }

    var doseStatus: String {
        switch doseFraction {
        case ..<0.5: "额度充裕"
        case ..<0.8: "已用过半"
        case ..<1: "接近上限"
        default: "已超出参考额度"
        }
    }

    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<LiveMonitorModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// 每次刷新：读设备与音频 → 估算 dBA → 累计声暴露 → 更新界面模型和菜单栏文字。
@MainActor
final class MonitorController {
    let model = LiveMonitorModel()

    private let audioMonitor: SystemAudioLevelMonitor
    private let appAttribution: AppAudioAttributionMonitor
    private let outputMonitor: OutputDeviceMonitor
    private let profiles: ProfileRepository
    private let exposure: ExposureService
    private let preferences: AppPreferences
    private let calibrationStore: CalibrationStore

    private(set) var statusBarLevelText = "--"
    private(set) var statusBarLevelColor = NSColor.systemGray
    private(set) var latestEstimate: LevelEstimate?

    private var lastDiagnosticDate = Date.distantPast
    private var lastStatsDate = Date.distantPast
    private var cachedFallbackCompensation: (id: UUID, value: Float)?
    private static let sparklineWindow: TimeInterval = 30
    /// 显示数字的更新周期，以及这段时间内实时声级的能量累加。
    private static let displayInterval: TimeInterval = 1
    private var displayWindowStart = Date.distantPast
    private var displayEnergy = 0.0
    private var displayCount = 0

    init(
        audioMonitor: SystemAudioLevelMonitor,
        appAttribution: AppAudioAttributionMonitor,
        outputMonitor: OutputDeviceMonitor,
        profiles: ProfileRepository,
        exposure: ExposureService,
        preferences: AppPreferences,
        calibrationStore: CalibrationStore
    ) {
        self.audioMonitor = audioMonitor
        self.appAttribution = appAttribution
        self.outputMonitor = outputMonitor
        self.profiles = profiles
        self.exposure = exposure
        self.preferences = preferences
        self.calibrationStore = calibrationStore
    }

    func refresh(now: Date = .now) {
        let device = outputMonitor.snapshot()
        let profile = profiles.profile(for: device.uid)
        let activeCalibration: CalibrationProfile?
        if case .active(let calibration) = calibrationStore.resolution(
            headphoneProfileID: profile?.id,
            outputDeviceUID: device.uid
        ) {
            activeCalibration = calibration
        } else {
            activeCalibration = nil
        }
        audioMonitor.setCalibrationProfile(
            activeCalibration?.frequencyCalibrationUsable == true ? activeCalibration : nil
        )
        let audio = audioMonitor.snapshot()
        let compensation = fallbackCompensation(for: activeCalibration)
        func estimate(rmsDBFS: Float) -> LevelEstimate? {
            LevelEstimator.estimate(
                volumeScalar: device.volumeScalar,
                isMuted: device.isMuted,
                rmsAWeightedDBFS: rmsDBFS,
                profile: profile,
                calibrationProfile: activeCalibration,
                frequencyCalibrationApplied: audio.frequencyCalibrationApplied,
                frequencyFallbackCompensationDB: compensation
            )
        }
        // 音量曲线与绝对锚点不依赖 FFT 引擎：引擎没跑起来时仍用实测音量曲线，
        // 只把频响加权换成保守补偿（宁可高估，不再整条链退回估算曲线）。
        let current = audio.hasUsableAudio ? estimate(rmsDBFS: audio.rmsAWeightedDBFS) : nil
        latestEstimate = current

        // 声暴露按音频线程累加的真实能量积分；显示值（Fast 计权）只用于界面。
        let loudness = audioMonitor.drainLoudness()
        let levelFor: (Double) -> Double? = { meanSquare in
            guard meanSquare > 0 else { return nil }
            return estimate(rmsDBFS: Float(10 * log10(meanSquare))).map { Double($0.estimatedLevelDBA) }
        }
        let summary = exposure.ingest(
            levelDBA: preferences.monitoringEnabled ? levelFor(loudness.meanSquare) : nil,
            peakDBA: levelFor(loudness.maxFastMeanSquare),
            duration: loudness.activeSeconds,
            deviceUID: device.uid,
            currentLevelDBA: current.map { Double($0.estimatedLevelDBA) },
            appEnergy: appAttribution.drain()
        )

        updateModel(
            device: device,
            profile: profile,
            audio: audio,
            estimate: current,
            summary: summary,
            now: now
        )
        updateStatusBar(audio: audio, estimate: current, summary: summary)
        logDiagnostics(audio: audio, device: device, profile: profile, estimate: current, summary: summary)
    }

    // MARK: - 界面模型

    private func updateModel(
        device: OutputDeviceSnapshot,
        profile: TransducerProfile?,
        audio: AudioLevelSnapshot,
        estimate: LevelEstimate?,
        summary: ExposureSummary,
        now: Date
    ) {
        let level = estimate.map { Double($0.estimatedLevelDBA) }
        model.set(\.level, level)
        updateDisplayLevel(level, now: now)
        model.set(\.monitoringEnabled, preferences.monitoringEnabled)
        model.set(\.mode, preferences.exposureMode)
        model.set(\.deviceName, device.name ?? "无输出设备")
        model.set(\.subtitle, Self.subtitle(profile: profile, estimate: estimate))
        model.set(\.doseFraction, summary.doseFraction)

        var samples = model.samples.filter { now.timeIntervalSince($0.date) <= Self.sparklineWindow + 1 }
        samples.append(LevelSample(date: now, level: level))
        model.samples = samples

        if now.timeIntervalSince(lastStatsDate) >= 15 {
            lastStatsDate = now
            reloadDailyStats(now: now)
        }

        let state = Self.state(
            device: device,
            profile: profile,
            audio: audio,
            estimate: estimate,
            monitoringEnabled: preferences.monitoringEnabled
        )
        model.set(\.stateText, state.text)
        model.set(\.isActive, state.active)
        var notice = state.notice
        if MenuBarHostStatus.unhosted {
            notice = .init(text: "菜单栏图标未显示：打开 系统设置 → 菜单栏，允许 VolumeMonitor 后重启应用", action: nil)
        }
        model.set(\.notice, notice)

        var warning: String?
        if let estimate, estimate.volumeCalibrationApplied, !estimate.frequencyCalibrationApplied {
            warning = String(format: "频响校准未生效，已按保守值 +%.1f dB 估算", estimate.frequencyFallbackCompensationDB)
        } else if estimate != nil, !(estimate?.volumeCalibrationApplied ?? false),
                  let reason = audio.calibrationFallbackReason, !reason.isEmpty {
            warning = reason
        }
        model.set(\.warning, warning)
    }

    /// 大数字每秒更新一次，取这 1 秒内实时声级的能量平均；没有声音时立刻显示“--”。
    private func updateDisplayLevel(_ level: Double?, now: Date) {
        guard let level else {
            displayEnergy = 0
            displayCount = 0
            displayWindowStart = now
            model.set(\.displayLevel, nil)
            return
        }
        displayEnergy += pow(10, level / 10)
        displayCount += 1
        let due = now.timeIntervalSince(displayWindowStart) >= Self.displayInterval
        guard due || model.displayLevel == nil else { return }
        model.set(\.displayLevel, 10 * log10(displayEnergy / Double(displayCount)))
        displayEnergy = 0
        displayCount = 0
        displayWindowStart = now
    }

    /// 弹窗打开或数据刚变化时调用：重算最近 7 天和今天的统计。
    func reloadDailyStats(now: Date = .now) {
        lastStatsDate = now
        let days = exposure.dailyStats(days: 7, now: now)
        model.set(\.days, days)
        model.set(\.todaySeconds, days.last?.seconds ?? 0)
        model.set(\.todayLevel, days.last?.equivalentLevelDBA)
    }

    private static func subtitle(profile: TransducerProfile?, estimate: LevelEstimate?) -> String {
        guard let profile else { return "未配置档案" }
        guard let estimate else { return profile.name }
        let calibration: String
        switch estimate.confidence {
        case .measuredAbsolute: calibration = "已校准"
        case .relativeCalibrated: calibration = "已校准 · 规格绝对值"
        case .calibrated: calibration = "手动校准"
        case .specified, .estimatedCurve: calibration = "规格估算"
        }
        return "\(profile.name) · \(calibration)"
    }

    private static func state(
        device: OutputDeviceSnapshot,
        profile: TransducerProfile?,
        audio: AudioLevelSnapshot,
        estimate: LevelEstimate?,
        monitoringEnabled: Bool
    ) -> (text: String, active: Bool, notice: LiveMonitorModel.Notice?) {
        if estimate != nil { return ("监测中", true, nil) }
        guard monitoringEnabled else {
            return ("已暂停", false, .init(text: "监测已暂停，不读取系统音频，也不累计声暴露", action: .resume))
        }
        if device.isMuted == true {
            return ("系统静音", false, .init(text: "静音时不累计声暴露", action: nil))
        }
        if device.volumeScalar == nil {
            return ("音量不可读", false, .init(text: "读不到系统音量，为避免沿用旧数值已暂停估算", action: nil))
        }
        if profile == nil || profile?.isConfirmed != true {
            return ("未配置", false, .init(text: "为当前设备做一次快速设置后开始估算", action: .quickSetup))
        }
        switch audio.status {
        case .idle:
            return ("未启动", false, .init(text: "系统音频采集未启动", action: .retry))
        case .starting:
            return ("正在启动", false, nil)
        case .capturing, .noAudio:
            return ("无音频", true, .init(text: "没有正在播放的声音，播放后开始估算", action: nil))
        case .noPermission:
            return ("需要权限", false, .init(text: "请在系统设置中允许录制系统音频，然后重试", action: .retry))
        case .failed(let message):
            return ("采集异常", false, .init(text: message, action: .retry))
        }
    }

    // MARK: - 菜单栏

    private func updateStatusBar(
        audio: AudioLevelSnapshot,
        estimate: LevelEstimate?,
        summary: ExposureSummary
    ) {
        let percent = summary.doseFraction * 100
        statusBarLevelColor = percent >= 100 ? .systemRed : percent >= 80 ? .systemOrange : .systemBlue
        switch preferences.statusBarDisplayMode {
        case .estimatedDBA:
            statusBarLevelText = estimate == nil
                ? "--"
                : model.displayLevel.map { "\(Int($0.rounded()))" } ?? "--"
        case .sevenDayDose:
            statusBarLevelText = "\(Int(min(percent, 999).rounded()))%"
        case .rmsDBFS:
            statusBarLevelText = audio.hasUsableAudio ? "\(Int(audio.rmsAWeightedDBFS.rounded()))" : "--"
        }
        if statusBarLevelText == "--" { statusBarLevelColor = .systemGray }
    }

    /// 每个校准档案只算一次（要扫一遍 A 加权频响）。
    private func fallbackCompensation(for calibration: CalibrationProfile?) -> Float {
        guard let calibration else { return 0 }
        if let cached = cachedFallbackCompensation, cached.id == calibration.id {
            return cached.value
        }
        let value = Float(calibration.frequencyFallbackCompensationDB)
        cachedFallbackCompensation = (calibration.id, value)
        return value
    }

    /// 排查「数值不对」类问题时，把内部判断链写进诊断日志（仅 VM_DIAG=1 生效）。
    private func logDiagnostics(
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
}
