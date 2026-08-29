import Foundation

enum AbsoluteCalibrationMode: String, Codable, Sendable, Equatable {
    case estimatedFromHeadphoneModel
    case acousticReference
}

struct CalibrationInputChainFingerprint: Codable, Sendable, Equatable {
    let deviceUID: String
    let sampleRate: Double
    let channelCount: Int
    let formatDescription: String
    let inputGainScalar: Float?

    func matchesCurrentInputChain(
        _ current: CalibrationInputChainFingerprint,
        gainTolerance: Float = 0.02
    ) -> Bool {
        guard deviceUID == current.deviceUID,
              abs(sampleRate - current.sampleRate) < 0.5,
              channelCount == current.channelCount,
              formatDescription == current.formatDescription else {
            return false
        }
        switch (inputGainScalar, current.inputGainScalar) {
        case (.none, .none):
            return true
        case let (.some(expected), .some(actual)):
            return abs(expected - actual) <= gainTolerance
        default:
            return false
        }
    }
}

struct FrequencyCalibrationPoint: Codable, Sendable, Equatable, Identifiable {
    var id: Double { frequencyHz }
    let frequencyHz: Double
    let relativeDB: Double
    let stabilityDB: Double
    let measuredLevelDBFS: Double?

    init(
        frequencyHz: Double,
        relativeDB: Double,
        stabilityDB: Double,
        measuredLevelDBFS: Double? = nil
    ) {
        self.frequencyHz = frequencyHz
        self.relativeDB = relativeDB
        self.stabilityDB = stabilityDB
        self.measuredLevelDBFS = measuredLevelDBFS
    }
}

struct VolumeCalibrationPoint: Codable, Sendable, Equatable, Identifiable {
    var id: Float { systemVolume }
    let systemVolume: Float
    let relativeDB: Double
    let stabilityDB: Double
    let measuredLevelDBFS: Double?

    init(
        systemVolume: Float,
        relativeDB: Double,
        stabilityDB: Double,
        measuredLevelDBFS: Double? = nil
    ) {
        self.systemVolume = systemVolume
        self.relativeDB = relativeDB
        self.stabilityDB = stabilityDB
        self.measuredLevelDBFS = measuredLevelDBFS
    }
}

struct MicrophoneResponsePoint: Codable, Sendable, Equatable, Identifiable {
    var id: Double { frequencyHz }
    let frequencyHz: Double
    /// Correction to add to the measured microphone level at this frequency.
    let correctionDB: Double
}

struct MicrophoneResponseProfile: Codable, Sendable, Equatable {
    var name: String
    var isIndividuallyCalibrated: Bool
    var points: [MicrophoneResponsePoint]

    static let em258NominalUncorrected = MicrophoneResponseProfile(
        name: "EM258 标称频响（无个体校准文件）",
        isIndividuallyCalibrated: false,
        points: []
    )
}

struct CalibrationQuality: Codable, Sendable, Equatable {
    var averageStabilityDB: Double
    var maximumStabilityDB: Double
    var minimumSNRDB: Double
    var relativeValidationErrorDB: Double?

    static let unmeasured = CalibrationQuality(
        averageStabilityDB: 0,
        maximumStabilityDB: 0,
        minimumSNRDB: 0,
        relativeValidationErrorDB: nil
    )

    var grade: CalibrationQualityGrade {
        guard let validation = relativeValidationErrorDB else { return .poor }
        if minimumSNRDB >= 25, maximumStabilityDB <= 0.3, validation <= 1.0 {
            return .excellent
        }
        if minimumSNRDB >= 20, maximumStabilityDB <= 0.5, validation <= 1.5 {
            return .good
        }
        if minimumSNRDB >= 15, maximumStabilityDB <= 0.7, validation <= 2.0 {
            return .acceptable
        }
        return .poor
    }
}

enum CalibrationQualityGrade: String, Codable, Sendable, Equatable, CaseIterable {
    case excellent
    case good
    case acceptable
    case poor

    var displayName: String {
        switch self {
        case .excellent: "优秀"
        case .good: "良好"
        case .acceptable: "可用"
        case .poor: "较差"
        }
    }
}

enum CalibrationValidationPolicy {
    static func canSave(relativeValidationErrorDB: Double?) -> Bool {
        guard let error = relativeValidationErrorDB, error.isFinite else { return false }
        return error <= 2.0
    }
}

struct CalibrationProfile: Codable, Sendable, Equatable, Identifiable {
    static let currentVersion = 1
    static let requiredFrequenciesHz: [Double] = [63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 12_000]
    static let requiredVolumes: [Float] = [0.3, 0.5, 0.7]

    var version: Int
    var id: UUID
    var headphoneProfileID: UUID
    var headphoneName: String
    var outputDeviceUID: String
    var outputDeviceName: String
    var inputDeviceUID: String?
    var inputDeviceName: String?
    var inputChainFingerprint: CalibrationInputChainFingerprint?
    var createdAt: Date
    var referenceVolume: Float
    var testSignalRMSDBFS: Double
    var frequencyPoints: [FrequencyCalibrationPoint]
    var volumePoints: [VolumeCalibrationPoint]
    var frequencyCalibrationValid: Bool
    var volumeCalibrationValid: Bool
    var absoluteCalibrationMode: AbsoluteCalibrationMode
    var microphoneResponse: MicrophoneResponseProfile
    var quality: CalibrationQuality

    init(
        version: Int = CalibrationProfile.currentVersion,
        id: UUID = UUID(),
        headphoneProfileID: UUID,
        headphoneName: String,
        outputDeviceUID: String,
        outputDeviceName: String,
        inputDeviceUID: String? = nil,
        inputDeviceName: String? = nil,
        inputChainFingerprint: CalibrationInputChainFingerprint? = nil,
        createdAt: Date = .now,
        referenceVolume: Float = 0.5,
        testSignalRMSDBFS: Double = -35,
        frequencyPoints: [FrequencyCalibrationPoint] = [],
        volumePoints: [VolumeCalibrationPoint] = [],
        frequencyCalibrationValid: Bool = false,
        volumeCalibrationValid: Bool = false,
        absoluteCalibrationMode: AbsoluteCalibrationMode = .estimatedFromHeadphoneModel,
        microphoneResponse: MicrophoneResponseProfile = .em258NominalUncorrected,
        quality: CalibrationQuality = .unmeasured
    ) {
        self.version = version
        self.id = id
        self.headphoneProfileID = headphoneProfileID
        self.headphoneName = headphoneName
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceName = inputDeviceName
        self.inputChainFingerprint = inputChainFingerprint
        self.createdAt = createdAt
        self.referenceVolume = referenceVolume
        self.testSignalRMSDBFS = testSignalRMSDBFS
        self.frequencyPoints = frequencyPoints
        self.volumePoints = volumePoints
        self.frequencyCalibrationValid = frequencyCalibrationValid
        self.volumeCalibrationValid = volumeCalibrationValid
        self.absoluteCalibrationMode = absoluteCalibrationMode
        self.microphoneResponse = microphoneResponse
        self.quality = quality
    }

    var frequencyCalibrationUsable: Bool {
        frequencyCalibrationValid && frequencyValidationIssue == nil && commonValidationIssue == nil
    }

    var volumeCalibrationUsable: Bool {
        volumeCalibrationValid && volumeValidationIssue == nil && commonValidationIssue == nil
    }

    var isUsable: Bool {
        frequencyCalibrationUsable || volumeCalibrationUsable
    }

    var commonValidationIssue: String? {
        guard version == Self.currentVersion else { return "不支持的校准版本 \(version)" }
        guard !headphoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "耳机名称为空"
        }
        guard !outputDeviceUID.isEmpty else { return "输出设备 UID 为空" }
        guard (0...1).contains(referenceVolume), referenceVolume.isFinite else {
            return "参考音量无效"
        }
        guard testSignalRMSDBFS.isFinite, testSignalRMSDBFS <= 0 else {
            return "测试信号电平无效"
        }
        let qualityValues = [quality.averageStabilityDB, quality.maximumStabilityDB, quality.minimumSNRDB]
        guard qualityValues.allSatisfy(\.isFinite),
              quality.relativeValidationErrorDB?.isFinite != false else {
            return "质量数据包含非有限数值"
        }
        return nil
    }

    var frequencyValidationIssue: String? {
        guard frequencyCalibrationValid else { return nil }
        guard frequencyPoints.allSatisfy({
            $0.frequencyHz.isFinite && $0.frequencyHz > 0 &&
            $0.relativeDB.isFinite && $0.stabilityDB.isFinite &&
            $0.measuredLevelDBFS?.isFinite != false
        }) else { return "频率校准包含无效数值" }
        let sorted = frequencyPoints.sorted { $0.frequencyHz < $1.frequencyHz }
        guard sorted.count == Self.requiredFrequenciesHz.count else { return "频率点数量不完整" }
        for (actual, expected) in zip(sorted.map(\.frequencyHz), Self.requiredFrequenciesHz) {
            guard abs(actual - expected) < 0.5 else { return "缺少 \(Int(expected)) Hz 频率点" }
        }
        guard let reference = sorted.first(where: { abs($0.frequencyHz - 1_000) < 0.5 }),
              abs(reference.relativeDB) <= 0.2 else {
            return "1 kHz 频率点没有归一化为 0 dB"
        }
        return nil
    }

    var volumeValidationIssue: String? {
        guard volumeCalibrationValid else { return nil }
        guard volumePoints.allSatisfy({
            $0.systemVolume.isFinite && (0...1).contains($0.systemVolume) &&
            $0.relativeDB.isFinite && $0.stabilityDB.isFinite &&
            $0.measuredLevelDBFS?.isFinite != false
        }) else { return "音量校准包含无效数值" }
        let sorted = volumePoints.sorted { $0.systemVolume < $1.systemVolume }
        guard sorted.count == Self.requiredVolumes.count else { return "音量点数量不完整" }
        for (actual, expected) in zip(sorted.map(\.systemVolume), Self.requiredVolumes) {
            guard abs(actual - expected) < 0.002 else { return "缺少 \(Int(expected * 100))% 音量点" }
        }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.relativeDB <= $1.relativeDB }) else {
            return "实测音量曲线不是单调递增"
        }
        guard let reference = sorted.first(where: { abs($0.systemVolume - referenceVolume) < 0.002 }),
              abs(reference.relativeDB) <= 0.2 else {
            return "参考音量没有归一化为 0 dB"
        }
        guard CalibrationValidationPolicy.canSave(
            relativeValidationErrorDB: quality.relativeValidationErrorDB
        ) else {
            return "相对音量曲线验证误差超过 2 dB"
        }
        return nil
    }

    var validationIssues: [String] {
        [commonValidationIssue, frequencyValidationIssue, volumeValidationIssue].compactMap { $0 }
    }
}
