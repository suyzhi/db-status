import Combine
import SwiftUI

struct DeviceCardInfo: Identifiable {
    enum BadgeStyle { case measured, calibrated, warning, neutral }

    var id: String { deviceUID }
    let deviceUID: String
    let title: String
    let subtitle: String
    let isCurrent: Bool
    let hasProfile: Bool
    let canCalibrate: Bool
    let badge: String
    let badgeStyle: BadgeStyle
    let facts: [(label: String, value: String)]
    let checks: [String]
    let issue: String?
}

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var cards: [DeviceCardInfo] = []

    private let profiles: ProfileRepository
    private let calibrationStore: CalibrationStore
    private let outputMonitor: OutputDeviceMonitor

    init(profiles: ProfileRepository, calibrationStore: CalibrationStore, outputMonitor: OutputDeviceMonitor) {
        self.profiles = profiles
        self.calibrationStore = calibrationStore
        self.outputMonitor = outputMonitor
    }

    func reload() {
        let current = outputMonitor.snapshot()
        var result = profiles.allProfiles.map { card(for: $0, current: current) }
        if let uid = current.uid, !result.contains(where: { $0.deviceUID == uid }) {
            result.append(DeviceCardInfo(
                deviceUID: uid,
                title: current.name ?? uid,
                subtitle: "当前输出 · 尚未配置档案",
                isCurrent: true,
                hasProfile: false,
                canCalibrate: false,
                badge: "未配置",
                badgeStyle: .warning,
                facts: [],
                checks: [],
                issue: nil
            ))
        }
        cards = result.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func card(for profile: TransducerProfile, current: OutputDeviceSnapshot) -> DeviceCardInfo {
        let isCurrent = profile.deviceUID == current.uid
        var facts: [(String, String)] = []
        var checks: [String] = []
        var badge = "规格估算"
        var style = DeviceCardInfo.BadgeStyle.neutral
        var issue: String?

        switch profile.kind {
        case .wiredHeadphones:
            switch profile.sensitivity {
            case .dbPerVolt(let value):
                facts.append(("灵敏度", "\(Self.number(value)) dB/V @ \(Int(profile.sensitivityReferenceHz ?? 1_000)) Hz"))
            case .dbPerMilliwatt(let value, let impedance):
                facts.append(("灵敏度", "\(Self.number(value)) dB/mW · \(Self.number(impedance)) Ω"))
            case nil:
                break
            }
            if let source = profile.outputSource {
                facts.append(("最大输出", "\(Self.number(source.maxOutputVRMS)) Vrms"))
            }
        case .calibratedDevice:
            badge = "声学校准点"
            facts.append(("校准点", "\(profile.acousticCalibrationPoints.count) 个"))
        }
        if let offset = profile.calibration?.offsetDB {
            facts.append(("手动偏移", String(format: "%+.1f dB", offset)))
        }

        switch calibrationStore.resolution(headphoneProfileID: profile.id, outputDeviceUID: profile.deviceUID) {
        case .active(let calibration):
            if calibration.frequencyCalibrationUsable {
                checks.append("频响 \(calibration.frequencyPoints.count) 点")
            }
            if calibration.volumeCalibrationUsable {
                checks.append(calibration.volumeCurveCoversFullScale ? "音量曲线 25%~100%" : "音量曲线 30%~70%（旧版）")
            }
            if calibration.absoluteCalibrationMode == .acousticReference,
               calibration.absoluteValidationIssue == nil,
               let reference = calibration.acousticReference {
                checks.append("手机对标：\(reference.referenceDescription)")
                facts.append(("50% 音量满幅", String(format: "%.1f dB SPL", reference.fullScaleRMSSPLAtReferenceVolume)))
                badge = "实测绝对校准"
                style = .measured
            } else {
                checks.append("绝对值按耳机规格换算")
                badge = "已校准"
                style = .calibrated
            }
            facts.append(("校准日期", calibration.createdAt.formatted(date: .abbreviated, time: .omitted)))
        case .invalid(let reason):
            badge = "校准不可用"
            style = .warning
            issue = reason
        case .outputMismatch, .notCalibrated:
            break
        }

        return DeviceCardInfo(
            deviceUID: profile.deviceUID,
            title: profile.name,
            subtitle: isCurrent ? "\(current.name ?? "当前设备") · 当前输出" : profile.deviceUID,
            isCurrent: isCurrent,
            hasProfile: true,
            canCalibrate: isCurrent && profile.kind == .wiredHeadphones,
            badge: badge,
            badgeStyle: style,
            facts: facts,
            checks: checks,
            issue: issue
        )
    }

    private static func number(_ value: Float) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

struct DevicesPage: View {
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var devices: DevicesModel
    let onShowCalibration: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "设备与校准", subtitle: "档案按 CoreAudio 设备 UID 绑定")
                    .appearAnimation()
                ForEach(Array(devices.cards.enumerated()), id: \.element.id) { index, card in
                    DeviceCard(
                        card: card,
                        onCalibrate: onShowCalibration,
                        onQuickSetup: { settings.showQuickSetup = true },
                        onEdit: { settings.beginEditing(deviceUID: card.deviceUID) }
                    )
                    .appearAnimation(delay: 0.04 * Double(min(index + 1, 6)))
                }
                HStack(spacing: 8) {
                    Button("导入档案…") { settings.importProfiles() }
                    Button("导出档案…") { settings.exportProfiles() }
                    Text("包含全部设备档案与 EM258 校准，换电脑导入即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
    }
}

private struct DeviceCard: View {
    let card: DeviceCardInfo
    let onCalibrate: () -> Void
    let onQuickSetup: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: card.isCurrent ? "headphones" : "hifispeaker")
                    .font(.system(size: 20))
                    .foregroundStyle(card.isCurrent ? Theme.accent : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 15, weight: .semibold))
                    Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(card.badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badgeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badgeBackground, in: Capsule())
            }
            if !card.facts.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 10) {
                    ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label).font(.caption).foregroundStyle(.secondary)
                            Text(fact.value).font(.callout.monospacedDigit())
                        }
                    }
                }
            }
            if !card.checks.isEmpty {
                HStack(spacing: 16) {
                    ForEach(card.checks, id: \.self) { check in
                        Label(check, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.safe)
                    }
                }
            }
            if let issue = card.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.caution)
            }
            HStack(spacing: 8) {
                if !card.hasProfile {
                    Button("快速设置…", action: onQuickSetup).buttonStyle(.borderedProminent)
                    Button("手动填写参数…", action: onEdit)
                } else {
                    if card.canCalibrate {
                        Button(card.checks.isEmpty ? "开始校准…" : "重新校准…", action: onCalibrate)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("编辑参数…", action: onEdit)
                    if !card.isCurrent {
                        Text("切换到该设备后可以校准")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card(padding: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(card.isCurrent ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1.5)
        )
    }

    private var badgeBackground: Color {
        switch card.badgeStyle {
        case .measured: Theme.safeChip
        case .calibrated: Theme.accent
        case .warning: Theme.cautionChip
        case .neutral: Theme.track
        }
    }

    private var badgeForeground: Color {
        card.badgeStyle == .neutral ? .primary : .white
    }
}

/// 编辑一个设备档案的全部参数。只在需要时弹出，平时不常驻。
struct ProfileEditorSheet: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.editingExists ? "编辑档案" : "新建档案").font(.headline)
                    Text("\(settings.deviceName) · \(settings.deviceUID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(20)
            Form {
                Section {
                    TextField("档案名称", text: $settings.profileName)
                    Picker("档案类型", selection: $settings.kind) {
                        ForEach(TransducerKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                if settings.kind == .wiredHeadphones {
                    Section {
                        Picker("灵敏度单位", selection: $settings.sensitivityUnit) {
                            Text("dB/V").tag("dbPerVolt")
                            Text("dB/mW").tag("dbPerMilliwatt")
                        }
                        TextField("灵敏度数值", text: $settings.sensitivityValue)
                        if settings.sensitivityUnit == "dbPerMilliwatt" {
                            TextField("阻抗 (Ω)", text: $settings.impedanceOhms)
                        }
                        TextField("灵敏度测量频率 (Hz)", text: $settings.sensitivityReferenceHz)
                        TextField("输出源最大 Vrms", text: $settings.maxOutputVRMS)
                        TextField("音量曲线（可选）", text: $settings.volumeCurveText)
                    } header: {
                        Text("耳机规格")
                    } footer: {
                        Text("测量频率按规格填写，例如“110 dB @ 1 V / 500 Hz”填 500。音量曲线例如 25=-32, 50=-19, 100=0；有 EM258 校准时以实测为准。")
                    }
                } else {
                    Section {
                        TextField("音量%=dBA", text: $settings.acousticPointsText)
                    } header: {
                        Text("声学校准点")
                    } footer: {
                        Text("例如 25=70, 50=82, 100=96；请使用可追溯的参考测量，扬声器需在固定聆听位置校准。")
                    }
                }
                Section {
                    TextField("手动校准偏移 (dB，可选)", text: $settings.calibrationOffsetDB)
                    TextField("规格/校准来源（必填）", text: $settings.reference)
                } footer: {
                    Text(settings.calibrationStatus)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                if settings.editingExists {
                    Button("删除档案", role: .destructive) { settings.removeProfile() }
                }
                if settings.hasCurrentCalibration {
                    Button("删除 EM258 校准", role: .destructive) { settings.removeCalibration() }
                }
                Spacer()
                Button("取消") { settings.showEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { settings.saveProfile() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 540, height: 620)
    }
}
