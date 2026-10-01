import Foundation
import Testing
@testable import VolumeMonitor

/// 2026-10 准确度修正：全量程音量曲线、满幅正弦约定、手机对标绝对值、保守回退。
@Suite struct AbsoluteCalibrationTests {
    /// 2026-10-01 MacBook Air 耳机孔 + DT 1990 Pro MK II 的实测音量曲线（相对 50%）。
    static let measuredCurve: [(Float, Double)] = [
        (0.25, -13.22), (0.3125, -9.31), (0.375, -6.02), (0.5, 0),
        (0.625, 5.39), (0.75, 10.21), (0.875, 14.68), (1.0, 18.78)
    ]

    @Test func fullRangeCurveAnchorsAtFullVolumeInsteadOfEstimatedCurve() throws {
        let headphone = wiredHeadphone(sensitivityDBV: 110)
        let calibration = calibrationProfile(headphone: headphone)

        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 0.5,
            isMuted: false,
            rmsAWeightedDBFS: -33.0103,
            profile: headphone,
            calibrationProfile: calibration,
            frequencyCalibrationApplied: true
        ))
        // 1 kHz −30 dBFS(峰值) 正弦，50% 音量：110 − 18.78 − 30 = 61.22 dB SPL。
        #expect(abs(estimate.estimatedLevelDBA - 61.22) < 0.01)
        #expect(estimate.confidence == .relativeCalibrated)
        #expect(estimate.absoluteLevelIsEstimated)
    }

    @Test func acousticReferenceOverridesSpecificationAnchor() throws {
        let headphone = wiredHeadphone(sensitivityDBV: 110)
        var calibration = calibrationProfile(headphone: headphone)
        calibration.absoluteCalibrationMode = .acousticReference
        calibration.acousticReference = acousticReference(fullScale: 93.88)

        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 0.3125,
            isMuted: false,
            rmsAWeightedDBFS: -20,
            profile: headphone,
            calibrationProfile: calibration,
            frequencyCalibrationApplied: true
        ))
        #expect(abs(estimate.estimatedLevelDBA - (93.88 - 9.31 - 20)) < 0.01)
        #expect(estimate.confidence == .measuredAbsolute)
        #expect(!estimate.absoluteLevelIsEstimated)
    }

    @Test func invalidAcousticReferenceFallsBackToSpecification() throws {
        let headphone = wiredHeadphone(sensitivityDBV: 110)
        var calibration = calibrationProfile(headphone: headphone)
        calibration.absoluteCalibrationMode = .acousticReference
        calibration.acousticReference = acousticReference(fullScale: 200)
        #expect(calibration.absoluteValidationIssue != nil)

        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 0.5,
            isMuted: false,
            rmsAWeightedDBFS: -33.0103,
            profile: headphone,
            calibrationProfile: calibration,
            frequencyCalibrationApplied: true
        ))
        #expect(abs(estimate.estimatedLevelDBA - 61.22) < 0.01)
        #expect(estimate.confidence == .relativeCalibrated)
    }

    @Test func sensitivityMeasuredAt500HzIsShiftedToOneKilohertz() throws {
        var headphone = wiredHeadphone(sensitivityDBV: 110)
        headphone.sensitivityReferenceHz = 500
        let calibration = calibrationProfile(headphone: headphone, responseAt500: -1.11)

        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 1,
            isMuted: false,
            rmsAWeightedDBFS: -3.0103,
            profile: headphone,
            calibrationProfile: calibration,
            frequencyCalibrationApplied: true
        ))
        // 500 Hz 比 1 kHz 低 1.11 dB，所以 1 kHz 满幅正弦是 111.11 dB。
        #expect(abs(estimate.estimatedLevelDBA - 111.11) < 0.01)
    }

    @Test func fallbackKeepsMeasuredCurveAndAddsConservativeCompensation() throws {
        let headphone = wiredHeadphone(sensitivityDBV: 110)
        let calibration = calibrationProfile(headphone: headphone)
        let applied = try #require(LevelEstimator.estimate(
            volumeScalar: 0.3125, isMuted: false, rmsAWeightedDBFS: -20,
            profile: headphone, calibrationProfile: calibration,
            frequencyCalibrationApplied: true, frequencyFallbackCompensationDB: 2.5
        ))
        let fallback = try #require(LevelEstimator.estimate(
            volumeScalar: 0.3125, isMuted: false, rmsAWeightedDBFS: -20,
            profile: headphone, calibrationProfile: calibration,
            frequencyCalibrationApplied: false, frequencyFallbackCompensationDB: 2.5
        ))
        #expect(fallback.volumeCalibrationApplied)
        #expect(abs(fallback.estimatedLevelDBA - applied.estimatedLevelDBA - 2.5) < 0.001)
        #expect(applied.frequencyFallbackCompensationDB == 0)
        #expect(fallback.frequencyFallbackCompensationDB == 2.5)
    }

    @Test func fallbackCompensationReflectsBoostedResponseOnly() {
        let headphone = wiredHeadphone(sensitivityDBV: 110)
        let flat = calibrationProfile(headphone: headphone, response: Array(repeating: 0, count: 9))
        #expect(abs(flat.frequencyFallbackCompensationDB) < 0.001)

        let boosted = calibrationProfile(
            headphone: headphone,
            response: [-1.36, 0.07, 0.10, -1.11, 0, 2.78, 5.92, 3.87, 1.75]
        )
        #expect(boosted.frequencyFallbackCompensationDB > 1)
        #expect(boosted.frequencyFallbackCompensationDB < 5)

        let cut = calibrationProfile(
            headphone: headphone,
            response: [0, 0, 0, 0, 0, -6, -6, -6, -6]
        )
        #expect(cut.frequencyFallbackCompensationDB == 0)
    }

    @Test func defaultCurveMatchesMeasuredJackWithinTolerance() {
        for (volume, relativeTo50) in Self.measuredCurve where volume < 1 {
            let measured = relativeTo50 - 18.78
            let model = Double(LevelEstimator.defaultAttenuationDB(volumeScalar: volume))
            #expect(abs(model - measured) < 1.5, "volume \(volume)")
        }
        #expect(LevelEstimator.defaultAttenuationDB(volumeScalar: 1) == 0)
    }

    @Test func volumeValidationAcceptsFullRangeAndLegacyButRejectsGaps() {
        let headphone = wiredHeadphone(sensitivityDBV: 110)
        let full = calibrationProfile(headphone: headphone)
        #expect(full.volumeValidationIssue == nil)
        #expect(full.volumeCurveCoversFullScale)

        var missing = full
        missing.volumePoints.removeAll { $0.systemVolume == 0.875 }
        #expect(missing.volumeValidationIssue == "缺少 88% 音量点")

        var legacy = full
        legacy.version = 1
        legacy.volumePoints = [
            VolumeCalibrationPoint(systemVolume: 0.3, relativeDB: -10.18, stabilityDB: 0.01),
            VolumeCalibrationPoint(systemVolume: 0.5, relativeDB: 0, stabilityDB: 0.01),
            VolumeCalibrationPoint(systemVolume: 0.7, relativeDB: 8.21, stabilityDB: 0.01)
        ]
        #expect(legacy.volumeValidationIssue == nil)
        #expect(legacy.commonValidationIssue == nil)
        #expect(!legacy.volumeCurveCoversFullScale)
    }

    @Test @MainActor func storeSavesAcousticReferenceProfiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeMonitorTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let headphone = wiredHeadphone(sensitivityDBV: 110)
        var calibration = calibrationProfile(headphone: headphone)
        calibration.absoluteCalibrationMode = .acousticReference
        calibration.acousticReference = acousticReference(fullScale: 93.88)

        let store = CalibrationStore(fileURL: url)
        try store.save(calibration)
        let reloaded = CalibrationStore(fileURL: url)
        let loaded = try #require(reloaded.profile(
            headphoneProfileID: headphone.id,
            outputDeviceUID: headphone.deviceUID
        ))
        #expect(loaded.acousticReference == calibration.acousticReference)
        #expect(abs((loaded.acousticReference?.microphoneOffsetDB ?? 0) - 97.18) < 0.001)

        var broken = calibration
        broken.id = UUID()
        broken.acousticReference = nil
        #expect(throws: CalibrationStoreError.self) { try store.save(broken) }
    }

    @Test func pinkNoiseHasRequestedLevelAndSeamlessLength() {
        let samples = CalibrationNoisePlayer.makePinkNoise(frameCount: 48_000 * 2, rmsDBFS: -20)
        #expect(samples.count == 48_000 * 2 - 2_048)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        #expect(abs(20 * log10(rms) + 20) < 0.3)
        #expect((samples.map { abs($0) }.max() ?? 1) < 1)
    }

    @Test func aWeightedRMSOfOneKilohertzSineIsUnchanged() {
        let sampleRate = 48_000.0
        let samples = (0..<Int(sampleRate * 2)).map {
            Float(0.1 * sin(2 * Double.pi * 1_000 * Double($0) / sampleRate))
        }
        let meter = AWeightingMeter(sampleRate: sampleRate, channelCount: 1)
        let rms = meter.rms(of: samples)
        #expect(abs(20 * log10(rms) - 20 * log10(0.1 / sqrt(2))) < 0.05)
    }

    // MARK: - Helpers

    private func wiredHeadphone(sensitivityDBV: Float) -> TransducerProfile {
        TransducerProfile(
            id: UUID(),
            name: "DT 1990 Pro MK II",
            deviceUID: "BuiltInHeadphoneOutputDevice",
            kind: .wiredHeadphones,
            sensitivity: .dbPerVolt(sensitivityDBV),
            outputSource: OutputSourceProfile(maxOutputVRMS: 1, volumeCurve: []),
            reference: "spec",
            isConfirmed: true
        )
    }

    private func calibrationProfile(
        headphone: TransducerProfile,
        responseAt500: Double = 0,
        response: [Double]? = nil
    ) -> CalibrationProfile {
        let relative = response ?? [0, 0, 0, responseAt500, 0, 0, 0, 0, 0]
        return CalibrationProfile(
            headphoneProfileID: headphone.id,
            headphoneName: headphone.name,
            outputDeviceUID: headphone.deviceUID,
            outputDeviceName: "外置耳机",
            frequencyPoints: zip(CalibrationProfile.requiredFrequenciesHz, relative).map {
                FrequencyCalibrationPoint(frequencyHz: $0.0, relativeDB: $0.1, stabilityDB: 0.01)
            },
            volumePoints: Self.measuredCurve.map {
                VolumeCalibrationPoint(systemVolume: $0.0, relativeDB: $0.1, stabilityDB: 0.01)
            },
            frequencyCalibrationValid: true,
            volumeCalibrationValid: true,
            quality: CalibrationQuality(
                averageStabilityDB: 0.01,
                maximumStabilityDB: 0.02,
                minimumSNRDB: 25,
                relativeValidationErrorDB: 0.15
            )
        )
    }

    private func acousticReference(fullScale: Double) -> AcousticReferenceCalibration {
        AcousticReferenceCalibration(
            referenceMeterDBA: 69,
            microphoneAWeightedDBFS: -28.18,
            microphoneStabilityDB: 0.1,
            referenceDescription: "iPhone 15 Pro Max · NIOSH SLM",
            measuredAt: Date(timeIntervalSince1970: 1_790_000_000),
            fullScaleRMSSPLAtReferenceVolume: fullScale
        )
    }
}
