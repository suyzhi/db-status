import AppKit
import SwiftUI

/// 官方标称参数明确的有线耳机预设。所有值均为厂商公开标称，结果属
/// "规格估算"；输出源按典型 1.0 Vrms 估算（可在高级选项中调整）。
struct WiredPreset: Identifiable {
    let id: String
    let manufacturer: String
    let name: String
    let sensitivity: SensitivitySpec

    var equivalentDBV: Float? { sensitivity.dbPerVolt }

    var summary: String {
        switch sensitivity {
        case .dbPerVolt(let v):
            return String(format: "%.0f dB/V", v)
        case .dbPerMilliwatt(let v, let ohm):
            return String(format: "%.0f dB/mW · %.0f Ω", v, ohm)
        }
    }

    static let library: [WiredPreset] = [
        WiredPreset(
            id: "sony-mdr7506",
            manufacturer: "索尼",
            name: "MDR-7506（监听头戴）",
            sensitivity: .dbPerMilliwatt(value: 106, impedanceOhms: 63)
        ),
        WiredPreset(
            id: "sennheiser-hd600",
            manufacturer: "森海塞尔",
            name: "HD 600（开放头戴）",
            sensitivity: .dbPerMilliwatt(value: 97, impedanceOhms: 300)
        ),
        WiredPreset(
            id: "audio-technica-ath-m50x",
            manufacturer: "铁三角",
            name: "ATH-M50x（监听头戴）",
            sensitivity: .dbPerMilliwatt(value: 99, impedanceOhms: 38)
        ),
    ]
}

@MainActor
final class QuickSetupWizardViewModel: ObservableObject {
    enum Step: Equatable {
        case kind
        case wired
        case bluetooth
        case confirm
    }

    @Published var step: Step = .kind
    @Published var selectedKind: TransducerKind?
    @Published var selectedPreset: WiredPreset?
    /// 蓝牙/音箱引导式实测：系统音量 25% / 50% / 100% 时的 dBA 读数。
    @Published var btReadingsString: [String] = ["", "", ""]
    @Published var profileName = ""
    @Published var message = ""

    private let outputMonitor: OutputDeviceMonitor
    private let profiles: ProfileRepository

    var deviceName: String { outputMonitor.snapshot().name ?? "当前设备" }
    var deviceUID: String? { outputMonitor.snapshot().uid }

    var canSave: Bool {
        guard let uid = deviceUID, !uid.isEmpty else { return false }
        switch step {
        case .kind:
            return selectedKind != nil
        case .wired:
            return selectedPreset != nil
        case .bluetooth:
            return btReadings.count >= 1
        case .confirm:
            return (selectedKind == .wiredHeadphones && selectedPreset != nil)
                || (selectedKind == .calibratedDevice && btReadings.count >= 1)
        }
    }

    var btReadings: [(scalar: Float, dba: Float)] {
        let pairs: [(scalar: Float, index: Int)] = [(0.25, 0), (0.5, 1), (1.0, 2)]
        return pairs.compactMap { pair in
            let text = btReadingsString[safe: pair.index] ?? ""
            guard let value = Float(text), value.isFinite else { return nil }
            return (pair.scalar, value)
        }
    }

    init(outputMonitor: OutputDeviceMonitor, profiles: ProfileRepository) {
        self.outputMonitor = outputMonitor
        self.profiles = profiles
        profileName = outputMonitor.snapshot().name ?? "我的耳机"
    }

    func save() -> Bool {
        guard let uid = deviceUID, !uid.isEmpty else {
            message = "当前无法读取输出设备 UID，请先在高级选项中绑定。"
            return false
        }
        let profile: TransducerProfile
        switch selectedKind {
        case .wiredHeadphones:
            guard let preset = selectedPreset else { return false }
            profile = TransducerProfile(
                name: "\(preset.manufacturer) \(preset.name)",
                deviceUID: uid,
                kind: .wiredHeadphones,
                sensitivity: preset.sensitivity,
                outputSource: OutputSourceProfile(maxOutputVRMS: 1.0, volumeCurve: []),
                reference: "\(preset.manufacturer) \(preset.name) 官方标称参数（参考值）",
                isConfirmed: true
            )
        case .calibratedDevice:
            let points = btReadings.map {
                AcousticCalibrationPoint(volumeScalar: $0.scalar, fullScaleDBA: $0.dba)
            }
            guard !points.isEmpty else {
                message = "请至少填写一个音量档位的实测 dBA 读数。"
                return false
            }
            let name = profileName.trimmingCharacters(in: .whitespaces)
            profile = TransducerProfile(
                name: name.isEmpty ? deviceName : name,
                deviceUID: uid,
                kind: .calibratedDevice,
                acousticCalibrationPoints: points,
                reference: "用户使用分贝仪在 25%/50%/100% 系统音量实测",
                isConfirmed: true
            )
        case nil:
            return false
        }
        do {
            try profiles.save(profile)
            return true
        } catch {
            message = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct QuickSetupWizardView: View {
    @ObservedObject var viewModel: QuickSetupWizardViewModel
    let onSaved: () -> Void
    let onCancel: () -> Void

    private var stepTitle: String {
        switch viewModel.step {
        case .kind: "选择耳机类型"
        case .wired: "选择你的型号"
        case .bluetooth: "实测系统音量与响度"
        case .confirm: "确认并绑定"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快速设置 · \(stepTitle)")
                    .font(.headline)
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(.link)
            }

            Divider()

            switch viewModel.step {
            case .kind:
                kindStep
            case .wired:
                wiredStep
            case .bluetooth:
                bluetoothStep
            case .confirm:
                confirmStep
            }

            if !viewModel.message.isEmpty {
                Text(viewModel.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()
            HStack {
                if viewModel.step != .kind {
                    Button("上一步") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.step = viewModel.step == .confirm
                                ? (viewModel.selectedKind == .wiredHeadphones ? .wired : .bluetooth)
                                : .kind
                        }
                    }
                }
                Spacer()
                if viewModel.step == .confirm {
                    Button("保存并绑定当前设备") {
                        if viewModel.save() { onSaved() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            switch viewModel.step {
                            case .kind:
                                viewModel.step = viewModel.selectedKind == .wiredHeadphones ? .wired : .bluetooth
                            case .wired, .bluetooth:
                                viewModel.step = .confirm
                            case .confirm:
                                break
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSave)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var kindStep: some View {
        VStack(spacing: 10) {
            kindCard(
                title: "有线耳机",
                subtitle: "数据来自厂商规格，1 分钟内完成",
                isSelected: viewModel.selectedKind == .wiredHeadphones
            ) {
                viewModel.selectedKind = .wiredHeadphones
            }
            kindCard(
                title: "蓝牙耳机或音箱",
                subtitle: "需要 2~3 分钟，用手机分贝仪实测",
                isSelected: viewModel.selectedKind == .calibratedDevice
            ) {
                viewModel.selectedKind = .calibratedDevice
            }
        }
    }

    private func kindCard(
        title: String,
        subtitle: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var wiredStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择与你的耳机最接近的型号（参数均为官方标称，估算会标注为“参考值”）：")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(WiredPreset.library) { preset in
                presetRow(preset)
            }
            Button("我的型号不在列表中 → 去高级选项手动填写") {
                onCancel()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func presetRow(_ preset: WiredPreset) -> some View {
        Button {
            viewModel.selectedPreset = preset
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(preset.manufacturer) \(preset.name)")
                        .font(.body)
                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.selectedPreset?.id == preset.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        viewModel.selectedPreset?.id == preset.id
                            ? Color.accentColor.opacity(0.12)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bluetoothStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("耳机戴好（音箱摆平时听歌的位置），用手机装一个免费分贝仪 App（如 Decibel X），把手机放在耳旁 / 聆听位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("依次把系统音量调到 25%、50%、100%（菜单栏弹窗或键盘音量键），每次稳定 3 秒后记下一个 dBA 读数：")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(0..<3, id: \.self) { index in
                let labels = ["25% 音量", "50% 音量", "100% 音量"]
                HStack {
                    Text(labels[index]).frame(width: 90, alignment: .leading)
                    TextField("如 62", text: $viewModel.btReadingsString[index])
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("dBA").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Text("三个档位都填效果最好；至少填一个即可开始估算（档位越少精度越低）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryRow("设备", value: viewModel.deviceName)
            summaryRow("类型", value: viewModel.selectedKind?.displayName ?? "")
            switch viewModel.selectedKind {
            case .wiredHeadphones:
                summaryRow("型号", value: viewModel.selectedPreset.map { "\($0.manufacturer) \($0.name) — \($0.summary)" } ?? "")
                summaryRow("说明", value: "按典型 1.0 Vrms 输出估算；可在高级选项微调最大输出与音量曲线。")
            case .calibratedDevice:
                summaryRow("校准点", value: viewModel.btReadings
                    .map { String(format: "%.0f%% = %.0f dBA", $0.scalar * 100, $0.dba) }
                    .joined(separator: " · "))
                TextField("档案名称", text: $viewModel.profileName)
                    .textFieldStyle(.roundedBorder)
            case nil:
                EmptyView()
            }
            Text("保存后，本设备将立即开始 dBA 估算。已有档案会被覆盖。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }
}
