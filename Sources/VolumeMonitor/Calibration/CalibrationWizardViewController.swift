import AppKit
import Combine
import SwiftUI

enum CalibrationWizardStep: Int, CaseIterable {
    case microphone = 1
    case installation
    case frequency
    case volume
    case validation
    case absolute

    var title: String {
        switch self {
        case .microphone: "检测 EM258"
        case .installation: "固定耳机和麦克风"
        case .frequency: "自动频响测试"
        case .volume: "自动音量测试"
        case .validation: "验证"
        case .absolute: "手机对标"
        }
    }
}

enum CalibrationMicrophoneStartTrigger: Sendable, Equatable {
    case windowPreparation
    case deviceSelection
    case manualDetectionButton

    var startsCapture: Bool { self == .manualDetectionButton }
}

@MainActor
final class CalibrationWizardViewModel: ObservableObject {
    @Published var step: CalibrationWizardStep = .microphone
    @Published var selectedInputUID = ""
    @Published var progressMessage = "正在查找音频输入设备…"
    @Published var progressFraction = 0.0
    @Published var errorMessage = ""
    @Published var isBusy = false
    @Published var frequencyResult: FrequencySweepResult?
    @Published var volumeResult: VolumeSweepResult?
    @Published var validationResult: RelativeValidationResult?
    @Published var acousticMeasurement: AcousticReferenceMeasurement?
    @Published var phoneReadingText = ""
    @Published var phoneDescription = "iPhone · NIOSH SLM"
    @Published var saved = false

    let microphone = CalibrationMicrophoneMonitor()
    private let toneGenerator = CalibrationToneGenerator()
    private let noisePlayer = CalibrationNoisePlayer()
    private let outputMonitor: OutputDeviceMonitor
    private let profiles: ProfileRepository
    private let calibrationStore: CalibrationStore
    private lazy var measurementEngine = CalibrationMeasurementEngine(
        microphone: microphone,
        toneGenerator: toneGenerator,
        outputMonitor: outputMonitor
    )
    private var activeTask: Task<Void, Never>?
    private var prepared = false

    var onSaved: (() -> Void)?

    init(
        outputMonitor: OutputDeviceMonitor,
        profiles: ProfileRepository,
        calibrationStore: CalibrationStore
    ) {
        self.outputMonitor = outputMonitor
        self.profiles = profiles
        self.calibrationStore = calibrationStore
    }

    var outputDevice: OutputDeviceSnapshot { outputMonitor.snapshot() }
    var headphoneProfile: TransducerProfile? { profiles.profile(for: outputDevice.uid) }
    var currentQuality: CalibrationQuality? {
        guard let frequencyResult, let volumeResult, let validationResult else { return nil }
        let stabilities = frequencyResult.points.map(\.stabilityDB)
            + volumeResult.points.map(\.stabilityDB)
        return CalibrationQuality(
            averageStabilityDB: stabilities.isEmpty ? 0 : stabilities.reduce(0, +) / Double(stabilities.count),
            maximumStabilityDB: stabilities.max() ?? 0,
            minimumSNRDB: min(frequencyResult.minimumSNRDB, volumeResult.minimumSNRDB),
            relativeValidationErrorDB: validationResult.absoluteErrorDB
        )
    }
    var canSaveCalibration: Bool {
        !saved && CalibrationValidationPolicy.canSave(
            relativeValidationErrorDB: validationResult?.absoluteErrorDB
        )
    }

    var speakerAvailable: Bool { CalibrationNoisePlayer.builtInSpeakerDeviceID() != nil }

    var phoneReadingDBA: Double? {
        let text = phoneReadingText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "，", with: ".")
        guard let value = Double(text), (40...110).contains(value) else { return nil }
        return value
    }

    /// 手机对标得到的：参考音量下数字 RMS 0 dBFS 的 1 kHz 信号在耳道口的声压。
    var measuredFullScaleAtReference: Double? {
        guard let volumeResult, let acousticMeasurement, let phoneReadingDBA else { return nil }
        return volumeResult.referenceNormalizedLevelDBFS
            + (phoneReadingDBA - acousticMeasurement.microphoneAWeightedDBFS)
    }

    /// 同一点按耳机规格（灵敏度 × 最大输出）加实测音量曲线推算的值，用来交叉核对。
    var specFullScaleAtReference: Double? {
        guard let profile = headphoneProfile,
              let sensitivity = profile.sensitivity?.dbPerVolt,
              let source = profile.outputSource,
              let volumeResult,
              let fullVolume = volumeResult.points.first(where: { abs($0.systemVolume - 1) < 0.002 }),
              let spec100 = LevelEstimator.headphoneModelFullScaleDBA(
                  at: 1,
                  sensitivityDBV: sensitivity,
                  source: OutputSourceProfile(maxOutputVRMS: source.maxOutputVRMS, volumeCurve: [])
              ) else { return nil }
        let shift = frequencyResult.flatMap { result in
            FrequencyResponseInterpolator(points: result.points)?
                .responseDB(at: profile.sensitivityReferenceHz ?? 1_000)
        } ?? 0
        return Double(spec100) - shift - fullVolume.relativeDB
    }

    var prerequisiteIssue: String? {
        guard outputDevice.uid != nil else { return "无法读取当前输出设备 UID" }
        guard let profile = headphoneProfile, profile.isConfirmed else {
            return "请先在“设置与档案”中保存当前耳机的可信参数档案"
        }
        guard profile.kind == .wiredHeadphones,
              profile.sensitivity?.dbPerVolt != nil,
              profile.outputSource != nil else {
            return "EM258 相对校准当前需要有灵敏度和最大输出 Vrms 的有线耳机档案"
        }
        return nil
    }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        microphone.refreshDevices()
        guard let device = microphone.preferredDevice() else {
            progressMessage = "没有找到可用的音频输入设备"
            return
        }
        selectedInputUID = device.uid
        handleInput(device, trigger: .windowPreparation)
        if let prerequisiteIssue {
            progressMessage = prerequisiteIssue
        }
    }

    func prepareForPresentation() {
        if case .idle = microphone.snapshot.status {
            prepared = false
            if saved {
                step = .microphone
                frequencyResult = nil
                volumeResult = nil
                validationResult = nil
                acousticMeasurement = nil
                phoneReadingText = ""
                saved = false
            }
            prepare()
        }
    }

    func selectInput(uid: String) {
        selectedInputUID = uid
        guard let device = microphone.devices.first(where: { $0.uid == uid }) else { return }
        handleInput(device, trigger: .deviceSelection)
    }

    func beginMicrophoneDetection() {
        errorMessage = ""
        guard prerequisiteIssue == nil else {
            progressMessage = prerequisiteIssue ?? "校准条件不满足"
            return
        }
        guard let device = microphone.devices.first(where: { $0.uid == selectedInputUID }) else {
            errorMessage = "请选择可用的输入设备"
            return
        }
        handleInput(device, trigger: .manualDetectionButton)
    }

    func goToInstallation() {
        errorMessage = ""
        step = .installation
    }

    func beginFrequencyTest() {
        guard let profile = headphoneProfile,
              let uid = outputDevice.uid,
              let sensitivity = profile.sensitivity?.dbPerVolt,
              let source = profile.outputSource else { return }
        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isBusy = true
            errorMessage = ""
            defer { isBusy = false }
            do {
                let fullScale = LevelEstimator.headphoneModelFullScaleDBA(
                    at: 0.5,
                    sensitivityDBV: sensitivity,
                    source: source
                )
                let safeLevel = try CalibrationToneGenerator.safeRMSDBFS(
                    estimatedFullScaleDBA: fullScale
                )
                // 安全封顶：即使自动提高电平，也不让预测声压越过 90 dBA 上限。
                let maxSignal = fullScale.map {
                    CalibrationToneGenerator.maximumCalibrationToneDBA - Double($0)
                }
                frequencyResult = try await measurementEngine.measureFrequencyResponse(
                    outputDeviceUID: uid,
                    testSignalRMSDBFS: safeLevel,
                    maxSignalRMSDBFS: maxSignal,
                    allowSkipTopFrequencies: true,
                    progress: updateProgress
                )
                step = .volume
            } catch is CancellationError {
                progressMessage = "测试已取消"
            } catch {
                handleMeasurementError(error)
            }
        }
    }

    func beginVolumeTest() {
        guard let uid = outputDevice.uid,
              let frequencyResult,
              let sensitivity = headphoneProfile?.sensitivity?.dbPerVolt,
              let source = headphoneProfile?.outputSource else { return }
        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isBusy = true
            errorMessage = ""
            defer { isBusy = false }
            do {
                // 30% 等低音量点的声压比 50% 低一截；若沿用 50% 的封顶，
                // 测试音往往连环境噪声都压不过。这里按“当前音量”换算
                // 90 dBA 模型封顶（数字电平另有 -6 dBFS 钳制），让低音量点
                // 也有足够响的测试音，而不必要求环境绝对安静。
                let modelFullScale: (Float) -> Float? = { volume in
                    LevelEstimator.headphoneModelFullScaleDBA(
                        at: volume,
                        sensitivityDBV: sensitivity,
                        source: source
                    )
                }
                volumeResult = try await measurementEngine.measureVolumeCurve(
                    outputDeviceUID: uid,
                    testSignalRMSDBFS: frequencyResult.testSignalRMSDBFS,
                    maxSignalAtVolume: { volume in
                        modelFullScale(volume).map {
                            CalibrationToneGenerator.maximumCalibrationToneDBA - Double($0)
                        }
                    },
                    comfortableSignalAtVolume: { volume in
                        modelFullScale(volume).map {
                            CalibrationToneGenerator.comfortableCalibrationToneDBA - Double($0)
                        }
                    },
                    progress: updateProgress
                )
                step = .validation
                try await runValidation()
            } catch is CancellationError {
                progressMessage = "测试已取消"
            } catch {
                handleMeasurementError(error)
            }
        }
    }

    func retryCurrentStep() {
        errorMessage = ""
        if step == .frequency { beginFrequencyTest() }
        if step == .volume || step == .validation { beginVolumeTest() }
        if step == .absolute { beginAcousticReference() }
    }

    func goToAbsoluteStep() {
        errorMessage = ""
        step = .absolute
    }

    func beginAcousticReference() {
        activeTask?.cancel()
        acousticMeasurement = nil
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isBusy = true
            errorMessage = ""
            defer { isBusy = false }
            do {
                acousticMeasurement = try await measurementEngine.measureAcousticReference(
                    noisePlayer: noisePlayer,
                    progress: updateProgress
                )
            } catch is CancellationError {
                progressMessage = "测试已取消"
            } catch {
                handleMeasurementError(error)
            }
        }
    }

    func retryVolumeCurve() {
        errorMessage = ""
        volumeResult = nil
        validationResult = nil
        saved = false
        beginVolumeTest()
    }

    func saveCalibration(useAcousticReference: Bool = false) {
        guard canSaveCalibration else {
            errorMessage = "校准验证误差超过 2 dB，不能保存；请重新测试音量曲线。"
            return
        }
        guard microphone.matchesCurrentInputChain() else {
            handleMeasurementError(CalibrationMeasurementError.inputChainChanged)
            return
        }
        guard let profile = headphoneProfile,
              let outputUID = outputDevice.uid,
              let frequencyResult,
              let volumeResult,
              let input = microphone.snapshot.device,
              let inputChainFingerprint = microphone.inputChainFingerprint,
              let quality = currentQuality else { return }
        var acousticReference: AcousticReferenceCalibration?
        if useAcousticReference {
            guard let acousticMeasurement,
                  let phoneReadingDBA,
                  let fullScale = measuredFullScaleAtReference else {
                errorMessage = "请先完成粉红噪声测量，并输入 40~110 之间的手机读数"
                return
            }
            acousticReference = AcousticReferenceCalibration(
                referenceMeterDBA: phoneReadingDBA,
                microphoneAWeightedDBFS: acousticMeasurement.microphoneAWeightedDBFS,
                microphoneStabilityDB: acousticMeasurement.stabilityDB,
                referenceDescription: phoneDescription.trimmingCharacters(in: .whitespaces),
                measuredAt: .now,
                fullScaleRMSSPLAtReferenceVolume: fullScale
            )
        }
        let calibration = CalibrationProfile(
            headphoneProfileID: profile.id,
            headphoneName: profile.name,
            outputDeviceUID: outputUID,
            outputDeviceName: outputDevice.name ?? outputUID,
            inputDeviceUID: input.uid,
            inputDeviceName: input.name,
            inputChainFingerprint: inputChainFingerprint,
            referenceVolume: 0.5,
            testSignalRMSDBFS: volumeResult.testSignalRMSDBFS,
            frequencyPoints: frequencyResult.points,
            volumePoints: volumeResult.points,
            frequencyCalibrationValid: true,
            volumeCalibrationValid: true,
            absoluteCalibrationMode: acousticReference == nil ? .estimatedFromHeadphoneModel : .acousticReference,
            microphoneResponse: .em258NominalUncorrected,
            quality: quality,
            acousticReference: acousticReference
        )
        do {
            try calibrationStore.save(calibration)
            let absolute = acousticReference.map {
                String(format: "绝对值：手机对标实测（%@，50%% 音量满幅 %.1f dB）",
                       $0.referenceDescription, $0.fullScaleRMSSPLAtReferenceVolume)
            } ?? "绝对值：按耳机规格换算"
            try? LocalDataStore.shared.addAnnotation(ExposureAnnotation(
                title: "保存 EM258 校准",
                detail: "\(profile.name) · 音量曲线 \(volumeResult.points.count) 点 · \(absolute)"
            ))
            saved = true
            progressMessage = "校准已保存；现在可以拔掉 EM258"
            microphone.stop()
            toneGenerator.stop()
            onSaved?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        measurementEngine.cancel()
        toneGenerator.stop()
        noisePlayer.stop()
        microphone.stop()
    }

    private func handleInput(
        _ device: CalibrationInputDevice,
        trigger: CalibrationMicrophoneStartTrigger
    ) {
        activeTask?.cancel()
        microphone.select(device: device)
        errorMessage = ""
        guard trigger.startsCapture else {
            progressMessage = "已选择 \(device.name)；点击“开始检测麦克风”后才会使用麦克风"
            return
        }
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            progressMessage = "正在请求麦克风权限并连接 \(device.name)…"
            await microphone.start(device: device)
            switch microphone.snapshot.status {
            case .running:
                progressMessage = "轻触 EM258，确认下方电平明显变化"
            case .noPermission:
                progressMessage = "麦克风权限未授权；系统音频权限不受影响"
            case .failed(let message):
                errorMessage = message
            default:
                break
            }
        }
    }

    private func runValidation() async throws {
        guard let uid = outputDevice.uid, let volumeResult else { return }
        validationResult = try await measurementEngine.validateVolumeCurve(
            outputDeviceUID: uid,
            volumeResult: volumeResult,
            progress: updateProgress
        )
    }

    private func updateProgress(_ progress: CalibrationProgress) {
        progressMessage = progress.message
        progressFraction = progress.fraction
    }

    private func handleMeasurementError(_ error: Error) {
        errorMessage = error.localizedDescription
        guard let measurementError = error as? CalibrationMeasurementError else { return }
        switch measurementError {
        case .inputChainChanged, .inputDeviceChanged, .outputDeviceChanged:
            frequencyResult = nil
            volumeResult = nil
            validationResult = nil
            microphone.stop()
        default:
            break
        }
    }
}

@MainActor
final class CalibrationWizardWindowController: NSWindowController, NSWindowDelegate {
    let viewModel: CalibrationWizardViewModel

    init(
        outputMonitor: OutputDeviceMonitor,
        profiles: ProfileRepository,
        calibrationStore: CalibrationStore,
        onSaved: @escaping () -> Void
    ) {
        viewModel = CalibrationWizardViewModel(
            outputMonitor: outputMonitor,
            profiles: profiles,
            calibrationStore: calibrationStore
        )
        viewModel.onSaved = onSaved
        // VM_CALIBRATION_STEP=1…6 仅供调试/截图：直接显示某一步的版面。
        if let raw = ProcessInfo.processInfo.environment["VM_CALIBRATION_STEP"],
           let number = Int(raw), let step = CalibrationWizardStep(rawValue: number) {
            viewModel.step = step
        }
        let hostingController = NSHostingController(
            rootView: CalibrationWizardView(viewModel: viewModel)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "EM258 耳机校准"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 820, height: 640))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        viewModel.prepareForPresentation()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.cancel()
    }

    func stopCalibration() {
        viewModel.cancel()
    }
}

struct CalibrationWizardView: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel

    var body: some View {
        HStack(spacing: 0) {
            StepRail(viewModel: viewModel)
                .frame(width: 210)
                .background(Color.primary.opacity(0.035))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    switch viewModel.step {
                    case .microphone: MicrophoneCalibrationStep(viewModel: viewModel)
                    case .installation: InstallationCalibrationStep(viewModel: viewModel)
                    case .frequency: FrequencyCalibrationStep(viewModel: viewModel)
                    case .volume: VolumeCalibrationStep(viewModel: viewModel)
                    case .validation: ValidationCalibrationStep(viewModel: viewModel)
                    case .absolute: AbsoluteCalibrationStep(viewModel: viewModel)
                    }
                }
                .id(viewModel.step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity
                ))
                Spacer(minLength: 0)
                if viewModel.isBusy {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressTrack(fraction: viewModel.progressFraction)
                        Text(viewModel.progressMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    .card(padding: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !viewModel.errorMessage.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.loud)
                        Text(viewModel.errorMessage)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("仅重测当前阶段") { viewModel.retryCurrentStep() }
                            .disabled(viewModel.isBusy)
                    }
                    .card(padding: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.spring(response: 0.4, dampingFraction: 0.88), value: viewModel.step)
            .animation(.easeInOut(duration: 0.25), value: viewModel.isBusy)
            .animation(.easeInOut(duration: 0.25), value: viewModel.errorMessage)
        }
        .frame(minWidth: 760, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.prepare() }
    }
}

/// 左侧步骤栏：已完成打勾，当前步骤高亮。
private struct StepRail: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EM258 校准").font(.system(size: 17, weight: .semibold))
                Text(viewModel.headphoneProfile?.name ?? "未配置耳机档案")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.bottom, 22)
            ForEach(CalibrationWizardStep.allCases, id: \.rawValue) { item in
                let state = stepState(item)
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(state == .upcoming ? Theme.track : (state == .done ? Theme.safe : Theme.accent))
                                .frame(width: 24, height: 24)
                            if state == .done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Text("\(item.rawValue)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(state == .upcoming ? Color.secondary : Color.white)
                            }
                        }
                        if item != CalibrationWizardStep.allCases.last {
                            Rectangle()
                                .fill(state == .done ? Theme.safe.opacity(0.6) : Theme.track)
                                .frame(width: 2, height: 22)
                        }
                    }
                    Text(item.title)
                        .font(.system(size: 13, weight: state == .current ? .semibold : .regular))
                        .foregroundStyle(state == .upcoming ? .secondary : .primary)
                        .padding(.top, 3)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state)
            }
            Spacer()
            Label("麦克风只在这个窗口内使用", systemImage: "mic.slash")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private enum StepState { case done, current, upcoming }

    private func stepState(_ item: CalibrationWizardStep) -> StepState {
        if viewModel.saved { return .done }
        if item.rawValue < viewModel.step.rawValue { return .done }
        return item == viewModel.step ? .current : .upcoming
    }
}

/// 每一步顶部的图标 + 标题 + 说明。
private struct StepHeader: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 一组测量点的进度胶囊（已测 / 正在测 / 未测）。
private struct PointChips: View {
    let labels: [String]
    let done: Int
    let active: Bool
    var skipped: Set<String> = []

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let isDone = index < done && !skipped.contains(label)
                let isCurrent = active && index == done
                Text(label)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(isDone ? Color.white : (skipped.contains(label) ? Color.secondary : Color.primary))
                    .background(
                        isDone ? Theme.safe : (isCurrent ? Theme.accent.opacity(0.25) : Theme.track),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 1.5))
                    .scaleEffect(isCurrent ? 1.06 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: done)
            }
        }
    }
}

private struct CheckRow: View {
    let text: String
    var ok = true

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(ok ? Theme.safe : Theme.caution)
    }
}

private struct MicrophoneCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel
    @ObservedObject private var microphone: CalibrationMicrophoneMonitor

    init(viewModel: CalibrationWizardViewModel) {
        self.viewModel = viewModel
        microphone = viewModel.microphone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                systemImage: "mic",
                title: "检测校准麦克风",
                detail: "选择接 EM258 的输入设备（通常是“外置麦克风”），开始检测后轻触一下咪头，确认电平明显变化。"
            )
            if let issue = viewModel.prerequisiteIssue {
                CheckRow(text: issue, ok: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("输入设备", selection: Binding(
                        get: { viewModel.selectedInputUID },
                        set: { viewModel.selectInput(uid: $0) }
                    )) {
                        ForEach(microphone.devices) { device in
                            Text(device.isExternal ? "\(device.name)（外接）" : device.name).tag(device.uid)
                        }
                    }
                    .frame(maxWidth: 320)
                    .disabled(viewModel.isBusy || microphone.devices.isEmpty)
                    Spacer()
                    Button(microphone.snapshot.status == .running ? "重新检测" : "开始检测") {
                        viewModel.beginMicrophoneDetection()
                    }
                    .disabled(
                        viewModel.isBusy
                            || microphone.devices.isEmpty
                            || viewModel.prerequisiteIssue != nil
                            || microphone.snapshot.status == .requestingPermission
                    )
                }
                MicLevelBar(rms: microphone.snapshot.rmsDBFS, peak: microphone.snapshot.peakDBFS)
                HStack(spacing: 18) {
                    stat("RMS", microphone.snapshot.rmsDBFS)
                    stat("峰值", microphone.snapshot.peakDBFS)
                    stat("底噪", microphone.snapshot.noiseFloorDBFS)
                    Spacer()
                    Label(statusText, systemImage: statusIcon)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: statusText)
                }
            }
            .card()
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("下一步") { viewModel.goToInstallation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!microphone.snapshot.inputIsUsable || !microphone.snapshot.tapDetected || viewModel.prerequisiteIssue != nil)
            }
        }
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f dBFS", value)).font(.callout.monospacedDigit())
        }
    }

    private var statusText: String {
        if microphone.snapshot.clipping { return "输入接近削波，请降低输入增益" }
        if microphone.snapshot.tapDetected { return "已确认 EM258 响应" }
        switch microphone.snapshot.status {
        case .running: return "等待轻触确认"
        case .noPermission: return "麦克风权限未授权"
        case .requestingPermission: return "正在请求麦克风权限"
        case .deviceChanged: return "输入设备已变化"
        case .failed(let message): return message
        case .idle: return "尚未开始检测"
        }
    }

    private var statusIcon: String {
        microphone.snapshot.tapDetected && !microphone.snapshot.clipping ? "checkmark.circle.fill" : "hand.tap"
    }

    private var statusColor: Color {
        microphone.snapshot.tapDetected && !microphone.snapshot.clipping ? Theme.safe : Theme.caution
    }
}

/// 麦克风实时电平（−80~0 dBFS），峰值用细线标出。
private struct MicLevelBar: View {
    let rms: Double
    let peak: Double

    private func fraction(_ value: Double) -> Double {
        min(max((value + 80) / 80, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.safe, Theme.safe, Theme.caution, Theme.loud],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: proxy.size.width * fraction(rms))
                    .opacity(rms > -80 ? 1 : 0)
                    .animation(.linear(duration: 0.1), value: rms)
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: 14)
                    .offset(x: proxy.size.width * fraction(peak) - 1)
                    .animation(.easeOut(duration: 0.2), value: peak)
            }
        }
        .frame(height: 10)
        .accessibilityLabel(String(format: "麦克风电平 %.0f dBFS", rms))
    }
}

private struct InstallationCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                systemImage: "ear",
                title: "固定耳机和麦克风",
                detail: "像平时一样戴好耳机，把 EM258 放在耳罩内、尽量靠近耳道入口。后面所有测量都要保持这个位置。"
            )
            VStack(alignment: .leading, spacing: 12) {
                row("ear", "EM258 贴近耳道入口，咪头朝向耳机单元")
                row("headphones", "耳垫完整贴合，不要被线材顶开")
                row("hand.raised", "测试过程中不要移动耳机和咪头")
                row("speaker.wave.2", "测试音从低电平淡入，单点几秒，全程不超过 90 dB")
            }
            .card()
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("我已固定完成") { viewModel.step = .frequency }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(text).font(.callout)
        }
    }
}

private struct FrequencyCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel
    private static let labels = ["63", "125", "250", "500", "1k", "2k", "4k", "8k", "12k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                systemImage: "waveform",
                title: "自动频响测试",
                detail: "在 50% 音量依次测量 63 Hz 到 12 kHz 的 9 个频点，约几十秒。每个频点淡入、等待稳定、测量后淡出；噪声或不稳定只会重测当前点。"
            )
            VStack(alignment: .leading, spacing: 12) {
                PointChips(labels: Self.labels.map { $0 + " Hz" }, done: done, active: viewModel.isBusy)
                Text("8/12 kHz 信噪比不足时会自动跳过，并以 4 kHz 附近的点截止，不影响主频段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(viewModel.isBusy ? "测试中…" : "开始测试") { viewModel.beginFrequencyTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy)
            }
        }
    }

    private var done: Int {
        if viewModel.frequencyResult != nil { return Self.labels.count }
        guard viewModel.isBusy else { return 0 }
        return min(Self.labels.count - 1, Int(viewModel.progressFraction * Double(Self.labels.count)))
    }
}

private struct VolumeCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel

    private var labels: [String] {
        CalibrationProfile.requiredVolumes.map { CalibrationMeasurementEngine.percentText($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                systemImage: "speaker.wave.3",
                title: "自动音量测试",
                detail: "保持 EM258 和耳机不动，软件会把系统音量依次调到 25%~100%，每档测一次 1 kHz，约 1 分钟。测到 100% 才能不依赖估算曲线换算绝对声压。"
            )
            VStack(alignment: .leading, spacing: 12) {
                PointChips(labels: labels, done: done, active: viewModel.isBusy)
                Text("高音量点先用约 80 dB 的测试音，信噪比不够时才提高，整个过程不超过 90 dB。测完会恢复你原来的音量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(viewModel.isBusy ? "测试中…" : "开始测试") { viewModel.beginVolumeTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy)
            }
        }
    }

    private var done: Int {
        if viewModel.volumeResult != nil { return labels.count }
        guard viewModel.isBusy else { return 0 }
        return min(labels.count - 1, Int(viewModel.progressFraction * Double(labels.count)))
    }
}

private struct ValidationCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                systemImage: "checkmark.seal",
                title: "验证",
                detail: "用没参与建模的 60% 音量独立测一次，检查音量曲线能不能预测它。"
            )
            if viewModel.isBusy && viewModel.validationResult == nil {
                Text("正在验证…").foregroundStyle(.secondary)
            } else if let validation = viewModel.validationResult {
                VStack(alignment: .leading, spacing: 10) {
                    CheckRow(text: "频率响应已实测（\(viewModel.frequencyResult?.points.count ?? 0) 点）")
                    CheckRow(text: "系统音量曲线已实测（\(viewModel.volumeResult?.points.count ?? 0) 点，25%~100%）")
                    CheckRow(
                        text: String(format: "60%% 验证误差 %.2f dB · %@", validation.absoluteErrorDB, validationText(validation.absoluteErrorDB)),
                        ok: validation.absoluteErrorDB <= 2
                    )
                }
                .card()
                .fixedSize(horizontal: false, vertical: true)
                if let quality = viewModel.currentQuality {
                    HStack(spacing: 14) {
                        metric("数据质量", quality.grade.displayName)
                        metric("最低信噪比", String(format: "%.1f dB", quality.minimumSNRDB))
                        metric("最大波动", String(format: "%.2f dB", quality.maximumStabilityDB))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if viewModel.saved {
                    savedBanner
                } else {
                    Text("下一步用手机给 EM258 定刻度，得到耳边的实测绝对声压（推荐）；跳过则绝对值按耳机灵敏度和最大输出换算。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        if validation.absoluteErrorDB > 2.0 {
                            Button("重新测试音量曲线") { viewModel.retryVolumeCurve() }
                                .disabled(viewModel.isBusy)
                        }
                        Spacer()
                        Button("跳过，按耳机参数保存") { viewModel.saveCalibration() }
                            .disabled(!viewModel.canSaveCalibration)
                        Button("下一步：手机对标") { viewModel.goToAbsoluteStep() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.canSaveCalibration)
                    }
                }
            } else {
                Text("等待音量测试完成。").foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
        }
        .card(padding: 12)
    }

    private func validationText(_ error: Double) -> String {
        if error <= 1.0 { return "通过" }
        if error <= 2.0 { return "可用，但误差偏大" }
        return "未通过，请重测音量曲线"
    }

    private var savedBanner: some View {
        SavedBanner(message: viewModel.progressMessage)
    }
}

private struct SavedBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.safe)
                .symbolEffect(.bounce, value: message)
            VStack(alignment: .leading, spacing: 2) {
                Text("校准已保存").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
        .fixedSize(horizontal: false, vertical: true)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

private struct AbsoluteCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                systemImage: "iphone.gen3",
                title: "手机对标绝对声压",
                detail: "用手机自带麦克风作参考（精度约 ±2 dB），给 EM258 定刻度。不要把 EM258 插到手机上。"
            )
            if !viewModel.speakerAvailable {
                CheckRow(text: "找不到 MacBook 内置扬声器，这一步无法进行；可以按耳机参数保存。", ok: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                instruction(1, "cable.connector", "摘下耳机放一边，但耳机和 EM258 都保持插在转接头上")
                instruction(2, "iphone", "EM258 用胶带贴在手机底部麦克风旁，一起朝向 MacBook 扬声器，相距 30~50 cm，放在桌上")
                instruction(3, "app.badge", "手机打开 NIOSH SLM（或其他声级计 App），设为 A 计权")
                instruction(4, "play.circle", "点下方按钮播放约 20 秒粉红噪声，读数稳定后记下手机中间的大数字")
            }
            .card()
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                Button(viewModel.isBusy ? "测量中…" : "播放粉红噪声并测量") {
                    viewModel.beginAcousticReference()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || !viewModel.speakerAvailable)
                if let measurement = viewModel.acousticMeasurement {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(
                            format: "EM258 %.2f dBFS(A) · 波动 %.2f dB · 信噪比 %.1f dB",
                            measurement.microphoneAWeightedDBFS,
                            measurement.stabilityDB,
                            measurement.snrDB
                        ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        HStack {
                            TextField("手机读数 dBA", text: $viewModel.phoneReadingText)
                                .frame(width: 110)
                            TextField("手机型号 · App", text: $viewModel.phoneDescription)
                        }
                        comparison
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(.easeOut(duration: 0.3), value: viewModel.acousticMeasurement)
            if viewModel.saved {
                SavedBanner(message: viewModel.progressMessage)
            } else {
                HStack {
                    Spacer()
                    Button("不用手机，按耳机参数保存") { viewModel.saveCalibration() }
                        .disabled(viewModel.isBusy || !viewModel.canSaveCalibration)
                    Button("保存校准（实测绝对值）") { viewModel.saveCalibration(useAcousticReference: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.measuredFullScaleAtReference == nil)
                }
            }
        }
    }

    private func instruction(_ number: Int, _ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var comparison: some View {
        if let measured = viewModel.measuredFullScaleAtReference {
            if let spec = viewModel.specFullScaleAtReference {
                let delta = measured - spec
                Label(
                    String(format: "50%% 音量满幅：实测 %.1f dB · 规格推算 %.1f dB · 相差 %+.1f dB", measured, spec, delta),
                    systemImage: abs(delta) > 6 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(abs(delta) > 6 ? Theme.caution : Theme.safe)
                if abs(delta) > 6 {
                    Text("差异超过 6 dB：请确认手机读数、EM258 贴在手机麦克风旁、两者离扬声器距离一致。确认无误仍可保存。")
                        .font(.caption)
                        .foregroundStyle(Theme.caution)
                }
            } else {
                Text(String(format: "50%% 音量满幅：实测 %.1f dB", measured)).font(.callout.monospacedDigit())
            }
        } else if !viewModel.phoneReadingText.isEmpty {
            Text("请输入 40~110 之间的数字").font(.caption).foregroundStyle(Theme.caution)
        }
    }
}
