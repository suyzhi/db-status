import Foundation
import Testing
@testable import VolumeMonitor

@Suite struct LevelEstimatorTests {
    @Test func twoVoltOutputAddsSixDecibelsPlusSineCrest() throws {
        let profile = wiredProfile(
            sensitivity: .dbPerVolt(100),
            maxVRMS: 2,
            curve: [
                VolumeCurvePoint(volumeScalar: 0, attenuationDB: -65),
                VolumeCurvePoint(volumeScalar: 1, attenuationDB: 0)
            ]
        )
        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 1,
            isMuted: false,
            rmsAWeightedDBFS: 0,
            profile: profile
        ))
        #expect(abs(estimate.estimatedLevelDBA - 109.0309) <= 0.001)
    }

    @Test func milliwattSensitivityUsesImpedance() throws {
        let profile = wiredProfile(
            sensitivity: .dbPerMilliwatt(value: 100, impedanceOhms: 32),
            maxVRMS: 1,
            curve: [
                VolumeCurvePoint(volumeScalar: 0, attenuationDB: -65),
                VolumeCurvePoint(volumeScalar: 1, attenuationDB: 0)
            ]
        )
        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 1,
            isMuted: false,
            rmsAWeightedDBFS: 0,
            profile: profile
        ))
        #expect(abs(estimate.estimatedLevelDBA - 117.9588) <= 0.001)
    }

    @Test func calibrationOffsetIsApplied() throws {
        var profile = wiredProfile(sensitivity: .dbPerVolt(100), maxVRMS: 1)
        profile.calibration = CalibrationRecord(offsetDB: -4.5, date: .now, reference: "test")
        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 1,
            isMuted: false,
            rmsAWeightedDBFS: -10,
            profile: profile
        ))
        #expect(abs(estimate.estimatedLevelDBA - 88.5103) <= 0.001)
        #expect(estimate.confidence == .calibrated)
    }

    @Test func unknownMutedAndUnreadableDevicesDoNotEstimate() {
        let profile = wiredProfile(sensitivity: .dbPerVolt(100), maxVRMS: 1)
        #expect(LevelEstimator.estimate(
            volumeScalar: 1,
            isMuted: false,
            rmsAWeightedDBFS: -10,
            profile: nil
        ) == nil)
        #expect(LevelEstimator.estimate(
            volumeScalar: nil,
            isMuted: false,
            rmsAWeightedDBFS: -10,
            profile: profile
        ) == nil)
        #expect(LevelEstimator.estimate(
            volumeScalar: 1,
            isMuted: true,
            rmsAWeightedDBFS: -10,
            profile: profile
        ) == nil)
    }

    @Test func acousticCalibrationInterpolates() throws {
        let profile = TransducerProfile(
            name: "calibrated",
            deviceUID: "test",
            kind: .calibratedDevice,
            acousticCalibrationPoints: [
                AcousticCalibrationPoint(volumeScalar: 0.25, fullScaleDBA: 70),
                AcousticCalibrationPoint(volumeScalar: 0.75, fullScaleDBA: 90)
            ],
            reference: "meter",
            isConfirmed: true
        )
        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 0.5,
            isMuted: false,
            rmsAWeightedDBFS: -10,
            profile: profile
        ))
        #expect(abs(estimate.estimatedLevelDBA - 70) <= 0.001)
    }

    private func wiredProfile(
        sensitivity: SensitivitySpec,
        maxVRMS: Float,
        curve: [VolumeCurvePoint] = []
    ) -> TransducerProfile {
        TransducerProfile(
            name: "test",
            deviceUID: "test",
            kind: .wiredHeadphones,
            sensitivity: sensitivity,
            outputSource: OutputSourceProfile(maxOutputVRMS: maxVRMS, volumeCurve: curve),
            reference: "test",
            isConfirmed: true
        )
    }
}
