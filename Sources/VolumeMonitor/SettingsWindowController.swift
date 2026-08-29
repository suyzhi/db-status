import AppKit
import Charts
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ExposureHistoryPoint: Identifiable {
    var id: Date { minute }
    let minute: Date
    let equivalentLevelDBA: Double
    let peakDBA: Double
    let deviceUID: String
}

struct DeviceExposureSummary: Identifiable {
    var id: String { deviceUID }
    let deviceUID: String
    let dosePercent: Double
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let viewModel: SettingsViewModel

    init(
        outputMonitor: OutputDeviceMonitor,
        profiles: ProfileRepository,
        preferences: AppPreferences,
        calibrationStore: CalibrationStore,
        onMonitoringChanged: @escaping (Bool) -> Void
    ) {
        viewModel = SettingsViewModel(
            outputMonitor: outputMonitor,
            profiles: profiles,
            preferences: preferences,
            calibrationStore: calibrationStore,
            onMonitoringChanged: onMonitoringChanged
        )
        let hostingController = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        // VM_OPEN_ADVANCED / VM_OPEN_WIZARD 仅供调试/验证：直接定位到对应页面。
        if ProcessInfo.processInfo.environment["VM_OPEN_ADVANCED"] == "1" {
            viewModel.showAdvanced = true
        }
        if ProcessInfo.processInfo.environment["VM_OPEN_WIZARD"] == "1" {
            viewModel.showQuickSetup = true
        }
        let window = NSWindow(contentViewController: hostingController)
        window.title = "音量监测设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 680))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        viewModel.reloadCurrentDevice()
        super.showWindow(sender)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var deviceName = "不可用"
    @Published var deviceUID = ""
    @Published var profileName = ""
    @Published var kind: TransducerKind = .wiredHeadphones
    @Published var sensitivityUnit = "dbPerVolt"
    @Published var sensitivityValue = ""
    @Published var impedanceOhms = ""
    @Published var maxOutputVRMS = "1.0"
    @Published var volumeCurveText = ""
    @Published var acousticPointsText = ""
    @Published var calibrationOffsetDB = ""
    @Published var reference = ""
    @Published var message = ""
    @Published var monitoringEnabled: Bool
    @Published var exposureMode: ExposureMode
    @Published var statusBarDisplayMode: StatusBarDisplayMode
    @Published var launchAtLogin: Bool
    @Published var historyPoints: [ExposureHistoryPoint] = []
    @Published var deviceExposure: [DeviceExposureSummary] = []
    @Published var calibrationStatus = "未校准 · 当前使用标准估算模式"
    @Published var hasCurrentCalibration = false
    @Published var showAdvanced = false
    @Published var showHistory = false
    @Published var showQuickSetup = false
    @Published var currentDosePercent: Double = 0
    @Published var hasBoundProfile = false

    let outputMonitor: OutputDeviceMonitor
    let profiles: ProfileRepository
    private let preferences: AppPreferences
    private let calibrationStore: CalibrationStore
    private let onMonitoringChanged: (Bool) -> Void
    private var editingProfileID = UUID()

    init(
        outputMonitor: OutputDeviceMonitor,
        profiles: ProfileRepository,
        preferences: AppPreferences,
        calibrationStore: CalibrationStore,
        onMonitoringChanged: @escaping (Bool) -> Void
    ) {
        self.outputMonitor = outputMonitor
        self.profiles = profiles
        self.preferences = preferences
        self.calibrationStore = calibrationStore
        self.onMonitoringChanged = onMonitoringChanged
        monitoringEnabled = preferences.monitoringEnabled
        exposureMode = preferences.exposureMode
        statusBarDisplayMode = preferences.statusBarDisplayMode
        launchAtLogin = SMAppService.mainApp.status == .enabled
        reloadCurrentDevice()
    }

    func reloadCurrentDevice() {
        let device = outputMonitor.snapshot()
        deviceName = device.name ?? "不可用"
        deviceUID = device.uid ?? ""
        monitoringEnabled = preferences.monitoringEnabled
        exposureMode = preferences.exposureMode
        statusBarDisplayMode = preferences.statusBarDisplayMode
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hasBoundProfile = device.uid.flatMap { profiles.profile(for: $0)?.isConfirmed } == true
        reloadHistory()

        guard let profile = profiles.profile(for: device.uid) else {
            calibrationStatus = "未校准 · 当前使用标准估算模式"
            hasCurrentCalibration = false
            editingProfileID = UUID()
            profileName = device.name ?? ""
            kind = .wiredHeadphones
            sensitivityUnit = "dbPerVolt"
            sensitivityValue = ""
            impedanceOhms = ""
            maxOutputVRMS = "1.0"
            volumeCurveText = ""
            acousticPointsText = ""
            calibrationOffsetDB = ""
            reference = ""
            message = device.uid == nil ? "当前没有可配置的输出设备" : "当前设备尚未创建档案"
            return
        }

        editingProfileID = profile.id
        reloadCalibrationStatus(profile: profile, outputUID: device.uid)
        profileName = profile.name
        kind = profile.kind
        switch profile.sensitivity {
        case .dbPerVolt(let value):
            sensitivityUnit = "dbPerVolt"
            sensitivityValue = format(value)
            impedanceOhms = ""
        case .dbPerMilliwatt(let value, let impedance):
            sensitivityUnit = "dbPerMilliwatt"
            sensitivityValue = format(value)
            impedanceOhms = format(impedance)
        case nil:
            sensitivityUnit = "dbPerVolt"
            sensitivityValue = ""
            impedanceOhms = ""
        }
        maxOutputVRMS = profile.outputSource.map { format($0.maxOutputVRMS) } ?? "1.0"
        volumeCurveText = profile.outputSource?.volumeCurve
            .map { "\(Int(($0.volumeScalar * 100).rounded()))=\(format($0.attenuationDB))" }
            .joined(separator: ", ") ?? ""
        acousticPointsText = profile.acousticCalibrationPoints
            .map { "\(Int(($0.volumeScalar * 100).rounded()))=\(format($0.fullScaleDBA))" }
            .joined(separator: ", ")
        calibrationOffsetDB = profile.calibration.map { format($0.offsetDB) } ?? ""
        reference = profile.reference
        message = "已载入当前设备的档案"
    }

    func saveProfile() {
        guard !deviceUID.isEmpty else {
            message = "无法读取当前设备 UID"
            return
        }
        guard !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请输入档案名称"
            return
        }
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请记录规格或校准来源"
            return
        }

        let calibration = Float(calibrationOffsetDB).map {
            CalibrationRecord(offsetDB: $0, date: .now, reference: reference)
        }
        var profile = TransducerProfile(
            id: editingProfileID,
            name: profileName,
            deviceUID: deviceUID,
            kind: kind,
            calibration: calibration,
            reference: reference,
            isConfirmed: true
        )

        switch kind {
        case .wiredHeadphones:
            guard let sensitivity = Float(sensitivityValue),
                  let maxVRMS = Float(maxOutputVRMS),
                  maxVRMS > 0 else {
                message = "请输入有效的灵敏度和最大输出 Vrms"
                return
            }
            if sensitivityUnit == "dbPerMilliwatt" {
                guard let impedance = Float(impedanceOhms), impedance > 0 else {
                    message = "dB/mW 规格必须提供大于 0 的阻抗"
                    return
                }
                profile.sensitivity = .dbPerMilliwatt(value: sensitivity, impedanceOhms: impedance)
            } else {
                profile.sensitivity = .dbPerVolt(sensitivity)
            }
            profile.outputSource = OutputSourceProfile(
                maxOutputVRMS: maxVRMS,
                volumeCurve: parsePairs(volumeCurveText).map {
                    VolumeCurvePoint(volumeScalar: $0.0, attenuationDB: $0.1)
                }
            )

        case .calibratedDevice:
            let points = parsePairs(acousticPointsText).map {
                AcousticCalibrationPoint(volumeScalar: $0.0, fullScaleDBA: $0.1)
            }
            guard points.count >= 2 else {
                message = "蓝牙耳机或扬声器至少需要 2 个声学校准点"
                return
            }
            profile.acousticCalibrationPoints = points
        }

        do {
            try profiles.save(profile)
            message = "档案已保存并绑定到当前设备 UID"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    func removeProfile() {
        guard !deviceUID.isEmpty else { return }
        do {
            try profiles.removeProfile(for: deviceUID)
            reloadCurrentDevice()
            message = "已删除当前设备的档案，dBA 估算已停止"
        } catch {
            message = "删除失败：\(error.localizedDescription)"
        }
    }

    func removeCalibration() {
        guard let profile = profiles.profile(for: deviceUID), !deviceUID.isEmpty else { return }
        do {
            try calibrationStore.remove(
                headphoneProfileID: profile.id,
                outputDeviceUID: deviceUID
            )
            reloadCalibrationStatus(profile: profile, outputUID: deviceUID)
            message = "已删除当前耳机和输出设备的 EM258 校准；已恢复标准估算模式"
        } catch {
            message = "删除校准失败：\(error.localizedDescription)"
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        monitoringEnabled = enabled
        onMonitoringChanged(enabled)
    }

    func setExposureMode(_ mode: ExposureMode) {
        exposureMode = mode
        preferences.exposureMode = mode
        reloadHistory()
    }

    func setStatusBarDisplayMode(_ mode: StatusBarDisplayMode) {
        statusBarDisplayMode = mode
        preferences.statusBarDisplayMode = mode
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "导出本地声暴露记录"
        panel.nameFieldStringValue = "VolumeMonitor-exposure.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let formatter = ISO8601DateFormatter()
        var csv = "minute,equivalent_dBA,peak_dBA,device_uid\n"
        for point in historyPoints {
            let uid = point.deviceUID.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\(formatter.string(from: point.minute)),\(point.equivalentLevelDBA),\(point.peakDBA),\"\(uid)\"\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            message = "CSV 已导出"
        } catch {
            message = "CSV 导出失败：\(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = launchAtLogin ? "已设为登录时启动" : "已关闭登录时启动"
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "更新开机启动设置失败：\(error.localizedDescription)"
        }
    }

    func openAudioPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else {
            message = "无法生成系统设置链接"
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func reloadHistory(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let buckets = LocalDataStore.shared.exposureBuckets
            .filter { $0.minute >= cutoff && $0.measuredDuration > 0 }
            .sorted { $0.minute < $1.minute }
        historyPoints = buckets.compactMap { bucket in
            guard let level = ExposureMath.equivalentLevelDBA(
                normalizedEnergyAt80: bucket.normalizedEnergyAt80Seconds,
                duration: bucket.measuredDuration
            ) else { return nil }
            return ExposureHistoryPoint(
                minute: bucket.minute,
                equivalentLevelDBA: level,
                peakDBA: bucket.peakDBA,
                deviceUID: bucket.deviceUID
            )
        }
        let grouped = Dictionary(grouping: buckets, by: \.deviceUID)
        deviceExposure = grouped.map { uid, values in
            let energy = values.reduce(0) { $0 + $1.normalizedEnergyAt80Seconds }
            return DeviceExposureSummary(
                deviceUID: uid,
                dosePercent: ExposureMath.doseFraction(
                    normalizedEnergyAt80: energy,
                    mode: exposureMode
                ) * 100
            )
        }.sorted { $0.dosePercent > $1.dosePercent }

        let sevenDayEnergy = buckets.reduce(0) { $0 + $1.normalizedEnergyAt80Seconds }
        currentDosePercent = ExposureMath.doseFraction(
            normalizedEnergyAt80: sevenDayEnergy,
            mode: exposureMode
        ) * 100
    }

    private func reloadCalibrationStatus(
        profile: TransducerProfile,
        outputUID: String?
    ) {
        switch calibrationStore.resolution(
            headphoneProfileID: profile.id,
            outputDeviceUID: outputUID
        ) {
        case .active(let calibration):
            calibrationStatus = "频响：EM258 实测 · 音量曲线：EM258 实测 · 绝对 SPL：参数估算 · \(calibration.createdAt.formatted(date: .abbreviated, time: .shortened))"
            hasCurrentCalibration = true
        case .outputMismatch:
            calibrationStatus = "当前输出设备与校准设备不一致"
            hasCurrentCalibration = false
        case .invalid(let reason):
            calibrationStatus = "校准不可用：\(reason)"
            hasCurrentCalibration = false
        case .notCalibrated:
            calibrationStatus = "未校准 · 当前使用标准估算模式"
            hasCurrentCalibration = false
        }
    }

    private func parsePairs(_ text: String) -> [(Float, Float)] {
        text.split(separator: ",")
            .compactMap { component -> (Float, Float)? in
                let values = component.split(separator: "=", maxSplits: 1)
                guard values.count == 2,
                      let percent = Float(values[0].trimmingCharacters(in: .whitespaces)),
                      let value = Float(values[1].trimmingCharacters(in: .whitespaces)),
                      (0...100).contains(percent) else { return nil }
                return (percent / 100, value)
            }
            .sorted { $0.0 < $1.0 }
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.00$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\.\d)0$"#, with: "$1", options: .regularExpression)
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Group {
            if viewModel.showAdvanced {
                advancedForm
            } else {
                simpleForm
            }
        }
        .frame(minWidth: 540, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $viewModel.showHistory) {
            HistoryView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showQuickSetup) {
            QuickSetupWizardView(
                viewModel: QuickSetupWizardViewModel(
                    outputMonitor: viewModel.outputMonitor,
                    profiles: viewModel.profiles
                ),
                onSaved: {
                    viewModel.reloadCurrentDevice()
                    viewModel.showQuickSetup = false
                },
                onCancel: {
                    viewModel.showQuickSetup = false
                }
            )
        }
    }

    // MARK: - 简单页（默认）

    private var simpleForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("监测") {
                    Toggle("启用系统音频监测", isOn: Binding(
                        get: { viewModel.monitoringEnabled },
                        set: { viewModel.setMonitoringEnabled($0) }
                    ))
                    HStack {
                        Text("菜单栏显示")
                        Spacer()
                        Picker("", selection: Binding(
                            get: {
                                viewModel.statusBarDisplayMode == .estimatedDBA
                                    ? StatusBarDisplayMode.estimatedDBA
                                    : StatusBarDisplayMode.sevenDayDose
                            },
                            set: { viewModel.setStatusBarDisplayMode($0) }
                        )) {
                            Text("实时 dBA").tag(StatusBarDisplayMode.estimatedDBA)
                            Text("过去 7 天剂量 %").tag(StatusBarDisplayMode.sevenDayDose)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230)
                    }
                    if viewModel.statusBarDisplayMode == .rmsDBFS {
                        Text("当前显示为 RMS(A) dBFS（高级选项）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("当前设备") {
                    LabeledContent("名称", value: viewModel.deviceName)
                    LabeledContent("档案", value: viewModel.hasBoundProfile ? "✓ 已绑定可信估算" : "未绑定（先做快速设置）")
                    Button {
                        viewModel.showQuickSetup = true
                    } label: {
                        Label(viewModel.hasBoundProfile ? "重新快速设置…" : "快速设置…", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section("过去 7 天声暴露") {
                    HStack {
                        Text(String(format: "%.1f%%", viewModel.currentDosePercent))
                            .font(.system(size: 34, weight: .bold))
                            .monospacedDigit()
                        Spacer()
                        Button("查看详情…") { viewModel.showHistory = true }
                    }
                    if viewModel.historyPoints.isEmpty {
                        Text("暂无可信的声暴露记录")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        Text("按 WHO 成人参考：80 dBA × 40 小时 = 100%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("显示高级选项…") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.showAdvanced = true
                    }
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)

            Text(viewModel.message)
                .font(.caption)
                .foregroundStyle(viewModel.message.contains("失败") || viewModel.message.contains("请") ? .red : .secondary)
                .padding(.horizontal, 22)
            Text("所有档案和暴露记录仅保存在本机。估算结果不代替专业测量或医疗建议。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
        }
    }

    // MARK: - 高级页（展开全部现有功能）

    private var advancedForm: some View {
        Form {
            Section("监测") {
                Toggle("启用系统音频监测", isOn: Binding(
                    get: { viewModel.monitoringEnabled },
                    set: { viewModel.setMonitoringEnabled($0) }
                ))
                Toggle("登录时启动", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))
                Button("打开系统音频权限设置…") {
                    viewModel.openAudioPermissionSettings()
                }
                Picker("声暴露基准", selection: Binding(
                    get: { viewModel.exposureMode },
                    set: { viewModel.setExposureMode($0) }
                )) {
                    ForEach(ExposureMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("菜单栏显示", selection: Binding(
                    get: { viewModel.statusBarDisplayMode },
                    set: { viewModel.setStatusBarDisplayMode($0) }
                )) {
                    ForEach(StatusBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("当前输出设备") {
                LabeledContent("名称", value: viewModel.deviceName)
                LabeledContent("CoreAudio UID", value: viewModel.deviceUID.isEmpty ? "不可用" : viewModel.deviceUID)
                Button { viewModel.showQuickSetup = true } label: {
                    Label("快速设置当前设备…", systemImage: "sparkles")
                }
            }

            Section("可信估算档案") {
                TextField("档案名称", text: $viewModel.profileName)
                Picker("档案类型", selection: $viewModel.kind) {
                    ForEach(TransducerKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                if viewModel.kind == .wiredHeadphones {
                    Picker("灵敏度单位", selection: $viewModel.sensitivityUnit) {
                        Text("dB/V").tag("dbPerVolt")
                        Text("dB/mW").tag("dbPerMilliwatt")
                    }
                    TextField("灵敏度数值", text: $viewModel.sensitivityValue)
                    if viewModel.sensitivityUnit == "dbPerMilliwatt" {
                        TextField("阻抗 (Ω)", text: $viewModel.impedanceOhms)
                    }
                    TextField("输出源最大 Vrms", text: $viewModel.maxOutputVRMS)
                    TextField("音量曲线（可选，如 25=-40, 50=-18, 100=0）", text: $viewModel.volumeCurveText)
                    Text("未提供至少两个曲线点时，结果会标记为“估算曲线”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("校准点（音量%=dBA，如 25=70, 50=82, 100=96）", text: $viewModel.acousticPointsText)
                    Text("请使用声学耦合器或可追溯的参考测量；扬声器需在固定聆听位置校准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("可选校准偏移 (dB)", text: $viewModel.calibrationOffsetDB)
                TextField("规格/校准来源（必填）", text: $viewModel.reference)
                HStack {
                    Button("保存并绑定当前 UID") { viewModel.saveProfile() }
                        .buttonStyle(.borderedProminent)
                    Button("删除档案", role: .destructive) { viewModel.removeProfile() }
                    Spacer()
                    Button("重新读取设备") { viewModel.reloadCurrentDevice() }
                }
            }

            Section("EM258 相对校准") {
                Text(viewModel.calibrationStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.hasCurrentCalibration ? .blue : .secondary)
                Text("删除校准不会删除耳机参数档案或声暴露记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("删除当前校准并恢复标准估算", role: .destructive) {
                    viewModel.removeCalibration()
                }
                .disabled(!viewModel.hasCurrentCalibration)
            }

            Section("过去 7 天趋势") {
                Button("查看详情…") { viewModel.showHistory = true }
            }

            Text(viewModel.message)
                .font(.caption)
                .foregroundStyle(viewModel.message.contains("失败") || viewModel.message.contains("请") ? .red : .secondary)
            Text("所有档案和暴露记录仅保存在本机。估算结果不代替专业测量或医疗建议。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("返回简版") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.showAdvanced = false
                    }
                }
                .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// 趋势/历史详情（弹层）。
struct HistoryView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("过去 7 天趋势").font(.headline)
                Spacer()
                Button("关闭") { viewModel.showHistory = false }
                    .buttonStyle(.link)
            }
            if viewModel.historyPoints.isEmpty {
                Text("暂无可信的声暴露记录")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                Spacer()
            } else {
                Chart(viewModel.historyPoints) { point in
                    LineMark(
                        x: .value("时间", point.minute),
                        y: .value("LAeq", point.equivalentLevelDBA)
                    )
                    .foregroundStyle(.blue)
                    PointMark(
                        x: .value("时间", point.minute),
                        y: .value("峰值", point.peakDBA)
                    )
                    .foregroundStyle(.orange.opacity(0.45))
                }
                .frame(height: 200)

                ForEach(viewModel.deviceExposure.prefix(6)) { device in
                    HStack {
                        Text(device.deviceUID).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", device.dosePercent))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
                HStack {
                    Spacer()
                    Button("导出 CSV…") { viewModel.exportCSV() }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }
}
