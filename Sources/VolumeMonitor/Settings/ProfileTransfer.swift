import Foundation

/// 设备档案 + EM258 校准的导出包。换电脑时设备 UID 会变，导入时由用户重新绑定。
struct ProfileExportBundle: Codable, Sendable, Equatable {
    static let formatIdentifier = "VolumeMonitor.profiles"

    var format = ProfileExportBundle.formatIdentifier
    var version = 1
    var exportedAt: Date
    var profiles: [TransducerProfile]
    var calibrations: [CalibrationProfile]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ProfileExportBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(ProfileExportBundle.self, from: data)
        guard bundle.format == formatIdentifier else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "不是音量监测导出的档案文件"
            ])
        }
        guard bundle.version == 1 else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "档案文件版本 \(bundle.version) 不受支持"
            ])
        }
        return bundle
    }

    /// 某个耳机档案的校准；改绑设备时一并把校准的输出设备改过去。
    func calibrations(
        for profile: TransducerProfile,
        reboundTo newUID: String? = nil,
        deviceName: String? = nil
    ) -> [CalibrationProfile] {
        calibrations
            .filter { $0.headphoneProfileID == profile.id }
            .map { calibration in
                guard let newUID, calibration.outputDeviceUID == profile.deviceUID else {
                    return calibration
                }
                var rebound = calibration
                rebound.outputDeviceUID = newUID
                rebound.outputDeviceName = deviceName ?? newUID
                return rebound
            }
    }
}
