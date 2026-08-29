import AppKit
import Combine
import SwiftUI

enum CalibrationWizardStep: Int, CaseIterable {
    case microphone = 1
    case installation
    case frequency
    case volume
    case validation

    var title: String {
        switch self {
        case .microphone: "检测 EM258"
        case .installation: "固定耳机和麦克风"
        case .frequency: "自动频响测试"
        case .volume: "自动音量测试"
        case .validation: "验证并保存"
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
    @Published var saved = false

    let microphone = CalibrationMicrophoneMonitor()
    private let toneGenerator = CalibrationToneGenerator()
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
        guard let uid = outputDevice.uid, let frequencyResult else { return }
        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isBusy = true
            errorMessage = ""
            defer { isBusy = false }
            do {
                volumeResult = try await measurementEngine.measureVolumeCurve(
                    outputDeviceUID: uid,
                    testSignalRMSDBFS: frequencyResult.testSignalRMSDBFS,
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
    }

    func retryVolumeCurve() {
        errorMessage = ""
        volumeResult = nil
        validationResult = nil
        saved = false
        beginVolumeTest()
    }

    func saveCalibration() {
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
            absoluteCalibrationMode: .estimatedFromHeadphoneModel,
            microphoneResponse: .em258NominalUncorrected,
            quality: quality
        )
        do {
            try calibrationStore.save(calibration)
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
        let hostingController = NSHostingController(
            rootView: CalibrationWizardView(viewModel: viewModel)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "EM258 耳机相对校准"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 560))
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                ForEach(CalibrationWizardStep.allCases, id: \.rawValue) { item in
                    VStack(spacing: 4) {
                        Text("\(item.rawValue)")
                            .font(.caption.bold())
                            .frame(width: 24, height: 24)
                            .background(item.rawValue <= viewModel.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                            .foregroundStyle(item.rawValue <= viewModel.step.rawValue ? .white : .secondary)
                            .clipShape(Circle())
                        Text(item.title).font(.caption2).lineLimit(1)
                    }
                    if item != .validation { Divider().frame(width: 30) }
                }
            }

            Divider()
            Group {
                switch viewModel.step {
                case .microphone: MicrophoneCalibrationStep(viewModel: viewModel)
                case .installation: InstallationCalibrationStep(viewModel: viewModel)
                case .frequency: FrequencyCalibrationStep(viewModel: viewModel)
                case .volume: VolumeCalibrationStep(viewModel: viewModel)
                case .validation: ValidationCalibrationStep(viewModel: viewModel)
                }
            }
            Spacer()
            if viewModel.isBusy {
                ProgressView(value: viewModel.progressFraction)
                Text(viewModel.progressMessage).font(.caption).foregroundStyle(.secondary)
            }
            if !viewModel.errorMessage.isEmpty {
                Text(viewModel.errorMessage).font(.caption).foregroundStyle(.red)
                Button("仅重测当前阶段") { viewModel.retryCurrentStep() }
                    .disabled(viewModel.isBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.prepare() }
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
        VStack(alignment: .leading, spacing: 14) {
            Text("检测校准麦克风").font(.title2.bold())
            if let issue = viewModel.prerequisiteIssue {
                Text(issue).foregroundStyle(.orange)
            }
            Picker("输入设备", selection: Binding(
                get: { viewModel.selectedInputUID },
                set: { viewModel.selectInput(uid: $0) }
            )) {
                ForEach(microphone.devices) { device in
                    Text(device.isExternal ? "\(device.name)（外接）" : device.name).tag(device.uid)
                }
            }
            .disabled(viewModel.isBusy || microphone.devices.isEmpty)

            Button(microphone.snapshot.status == .running ? "重新检测麦克风" : "开始检测麦克风") {
                viewModel.beginMicrophoneDetection()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                viewModel.isBusy
                    || microphone.devices.isEmpty
                    || viewModel.prerequisiteIssue != nil
                    || microphone.snapshot.status == .requestingPermission
            )

            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 8) {
                GridRow { Text("RMS"); Text(format(microphone.snapshot.rmsDBFS) + " dBFS").monospacedDigit() }
                GridRow { Text("Peak"); Text(format(microphone.snapshot.peakDBFS) + " dBFS").monospacedDigit() }
                GridRow { Text("底噪"); Text(format(microphone.snapshot.noiseFloorDBFS) + " dBFS").monospacedDigit() }
            }
            Text(statusText).foregroundStyle(statusColor)
            Text("轻触 EM258，软件检测到明显电平变化后即可继续。麦克风只在这个校准窗口内使用。")
                .font(.callout).foregroundStyle(.secondary)
            Button("下一步") { viewModel.goToInstallation() }
                .buttonStyle(.borderedProminent)
                .disabled(!microphone.snapshot.inputIsUsable || !microphone.snapshot.tapDetected || viewModel.prerequisiteIssue != nil)
        }
    }

    private var statusText: String {
        if microphone.snapshot.clipping { return "● 输入接近削波，请降低输入增益" }
        if microphone.snapshot.tapDetected { return "● 输入正常，已确认 EM258 响应" }
        switch microphone.snapshot.status {
        case .running: return "○ 等待轻触确认"
        case .noPermission: return "○ 麦克风权限未授权"
        case .requestingPermission: return "○ 正在请求麦克风权限"
        case .deviceChanged: return "○ 输入设备已变化"
        case .failed(let message): return "○ \(message)"
        case .idle: return "○ 尚未检测；麦克风未启动"
        }
    }

    private var statusColor: Color {
        microphone.snapshot.tapDetected && !microphone.snapshot.clipping ? .green : .orange
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }
}

private struct InstallationCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("固定耳机和麦克风").font(.title2.bold())
            Text("把 EM258 固定在耳罩内部，位置尽量接近人耳耳道入口。")
            VStack(alignment: .leading, spacing: 8) {
                Label("麦克风不会移动", systemImage: "checkmark.circle.fill")
                Label("耳垫完整密封", systemImage: "checkmark.circle.fill")
                Label("后续测试不要移动耳机", systemImage: "checkmark.circle.fill")
            }.foregroundStyle(.green)
            Text("测试会从低电平淡入，并按耳机参数限制在估算 90 dBA 以下（短时校准音）。")
                .font(.caption).foregroundStyle(.secondary)
            Button("我已固定完成") {
                viewModel.step = .frequency
            }.buttonStyle(.borderedProminent)
        }
    }
}

private struct FrequencyCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自动频响测试").font(.title2.bold())
            Text("系统将在 50% 音量依次测量 63 Hz 到 12 kHz 的 9 个频点，约需几十秒。若 8/12 kHz 信噪比仍不足，会自动跳过并以 4 kHz 附近的点截止，不影响主频段校准。")
            Text("每个频点都会淡入、等待稳定、测量并淡出；噪声、削波或不稳定只会重测当前点。")
                .font(.callout).foregroundStyle(.secondary)
            Button(viewModel.isBusy ? "测试中…" : "开始自动测试") {
                viewModel.beginFrequencyTest()
            }.buttonStyle(.borderedProminent).disabled(viewModel.isBusy)
        }
    }
}

private struct VolumeCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自动音量测试").font(.title2.bold())
            Text("保持 EM258 和耳机位置不动，软件将在 30%、50%、70% 音量测量 1 kHz。")
            Text("这里记录的只是相对于 50% 的真实声压变化，不会把麦克风 dBFS 当作绝对 SPL。")
                .font(.callout).foregroundStyle(.secondary)
            Button(viewModel.isBusy ? "测试中…" : "开始音量测试") {
                viewModel.beginVolumeTest()
            }.buttonStyle(.borderedProminent).disabled(viewModel.isBusy)
        }
    }
}

private struct ValidationCalibrationStep: View {
    @ObservedObject var viewModel: CalibrationWizardViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("验证并保存").font(.title2.bold())
            if viewModel.isBusy {
                Text("正在使用未参与建模的 60% 音量验证相对曲线…")
            } else if let validation = viewModel.validationResult {
                Text("耳机：\(viewModel.headphoneProfile?.name ?? "—")")
                Text("输出设备：\(viewModel.outputDevice.name ?? "—")")
                Label("频率响应已实测（9 点）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("系统音量曲线已实测（3 点）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("绝对声压仍使用耳机参数估算", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Label(validationStatus(validation.absoluteErrorDB), systemImage: validationIcon(validation.absoluteErrorDB))
                    .foregroundStyle(validationColor(validation.absoluteErrorDB))
                if let quality = viewModel.currentQuality {
                    Text("相对校准数据质量：\(quality.grade.displayName)").font(.headline)
                    Text(String(format: "最低 SNR：%.1f dB", quality.minimumSNRDB)).monospacedDigit()
                    Text(String(format: "最大波动：%.2f dB", quality.maximumStabilityDB)).monospacedDigit()
                    Text(String(format: "音量验证误差：%.2f dB", validation.absoluteErrorDB)).monospacedDigit()
                    Text("该等级只描述本次相对校准的数据质量，不代表绝对 SPL 精度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("EM258：无个体频响校准文件")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(viewModel.saved ? "已保存" : "保存校准") {
                        viewModel.saveCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSaveCalibration)
                    if validation.absoluteErrorDB > 2.0 {
                        Button("重新测试音量曲线") { viewModel.retryVolumeCurve() }
                            .disabled(viewModel.isBusy)
                    }
                }
            } else {
                Text("等待音量测试完成。")
            }
        }
    }


    private func validationStatus(_ error: Double) -> String {
        if error <= 1.0 { return "验证通过" }
        if error <= 2.0 { return "校准可用，但验证误差偏大" }
        return "校准验证失败，建议重新测试"
    }

    private func validationIcon(_ error: Double) -> String {
        error <= 2.0 ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private func validationColor(_ error: Double) -> Color {
        if error <= 1.0 { return .green }
        if error <= 2.0 { return .orange }
        return .red
    }
}
