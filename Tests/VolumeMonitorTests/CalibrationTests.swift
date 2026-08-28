import Foundation
import Testing
@testable import VolumeMonitor

@Suite struct CalibrationTests {
    @Test func frequencyInterpolationUsesLogFrequency() throws {
        let interpolator = try #require(FrequencyResponseInterpolator(points: [
            FrequencyCalibrationPoint(frequencyHz: 100, relativeDB: -6, stabilityDB: 0.1),
            FrequencyCalibrationPoint(frequencyHz: 400, relativeDB: 6, stabilityDB: 0.1)
        ]))

        #expect(abs(interpolator.responseDB(at: 200)) <= 0.000_001)
        #expect(abs(interpolator.responseDB(at: 50) - (-6)) <= 0.000_001)
        #expect(abs(interpolator.responseDB(at: 800) - 6) <= 0.000_001)
    }

    @Test func volumeInterpolationIsContinuousMonotonicAndBounded() throws {
        let curve = try #require(VolumeCalibrationCurve(points: [
            VolumeCalibrationPoint(systemVolume: 0.3, relativeDB: -12, stabilityDB: 0.1),
            VolumeCalibrationPoint(systemVolume: 0.5, relativeDB: 0, stabilityDB: 0.1),
            VolumeCalibrationPoint(systemVolume: 0.7, relativeDB: 8, stabilityDB: 0.1)
        ]))

        #expect(abs(curve.relativeDB(at: 0.4) - (-6)) <= 0.000_01)
        #expect(abs(curve.relativeDB(at: 0.6) - 4) <= 0.000_01)
        let samples = stride(from: Float(0), through: 1, by: 0.01).map(curve.relativeDB(at:))
        #expect(zip(samples, samples.dropFirst()).allSatisfy(<=))
        #expect((samples.min() ?? -.infinity) >= -80)
        #expect((samples.max() ?? .infinity) <= 24)
    }

    @MainActor
    @Test func calibrationSaveLoadRoundTripAndMultipleHeadphones() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calibration-profiles.json")
        let first = makeValidProfile(headphoneProfileID: UUID(), outputUID: "output-A")
        let second = makeValidProfile(headphoneProfileID: UUID(), outputUID: "output-A")

        let store = CalibrationStore(fileURL: url)
        try store.save(first)
        try store.save(second)

        let reloaded = CalibrationStore(fileURL: url)
        #expect(reloaded.profiles.count == 2)
        #expect(
            reloaded.profile(
                headphoneProfileID: first.headphoneProfileID,
                outputDeviceUID: first.outputDeviceUID
            ) == first
        )
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    @Test func corruptFileAndInvalidProfileFallBackWithoutCrash() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("calibration-profiles.json")
        try Data("not-json".utf8).write(to: url)
        let corruptStore = CalibrationStore(fileURL: url)
        #expect(corruptStore.profiles.isEmpty)
        #expect(corruptStore.lastLoadWarning != nil)

        var invalid = makeValidProfile(headphoneProfileID: UUID(), outputUID: "output-A")
        invalid.frequencyPoints[0] = FrequencyCalibrationPoint(
            frequencyHz: 63,
            relativeDB: .nan,
            stabilityDB: 0.1
        )
        #expect(throws: (any Error).self) { try corruptStore.save(invalid) }

        var wrongVersion = makeValidProfile(headphoneProfileID: UUID(), outputUID: "output-B")
        wrongVersion.version = 999
        #expect(wrongVersion.commonValidationIssue == "不支持的校准版本 999")
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func measuredVolumeCurveKeepsAbsoluteReferenceFromHeadphoneModel() throws {
        let headphoneID = UUID()
        let transducer = TransducerProfile(
            id: headphoneID,
            name: "Test Headphone",
            deviceUID: "output-A",
            kind: .wiredHeadphones,
            sensitivity: .dbPerVolt(100),
            outputSource: OutputSourceProfile(
                maxOutputVRMS: 1,
                volumeCurve: [
                    VolumeCurvePoint(volumeScalar: 0.3, attenuationDB: -20),
                    VolumeCurvePoint(volumeScalar: 0.5, attenuationDB: -10),
                    VolumeCurvePoint(volumeScalar: 0.7, attenuationDB: -3)
                ]
            ),
            reference: "manufacturer",
            isConfirmed: true
        )
        let calibration = makeValidProfile(
            headphoneProfileID: headphoneID,
            outputUID: "output-A"
        )

        let estimate = try #require(LevelEstimator.estimate(
            volumeScalar: 0.7,
            isMuted: false,
            rmsAWeightedDBFS: -35,
            profile: transducer,
            calibrationProfile: calibration,
            frequencyCalibrationApplied: true
        ))

        // 50% model reference is 90 dB full-scale. Measured 70% delta is +8 dB.
        #expect(abs(estimate.estimatedLevelDBA - 63) <= 0.001)
        #expect(estimate.volumeCalibrationApplied)
        #expect(estimate.frequencyCalibrationApplied)
        #expect(estimate.absoluteLevelIsEstimated)
    }

    @Test func toneSafetyLevelUsesHeadphoneModelAndNeverRaisesRequestedLevel() throws {
        #expect(try CalibrationToneGenerator.safeRMSDBFS(
            requested: -35,
            estimatedFullScaleDBA: 100
        ) == -35)
        #expect(try CalibrationToneGenerator.safeRMSDBFS(
            requested: -35,
            estimatedFullScaleDBA: 125
        ) == -41)
        #expect(try CalibrationToneGenerator.safeRMSDBFS(
            requested: -35,
            estimatedFullScaleDBA: nil
        ) == -45)
    }

    @Test func changedTestSignalLevelIsRemovedFromRelativeAcousticResult() {
        let relative = CalibrationMeasurementMath.relativeDB(
            microphoneLevelDBFS: -32,
            signalRMSDBFS: -39,
            referenceMicrophoneLevelDBFS: -30,
            referenceSignalRMSDBFS: -35
        )
        // Test point has 7 dB acoustic transfer vs 5 dB at the reference,
        // even though its safety controller used a 4 dB quieter signal.
        #expect(relative == 2)
    }

    private func makeValidProfile(
        headphoneProfileID: UUID,
        outputUID: String
    ) -> CalibrationProfile {
        let relative: [Double] = [-3, -2, -1, -0.5, 0, 1, 2, 1, -2]
        return CalibrationProfile(
            id: UUID(),
            headphoneProfileID: headphoneProfileID,
            headphoneName: "Test Headphone",
            outputDeviceUID: outputUID,
            outputDeviceName: "Test Output",
            inputDeviceUID: "input-A",
            inputDeviceName: "EM258",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            frequencyPoints: zip(CalibrationProfile.requiredFrequenciesHz, relative).map {
                FrequencyCalibrationPoint(
                    frequencyHz: $0.0,
                    relativeDB: $0.1,
                    stabilityDB: 0.2,
                    measuredLevelDBFS: -30 + $0.1
                )
            },
            volumePoints: [
                VolumeCalibrationPoint(systemVolume: 0.3, relativeDB: -12, stabilityDB: 0.2),
                VolumeCalibrationPoint(systemVolume: 0.5, relativeDB: 0, stabilityDB: 0.2),
                VolumeCalibrationPoint(systemVolume: 0.7, relativeDB: 8, stabilityDB: 0.2)
            ],
            frequencyCalibrationValid: true,
            volumeCalibrationValid: true,
            quality: CalibrationQuality(
                averageStabilityDB: 0.2,
                maximumStabilityDB: 0.3,
                minimumSNRDB: 22,
                relativeValidationErrorDB: 0.6
            )
        )
    }
}
