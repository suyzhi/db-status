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
    /// 灵敏度规格对应的测量频率（Hz）。厂商常用 500 Hz 或 1 kHz；未填写按 1 kHz。
    var sensitivityReferenceHz: Double?
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
        sensitivityReferenceHz: Double? = nil,
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
        self.sensitivityReferenceHz = sensitivityReferenceHz
        self.outputSource = outputSource
        self.acousticCalibrationPoints = acousticCalibrationPoints
        self.calibration = calibration
        self.reference = reference
        self.isConfirmed = isConfirmed
    }
}

enum EstimateConfidence: String, Codable, Sendable {
    case measuredAbsolute = "实测绝对校准"
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
    /// 频响校准存在但运行时未生效时，为避免低估而加上的保守补偿（dB）。
    let frequencyFallbackCompensationDB: Float
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
    /// 满幅正弦的 RMS 是 −3.01 dBFS。耳机孔"最大输出 Vrms"按满幅正弦标称，
    /// 所以数字 RMS 0 dBFS 对应的电压比标称值高 3.01 dB。
    static let fullScaleSineCrestDB: Float = 3.0103

    static func estimate(
        volumeScalar: Float?,
        isMuted: Bool?,
        rmsAWeightedDBFS: Float,
        profile: TransducerProfile?,
        calibrationProfile: CalibrationProfile? = nil,
        frequencyCalibrationApplied: Bool = false,
        frequencyFallbackCompensationDB: Float = 0
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
        var confidence: EstimateConfidence
        var volumeCalibrationApplied = false
        var absoluteLevelIsEstimated = false
        var fallbackCompensation: Float = 0

        switch profile.kind {
        case .wiredHeadphones:
            guard let sensitivityDBV = profile.sensitivity?.dbPerVolt,
                  let source = profile.outputSource,
                  source.maxOutputVRMS > 0 else {
                return nil
            }
            absoluteLevelIsEstimated = true

            if let calibrationProfile,
               calibrationProfile.headphoneProfileID == profile.id,
               calibrationProfile.outputDeviceUID == profile.deviceUID,
               calibrationProfile.volumeCalibrationUsable,
               let curve = VolumeCalibrationCurve(points: calibrationProfile.volumePoints),
               let anchor = absoluteAnchor(
                   calibrationProfile: calibrationProfile,
                   sensitivityDBV: sensitivityDBV,
                   sensitivityReferenceHz: profile.sensitivityReferenceHz,
                   source: source
               ) {
                let modelShape: (Float) -> Double = { volume in
                    Double(attenuationDB(at: volume, points: source.volumeCurve))
                }
                let currentDelta = curve.relativeDB(
                    at: clampedVolume,
                    alignedToOriginalModel: modelShape
                )
                let anchorDelta = curve.relativeDB(
                    at: anchor.volume,
                    alignedToOriginalModel: modelShape
                )
                fullScaleDBA = anchor.fullScaleDBA + Float(currentDelta - anchorDelta)
                volumeCalibrationApplied = true
                absoluteLevelIsEstimated = !anchor.isMeasured
                confidence = anchor.isMeasured ? .measuredAbsolute : .relativeCalibrated
                // 频响校准存在但运行时 FFT 引擎没跑起来：A 加权路径默认耳机平直，
                // 补上实测频响对典型频谱多出的能量，宁可高估。
                if !frequencyCalibrationApplied, calibrationProfile.frequencyCalibrationUsable {
                    fallbackCompensation = max(0, frequencyFallbackCompensationDB)
                }
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
        let estimate = fullScaleDBA + offset + fallbackCompensation + rmsAWeightedDBFS
        guard estimate.isFinite else { return nil }
        if profile.calibration != nil, confidence != .measuredAbsolute {
            confidence = .calibrated
        }

        return LevelEstimate(
            estimatedLevelDBA: estimate,
            confidence: confidence,
            profileName: profile.name,
            reference: profile.reference,
            frequencyCalibrationApplied: frequencyCalibrationApplied,
            volumeCalibrationApplied: volumeCalibrationApplied,
            absoluteLevelIsEstimated: absoluteLevelIsEstimated,
            frequencyFallbackCompensationDB: fallbackCompensation
        )
    }

    /// 绝对声压的锚点：某个系统音量下，数字 RMS 0 dBFS 的 1 kHz 信号对应的 dB SPL。
    /// 优先级：实测（手机/声级计对标）> 规格换算到 100% 音量 > 规格 + 估算曲线（旧 3 点校准）。
    private static func absoluteAnchor(
        calibrationProfile: CalibrationProfile,
        sensitivityDBV: Float,
        sensitivityReferenceHz: Double?,
        source: OutputSourceProfile
    ) -> (volume: Float, fullScaleDBA: Float, isMeasured: Bool)? {
        if calibrationProfile.absoluteCalibrationMode == .acousticReference,
           calibrationProfile.absoluteValidationIssue == nil,
           let reference = calibrationProfile.acousticReference {
            return (
                calibrationProfile.referenceVolume,
                Float(reference.fullScaleRMSSPLAtReferenceVolume),
                true
            )
        }
        // 规格灵敏度在 sensitivityReferenceHz 测得；实测频响以 1 kHz 为 0 dB，
        // 换算到 1 kHz 才能和频响加权链对齐。
        let frequencyShift = Float(calibrationProfile.frequencyResponseDB(
            at: sensitivityReferenceHz ?? 1_000
        ) ?? 0)
        if calibrationProfile.volumeCurveCoversFullScale,
           let fullScale = headphoneModelFullScaleDBA(
               at: 1,
               sensitivityDBV: sensitivityDBV,
               source: OutputSourceProfile(maxOutputVRMS: source.maxOutputVRMS, volumeCurve: [])
           ) {
            return (1, fullScale - frequencyShift, false)
        }
        guard let referenceFullScale = headphoneModelFullScaleDBA(
            at: calibrationProfile.referenceVolume,
            sensitivityDBV: sensitivityDBV,
            source: source
        ) else { return nil }
        return (calibrationProfile.referenceVolume, referenceFullScale - frequencyShift, false)
    }

    /// 数字 RMS 0 dBFS 的信号在该音量下的估算声压（规格模型）。
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
        return sensitivityDBV + 20 * log10(actualVRMS) + fullScaleSineCrestDB
    }

    /// 没有实测音量曲线时的默认衰减。按 MacBook 耳机孔 EM258 实测（2026-10）拟合，
    /// 25%~87.5% 误差 ±1.4 dB；比旧的 −65·(1−v)^1.6 平缓，低音量时不再低估。
    /// 注意：CoreAudio 报告的 scalar→dB（−63.5 dB 线性）与实测不符，不能用来替代。
    static func defaultAttenuationDB(volumeScalar: Float) -> Float {
        guard volumeScalar > 0 else { return -.infinity }
        let volume = min(max(volumeScalar, 0), 1)
        return -42.5 * pow(1 - volume, 1.14)
    }

    private static func attenuationDB(at volume: Float, points: [VolumeCurvePoint]) -> Float {
        let sorted = points.isOrdered(by: { $0.volumeScalar < $1.volumeScalar })
            ? points
            : points.sorted { $0.volumeScalar < $1.volumeScalar }
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
        let sorted = points.isOrdered(by: { $0.volumeScalar < $1.volumeScalar })
            ? points
            : points.sorted { $0.volumeScalar < $1.volumeScalar }
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
    /// 按 App 分摊的能量（与 normalizedEnergyAt80Seconds 同单位）。缺失部分为未识别。
    var appEnergy: [String: Double]? = nil

    /// 合并同一分钟的另一条记录：能量/时长相加、峰值取大、App 能量逐项相加。
    mutating func absorb(_ other: ExposureBucket) {
        normalizedEnergyAt80Seconds += other.normalizedEnergyAt80Seconds
        measuredDuration += other.measuredDuration
        peakDBA = max(peakDBA, other.peakDBA)
        deviceUID = other.deviceUID
        if let otherApps = other.appEnergy {
            var merged = appEnergy ?? [:]
            for (key, value) in otherApps { merged[key, default: 0] += value }
            appEnergy = merged
        }
    }
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

private extension Array {
    /// 已排序时省掉一次 sort：估算在 10 Hz 刷新路径上，曲线通常早已有序。
    func isOrdered(by areInIncreasingOrder: (Element, Element) -> Bool) -> Bool {
        guard count > 1 else { return true }
        for index in 1..<count where areInIncreasingOrder(self[index], self[index - 1]) {
            return false
        }
        return true
    }
}
