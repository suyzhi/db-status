import Foundation

enum SensitivitySpec: Codable, Sendable, Equatable {
    case dbPerVolt(Float)
    case dbPerMilliwatt(value: Float, impedanceOhms: Float)

    var dbPerVolt: Float? {
        switch self {
        case .dbPerVolt(let value):
            return value
        case .dbPerMilliwatt(let value, let impedanceOhms):
            guard impedanceOhms > 0 else { return nil }
            return value + 10 * log10(1_000 / impedanceOhms)
        }
    }
}

enum TransducerKind: String, Codable, Sendable, CaseIterable {
    case wiredHeadphones
    case calibratedDevice

    var displayName: String {
        switch self {
        case .wiredHeadphones: "有线耳机 / 电气模型"
        case .calibratedDevice: "蓝牙耳机或扬声器 / 声学校准"
        }
    }
}

struct VolumeCurvePoint: Codable, Sendable, Equatable, Identifiable {
    var id: Float { volumeScalar }
    let volumeScalar: Float
    let attenuationDB: Float
}

struct AcousticCalibrationPoint: Codable, Sendable, Equatable, Identifiable {
    var id: Float { volumeScalar }
    let volumeScalar: Float
    let fullScaleDBA: Float
}

struct OutputSourceProfile: Codable, Sendable, Equatable {
    let maxOutputVRMS: Float
    let volumeCurve: [VolumeCurvePoint]
}

struct CalibrationRecord: Codable, Sendable, Equatable {
    let offsetDB: Float
    let date: Date
    let reference: String
}

struct TransducerProfile: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var deviceUID: String
    var kind: TransducerKind
    var sensitivity: SensitivitySpec?
    var outputSource: OutputSourceProfile?
    var acousticCalibrationPoints: [AcousticCalibrationPoint]
    var calibration: CalibrationRecord?
    var reference: String
    var isConfirmed: Bool

    init(
        id: UUID = UUID(),
        name: String,
        deviceUID: String,
        kind: TransducerKind,
        sensitivity: SensitivitySpec? = nil,
        outputSource: OutputSourceProfile? = nil,
        acousticCalibrationPoints: [AcousticCalibrationPoint] = [],
        calibration: CalibrationRecord? = nil,
        reference: String = "",
        isConfirmed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.deviceUID = deviceUID
        self.kind = kind
        self.sensitivity = sensitivity
        self.outputSource = outputSource
        self.acousticCalibrationPoints = acousticCalibrationPoints
        self.calibration = calibration
        self.reference = reference
        self.isConfirmed = isConfirmed
    }
}

enum EstimateConfidence: String, Codable, Sendable {
    case calibrated = "已校准"
    case relativeCalibrated = "实测相对曲线"
    case specified = "规格估算"
    case estimatedCurve = "估算曲线"
}

struct LevelEstimate: Sendable, Equatable {
    let estimatedLevelDBA: Float
    let confidence: EstimateConfidence
    let profileName: String
    let reference: String
    let frequencyCalibrationApplied: Bool
    let volumeCalibrationApplied: Bool
    let absoluteLevelIsEstimated: Bool
}

struct OutputDeviceSnapshot: Sendable, Equatable {
    let id: UInt32?
    let uid: String?
    let name: String?
    let volumeScalar: Float?
    let isMuted: Bool?

    static let unavailable = OutputDeviceSnapshot(
        id: nil,
        uid: nil,
        name: nil,
        volumeScalar: nil,
        isMuted: nil
    )
}

enum LevelEstimator {
    static func estimate(
        volumeScalar: Float?,
        isMuted: Bool?,
        rmsAWeightedDBFS: Float,
        profile: TransducerProfile?,
        calibrationProfile: CalibrationProfile? = nil,
        frequencyCalibrationApplied: Bool = false
    ) -> LevelEstimate? {
        guard let volumeScalar,
              volumeScalar > 0,
              isMuted != true,
              let profile,
              profile.isConfirmed else {
            return nil
        }

        let clampedVolume = min(max(volumeScalar, 0), 1)
        let fullScaleDBA: Float
        let confidence: EstimateConfidence
        var volumeCalibrationApplied = false

        switch profile.kind {
        case .wiredHeadphones:
            guard let sensitivityDBV = profile.sensitivity?.dbPerVolt,
                  let source = profile.outputSource,
                  source.maxOutputVRMS > 0 else {
                return nil
            }

            if let calibrationProfile,
               calibrationProfile.headphoneProfileID == profile.id,
               calibrationProfile.outputDeviceUID == profile.deviceUID,
               calibrationProfile.absoluteCalibrationMode == .estimatedFromHeadphoneModel,
               calibrationProfile.volumeCalibrationUsable,
               let curve = VolumeCalibrationCurve(points: calibrationProfile.volumePoints),
               let referenceFullScale = headphoneModelFullScaleDBA(
                   at: calibrationProfile.referenceVolume,
                   sensitivityDBV: sensitivityDBV,
                   source: source
               ) {
                let currentDelta = curve.relativeDB(at: clampedVolume)
                let referenceDelta = curve.relativeDB(at: calibrationProfile.referenceVolume)
                fullScaleDBA = referenceFullScale + Float(currentDelta - referenceDelta)
                confidence = .relativeCalibrated
                volumeCalibrationApplied = true
            } else {
                guard let modelFullScale = headphoneModelFullScaleDBA(
                    at: clampedVolume,
                    sensitivityDBV: sensitivityDBV,
                    source: source
                ) else { return nil }
                fullScaleDBA = modelFullScale
                confidence = source.volumeCurve.count >= 2 ? .specified : .estimatedCurve
            }

        case .calibratedDevice:
            guard let calibrated = interpolateAcousticDBA(
                at: clampedVolume,
                points: profile.acousticCalibrationPoints
            ) else {
                return nil
            }
            fullScaleDBA = calibrated
            confidence = .calibrated
        }

        let offset = profile.calibration?.offsetDB ?? 0
        let estimate = fullScaleDBA + offset + rmsAWeightedDBFS
        guard estimate.isFinite else { return nil }

        return LevelEstimate(
            estimatedLevelDBA: estimate,
            confidence: profile.calibration == nil ? confidence : .calibrated,
            profileName: profile.name,
            reference: profile.reference,
            frequencyCalibrationApplied: frequencyCalibrationApplied,
            volumeCalibrationApplied: volumeCalibrationApplied,
            absoluteLevelIsEstimated: profile.kind == .wiredHeadphones
        )
    }

    static func headphoneModelFullScaleDBA(
        at volume: Float,
        sensitivityDBV: Float,
        source: OutputSourceProfile
    ) -> Float? {
        guard sensitivityDBV.isFinite, source.maxOutputVRMS.isFinite, source.maxOutputVRMS > 0 else {
            return nil
        }
        let attenuation = attenuationDB(at: min(max(volume, 0), 1), points: source.volumeCurve)
        let actualVRMS = source.maxOutputVRMS * pow(10, attenuation / 20)
        guard actualVRMS.isFinite, actualVRMS > 0 else { return nil }
        return sensitivityDBV + 20 * log10(actualVRMS)
    }

    static func defaultAttenuationDB(volumeScalar: Float) -> Float {
        guard volumeScalar > 0 else { return -.infinity }
        let volumePercent = min(max(volumeScalar, 0), 1) * 100
        return -65 * pow(1 - volumePercent / 100, 1.6)
    }

    private static func attenuationDB(at volume: Float, points: [VolumeCurvePoint]) -> Float {
        let sorted = points.sorted { $0.volumeScalar < $1.volumeScalar }
        guard sorted.count >= 2 else { return defaultAttenuationDB(volumeScalar: volume) }
        return interpolate(
            x: volume,
            points: sorted.map { ($0.volumeScalar, $0.attenuationDB) }
        )
    }

    private static func interpolateAcousticDBA(
        at volume: Float,
        points: [AcousticCalibrationPoint]
    ) -> Float? {
        let sorted = points.sorted { $0.volumeScalar < $1.volumeScalar }
        guard let first = sorted.first else { return nil }

        if sorted.count == 1 {
            let relativeAttenuation = defaultAttenuationDB(volumeScalar: volume)
                - defaultAttenuationDB(volumeScalar: first.volumeScalar)
            return first.fullScaleDBA + relativeAttenuation
        }

        return interpolate(
            x: volume,
            points: sorted.map { ($0.volumeScalar, $0.fullScaleDBA) }
        )
    }

    private static func interpolate(x: Float, points: [(Float, Float)]) -> Float {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }

        for (left, right) in zip(points, points.dropFirst()) where x <= right.0 {
            let width = right.0 - left.0
            guard width > 0 else { return right.1 }
            let fraction = (x - left.0) / width
            return left.1 + (right.1 - left.1) * fraction
        }
        return last.1
    }
}

enum ExposureMode: String, Codable, Sendable, CaseIterable {
    case adult
    case conservative

    var baselineDBA: Double { self == .adult ? 80 : 75 }
    var displayName: String { self == .adult ? "WHO 成人模式" : "WHO 保守模式" }
}

enum StatusBarDisplayMode: String, Codable, Sendable, CaseIterable {
    case estimatedDBA
    case sevenDayDose
    case rmsDBFS

    var displayName: String {
        switch self {
        case .estimatedDBA: "估算 dBA"
        case .sevenDayDose: "过去 7 天暴露 %"
        case .rmsDBFS: "RMS(A) dBFS"
        }
    }
}

struct ExposureBucket: Codable, Sendable, Equatable, Identifiable {
    var id: Date { minute }
    let minute: Date
    var normalizedEnergyAt80Seconds: Double
    var measuredDuration: Double
    var peakDBA: Double
    var deviceUID: String
}

enum ExposureMath {
    static let referenceDuration: Double = 40 * 60 * 60

    static func normalizedEnergyAt80(levelDBA: Double, duration: Double) -> Double {
        guard duration > 0, levelDBA.isFinite else { return 0 }
        return duration * pow(10, (levelDBA - 80) / 10)
    }

    static func doseFraction(normalizedEnergyAt80: Double, mode: ExposureMode) -> Double {
        let denominator = referenceDuration * pow(10, (mode.baselineDBA - 80) / 10)
        guard denominator > 0 else { return 0 }
        return max(0, normalizedEnergyAt80 / denominator)
    }

    static func equivalentLevelDBA(normalizedEnergyAt80: Double, duration: Double) -> Double? {
        guard normalizedEnergyAt80 > 0, duration > 0 else { return nil }
        return 80 + 10 * log10(normalizedEnergyAt80 / duration)
    }

    static func remainingTime(levelDBA: Double, currentDose: Double, mode: ExposureMode) -> Double? {
        guard levelDBA.isFinite, currentDose < 1 else { return currentDose >= 1 ? 0 : nil }
        let remainingEnergy = (1 - currentDose)
            * referenceDuration
            * pow(10, (mode.baselineDBA - 80) / 10)
        let energyPerSecond = pow(10, (levelDBA - 80) / 10)
        guard energyPerSecond > 0 else { return nil }
        return remainingEnergy / energyPerSecond
    }
}
