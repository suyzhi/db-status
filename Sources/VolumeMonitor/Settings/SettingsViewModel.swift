import AppKit
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

/// 设备、档案、偏好的编辑状态。主窗口的“设备与校准”“通用”两页共用。
/// 编辑目标默认是当前输出设备，也可以用 beginEditing(deviceUID:) 改为任一已保存的档案。
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var deviceName = "不可用"
    @Published var deviceUID = ""
    @Published var profileName = ""
    @Published var kind: TransducerKind = .wiredHeadphones
    @Published var sensitivityUnit = "dbPerVolt"
    @Published var sensitivityValue = ""
    @Published var impedanceOhms = ""
    @Published var sensitivityReferenceHz = "1000"
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
    @Published var calibrationStatus = "未校准 · 当前使用标准估算模式"
    @Published var hasCurrentCalibration = false
    @Published var showQuickSetup = false
    @Published var showEditor = false
    /// 档案或校准有变化时加一，设备列表据此刷新。
    @Published var revision = 0
    /// 正在编辑的档案是否已存在（新设备时为 false）。
    @Published var editingExists = false

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

    /// 重新读取偏好，并把编辑目标设为当前输出设备。
    func reloadCurrentDevice() {
        let device = outputMonitor.snapshot()
        monitoringEnabled = preferences.monitoringEnabled
        exposureMode = preferences.exposureMode
        statusBarDisplayMode = preferences.statusBarDisplayMode
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loadFields(deviceUID: device.uid ?? "", deviceName: device.name)
    }

    /// 编辑某个已保存的档案（可以不是当前输出设备）。
    func beginEditing(deviceUID uid: String) {
        let current = outputMonitor.snapshot()
        loadFields(deviceUID: uid, deviceName: uid == current.uid ? current.name : nil)
        showEditor = true
    }

    private func loadFields(deviceUID uid: String, deviceName name: String?) {
        deviceUID = uid
        let profile = uid.isEmpty ? nil : profiles.profile(for: uid)
        deviceName = name ?? profile?.name ?? (uid.isEmpty ? "不可用" : uid)
        editingExists = profile != nil
        guard let profile else {
            calibrationStatus = "未校准 · 当前使用标准估算模式"
            hasCurrentCalibration = false
            editingProfileID = UUID()
            profileName = name ?? ""
            kind = .wiredHeadphones
            sensitivityUnit = "dbPerVolt"
            sensitivityValue = ""
            impedanceOhms = ""
            sensitivityReferenceHz = "1000"
            maxOutputVRMS = "1.0"
            volumeCurveText = ""
            acousticPointsText = ""
            calibrationOffsetDB = ""
            reference = ""
            return
        }

        editingProfileID = profile.id
        reloadCalibrationStatus(profile: profile, outputUID: uid)
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
        sensitivityReferenceHz = format(Float(profile.sensitivityReferenceHz ?? 1_000))
        maxOutputVRMS = profile.outputSource.map { format($0.maxOutputVRMS) } ?? "1.0"
        volumeCurveText = profile.outputSource?.volumeCurve
            .map { "\(Int(($0.volumeScalar * 100).rounded()))=\(format($0.attenuationDB))" }
            .joined(separator: ", ") ?? ""
        acousticPointsText = profile.acousticCalibrationPoints
            .map { "\(Int(($0.volumeScalar * 100).rounded()))=\(format($0.fullScaleDBA))" }
            .joined(separator: ", ")
        calibrationOffsetDB = profile.calibration.map { format($0.offsetDB) } ?? ""
        reference = profile.reference
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

        // 偏移没改时保留原记录日期，日期才能反映"偏移是什么时候填的"。
        let existingCalibration = profiles.profile(for: deviceUID)?.calibration
        let calibration = Float(calibrationOffsetDB).map { offset in
            if let existingCalibration, existingCalibration.offsetDB == offset {
                return existingCalibration
            }
            return CalibrationRecord(offsetDB: offset, date: .now, reference: reference)
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
            guard let referenceHz = Double(sensitivityReferenceHz), (20...20_000).contains(referenceHz) else {
                message = "灵敏度测量频率需在 20~20000 Hz 之间（不确定就填 1000）"
                return
            }
            profile.sensitivityReferenceHz = referenceHz
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

        let previousOffset = existingCalibration?.offsetDB
        let newOffset = profile.calibration?.offsetDB
        do {
            try profiles.save(profile)
            if previousOffset != newOffset {
                try? LocalDataStore.shared.addAnnotation(ExposureAnnotation(
                    title: "校准偏移变更",
                    detail: "\(profile.name)：\(Self.offsetText(previousOffset)) → \(Self.offsetText(newOffset))；此后该设备的数值口径随之改变"
                ))
                reloadHistory()
            }
            editingExists = true
            revision += 1
            showEditor = false
            message = "档案「\(profile.name)」已保存"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    func removeProfile() {
        guard !deviceUID.isEmpty else { return }
        do {
            let name = profileName
            try profiles.removeProfile(for: deviceUID)
            revision += 1
            showEditor = false
            reloadCurrentDevice()
            message = "已删除档案「\(name)」，该设备不再估算 dBA"
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
            try? LocalDataStore.shared.addAnnotation(ExposureAnnotation(
                title: "删除 EM258 校准",
                detail: "\(profile.name)：恢复按耳机规格估算；此后该设备的数值口径随之改变"
            ))
            revision += 1
            message = "已删除「\(profile.name)」的 EM258 校准，恢复按规格估算"
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
        reloadHistory()
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

    func exportProfiles() {
        let panel = NSSavePanel()
        panel.title = "导出设备档案与校准"
        panel.nameFieldStringValue = "VolumeMonitor-档案.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = ProfileExportBundle(
            exportedAt: .now,
            profiles: profiles.allProfiles,
            calibrations: calibrationStore.profiles
        )
        do {
            try bundle.encoded().write(to: url, options: [.atomic])
            message = "已导出 \(bundle.profiles.count) 个档案、\(bundle.calibrations.count) 个校准"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    func importProfiles() {
        let panel = NSOpenPanel()
        panel.title = "导入设备档案与校准"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle: ProfileExportBundle
        do {
            bundle = try ProfileExportBundle.decode(Data(contentsOf: url))
        } catch {
            message = "导入失败：\(error.localizedDescription)"
            return
        }

        let current = outputMonitor.snapshot()
        var importedNames: [String] = []
        var calibrationCount = 0
        var problems: [String] = []
        for original in bundle.profiles {
            var profile = original
            var reboundUID: String?
            if let currentUID = current.uid, original.deviceUID != currentUID {
                switch askBinding(for: original, currentUID: currentUID, currentName: current.name) {
                case .bindToCurrent:
                    profile.deviceUID = currentUID
                    reboundUID = currentUID
                case .keepOriginal:
                    break
                case .skip:
                    continue
                }
            }
            do {
                try profiles.save(profile)
                importedNames.append(profile.name)
            } catch {
                problems.append("\(profile.name)：\(error.localizedDescription)")
                continue
            }
            for calibration in bundle.calibrations(for: original, reboundTo: reboundUID, deviceName: current.name) {
                do {
                    try calibrationStore.save(calibration)
                    calibrationCount += 1
                } catch {
                    problems.append("\(profile.name) 的校准：\(error.localizedDescription)")
                }
            }
        }

        if !importedNames.isEmpty {
            try? LocalDataStore.shared.addAnnotation(ExposureAnnotation(
                title: "导入档案",
                detail: "\(importedNames.joined(separator: "、"))（含 \(calibrationCount) 个校准）；此后相关设备的数值口径随之改变"
            ))
        }
        reloadCurrentDevice()
        revision += 1
        message = (["已导入 \(importedNames.count) 个档案、\(calibrationCount) 个校准"] + problems)
            .joined(separator: "；")
    }

    private enum ImportBinding { case bindToCurrent, keepOriginal, skip }

    private func askBinding(
        for profile: TransducerProfile,
        currentUID: String,
        currentName: String?
    ) -> ImportBinding {
        let alert = NSAlert()
        alert.messageText = "导入「\(profile.name)」"
        var info = "档案原来绑定的设备 UID：\(profile.deviceUID)\n当前输出设备：\(currentName ?? currentUID)"
        if let existing = profiles.profile(for: currentUID), existing.id != profile.id {
            info += "\n\n绑定到当前设备会替换它现有的档案「\(existing.name)」。"
        }
        alert.informativeText = info + "\n\n换了电脑或转接头时，设备 UID 通常会变。"
        alert.addButton(withTitle: "绑定到当前输出设备")
        alert.addButton(withTitle: "保留原设备 UID")
        alert.addButton(withTitle: "跳过")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .bindToCurrent
        case .alertSecondButtonReturn: return .keepOriginal
        default: return .skip
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

    /// CSV 导出用的过去 7 天分钟明细。
    private func reloadHistory(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        historyPoints = LocalDataStore.shared.exposureBuckets
            .filter { $0.minute >= cutoff && $0.measuredDuration > 0 }
            .sorted { $0.minute < $1.minute }
            .compactMap { bucket in
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
            let absolute: String
            if calibration.absoluteCalibrationMode == .acousticReference,
               calibration.absoluteValidationIssue == nil,
               let reference = calibration.acousticReference {
                absolute = "手机对标实测（\(reference.referenceDescription)）"
            } else if calibration.volumeCurveCoversFullScale {
                absolute = "按耳机规格换算"
            } else {
                absolute = "参数估算（旧版 3 点曲线，建议重新校准）"
            }
            let volumeRange = calibration.volumeCurveCoversFullScale ? "25%~100%" : "30%~70%"
            calibrationStatus = "频响：EM258 实测 · 音量曲线：EM258 实测 \(volumeRange) · 绝对 SPL：\(absolute) · \(calibration.createdAt.formatted(date: .abbreviated, time: .shortened))"
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

    private static func offsetText(_ offset: Float?) -> String {
        guard let offset else { return "无" }
        return String(format: "%+.1f dB", offset)
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
