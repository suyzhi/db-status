import Foundation

private struct CalibrationStoreState: Codable {
    var schemaVersion: Int
    var profiles: [CalibrationProfile]
}

enum CalibrationStoreError: LocalizedError {
    case invalidProfile(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let reason): "校准配置无效：\(reason)"
        }
    }
}

enum CalibrationResolution: Equatable {
    case active(CalibrationProfile)
    case outputMismatch(expectedDeviceName: String)
    case invalid(String)
    case notCalibrated
}

@MainActor
final class CalibrationStore {
    static let shared = CalibrationStore()
    static let schemaVersion = 1

    private(set) var profiles: [CalibrationProfile] = []
    private(set) var lastLoadWarning: String?
    let fileURL: URL?

    init(fileURL: URL? = CalibrationStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    func resolution(
        headphoneProfileID: UUID?,
        outputDeviceUID: String?
    ) -> CalibrationResolution {
        guard let headphoneProfileID else { return .notCalibrated }
        let candidates = profiles
            .filter { $0.headphoneProfileID == headphoneProfileID }
            .sorted { $0.createdAt > $1.createdAt }
        guard !candidates.isEmpty else { return .notCalibrated }
        guard let outputDeviceUID else {
            return .outputMismatch(expectedDeviceName: candidates[0].outputDeviceName)
        }
        guard let matching = candidates.first(where: { $0.outputDeviceUID == outputDeviceUID }) else {
            return .outputMismatch(expectedDeviceName: candidates[0].outputDeviceName)
        }
        if let issue = matching.commonValidationIssue
            ?? matching.frequencyValidationIssue
            ?? matching.volumeValidationIssue {
            return .invalid(issue)
        }
        return matching.isUsable ? .active(matching) : .invalid("配置没有可用的相对校准数据")
    }

    func profile(headphoneProfileID: UUID, outputDeviceUID: String) -> CalibrationProfile? {
        guard case .active(let profile) = resolution(
            headphoneProfileID: headphoneProfileID,
            outputDeviceUID: outputDeviceUID
        ) else { return nil }
        return profile
    }

    func save(_ profile: CalibrationProfile) throws {
        guard profile.absoluteCalibrationMode == .estimatedFromHeadphoneModel else {
            throw CalibrationStoreError.invalidProfile("当前版本尚未实现绝对声学参考模式")
        }
        guard profile.isUsable else {
            let reason = profile.validationIssues.first ?? "没有通过有效性检查"
            throw CalibrationStoreError.invalidProfile(reason)
        }
        profiles.removeAll {
            $0.id == profile.id || (
                $0.headphoneProfileID == profile.headphoneProfileID &&
                $0.outputDeviceUID == profile.outputDeviceUID
            )
        }
        profiles.append(profile)
        try persist()
    }

    func remove(headphoneProfileID: UUID, outputDeviceUID: String) throws {
        profiles.removeAll {
            $0.headphoneProfileID == headphoneProfileID &&
            $0.outputDeviceUID == outputDeviceUID
        }
        try persist()
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(CalibrationStoreState.self, from: data)
            guard state.schemaVersion == Self.schemaVersion else {
                lastLoadWarning = "校准文件版本不兼容，已使用标准估算模式"
                return
            }
            profiles = state.profiles
        } catch {
            profiles = []
            lastLoadWarning = "校准文件无法读取，已使用标准估算模式：\(error.localizedDescription)"
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let state = CalibrationStoreState(
            schemaVersion: Self.schemaVersion,
            profiles: profiles.sorted { $0.createdAt < $1.createdAt }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: fileURL, options: [.atomic])
    }

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("VolumeMonitor", isDirectory: true)
            .appendingPathComponent("calibration-profiles.json")
    }
}
