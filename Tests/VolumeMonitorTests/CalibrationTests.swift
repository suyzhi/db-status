import CoreAudio
import Foundation
import Testing
@testable import VolumeMonitor

@Suite struct CalibrationTests {
    @Test func microphoneInputFormatValidatorRejectsInvalidFormats() {
        #expect(CalibrationInputFormatValidator.isValid(
            sampleRate: 48_000,
            channelCount: 1,
            isStandardPCM: true
        ))
        #expect(CalibrationInputFormatValidator.isValid(
            sampleRate: 44_100,
            channelCount: 2,
            isStandardPCM: true
        ))
        #expect(!CalibrationInputFormatValidator.isValid(
            sampleRate: 0,
            channelCount: 1,
            isStandardPCM: true
        ))
        #expect(!CalibrationInputFormatValidator.isValid(
            sampleRate: .nan,
            channelCount: 1,
            isStandardPCM: true
        ))
        #expect(!CalibrationInputFormatValidator.isValid(
            sampleRate: -48_000,
            channelCount: 1,
            isStandardPCM: true
        ))
        #expect(!CalibrationInputFormatValidator.isValid(
            sampleRate: 48_000,
            channelCount: 0,
            isStandardPCM: true
        ))
        #expect(!CalibrationInputFormatValidator.isValid(
            sampleRate: 48_000,
            channelCount: 33,
            isStandardPCM: true
        ))
        #expect(!CalibrationInputFormatValidator.isValid(
            sampleRate: 48_000,
            channelCount: 1,
            isStandardPCM: false
        ))
    }

    @Test func microphoneCaptureStartsOnlyFromExplicitButton() {
        #expect(!CalibrationMicrophoneStartTrigger.windowPreparation.startsCapture)
        #expect(!CalibrationMicrophoneStartTrigger.deviceSelection.startsCapture)
        #expect(CalibrationMicrophoneStartTrigger.manualDetectionButton.startsCapture)
    }

    @Test func virtualAudioTapIsNotTreatedAsExternalMicrophone() {
        let virtual = CalibrationInputDevice(
            id: 124,
            uid: "com.volumemonitor.audio-tap.test",
            name: "VolumeMonitor Audio Tap",
            transportType: kAudioDeviceTransportTypeVirtual
        )
        #expect(!virtual.isExternal)
    }

    @MainActor
    @Test func selectingMicrophoneKeepsCaptureIdle() {
        let monitor = CalibrationMicrophoneMonitor()
        let device = CalibrationInputDevice(
            id: 123,
            uid: "test-input",
            name: "Test Input",
            transportType: kAudioDeviceTransportTypeBuiltIn
        )
        monitor.select(device: device)
        #expect(monitor.snapshot.status == .idle)
        #expect(monitor.snapshot.device == device)
        #expect(monitor.inputChainFingerprint == nil)
    }

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

    @Test func lowFrequencyLongWindowsRecoverKnownRMS() throws {
        let sampleRate = 48_000.0
        let expectedDBFS = -30.0
        for frequency in [63.0, 125.0, 1_000.0] {
            let samples = sine(
                frequencyHz: frequency,
                rmsDBFS: expectedDBFS,
                sampleRate: sampleRate,
                duration: 3.1
            )
            let analysis = try #require(CalibrationFrequencyAnalyzer.analyze(
                samplesByChannel: [samples],
                sampleRate: sampleRate,
                frequencyHz: frequency
            ))
            #expect(abs(analysis.levelDBFS - expectedDBFS) <= 0.1)
            #expect(analysis.sampleCount == 144_000)
            #expect(analysis.windowLevelsDBFS.count == 3)
        }
    }

    @Test func longWindowStabilityRespondsToAmplitudeChange() throws {
        let sampleRate = 48_000.0
        let stable = sine(frequencyHz: 125, rmsDBFS: -30, sampleRate: sampleRate, duration: 3)
        let stableAnalysis = try #require(CalibrationFrequencyAnalyzer.analyze(
            samplesByChannel: [stable],
            sampleRate: sampleRate,
            frequencyHz: 125
        ))
        #expect(stableAnalysis.stabilityDB <= 0.01)

        let changed = sine(frequencyHz: 125, rmsDBFS: -30, sampleRate: sampleRate, duration: 2)
            + sine(frequencyHz: 125, rmsDBFS: -24, sampleRate: sampleRate, duration: 1)
        let changedAnalysis = try #require(CalibrationFrequencyAnalyzer.analyze(
            samplesByChannel: [changed],
            sampleRate: sampleRate,
            frequencyHz: 125
        ))
        #expect(changedAnalysis.stabilityDB >= 3)
    }

    @Test func volumeCurveUsesAlignedOriginalModelOutsideMeasuredRange() throws {
        let curve = try #require(VolumeCalibrationCurve(points: [
            VolumeCalibrationPoint(systemVolume: 0.3, relativeDB: -12, stabilityDB: 0.1),
            VolumeCalibrationPoint(systemVolume: 0.5, relativeDB: 0, stabilityDB: 0.1),
            VolumeCalibrationPoint(systemVolume: 0.7, relativeDB: 8, stabilityDB: 0.1)
        ]))
        let model: (Float) -> Double = { volume in
            Double(LevelEstimator.defaultAttenuationDB(volumeScalar: volume))
        }
        let value: (Float) -> Double = { volume in
            curve.relativeDB(at: volume, alignedToOriginalModel: model)
        }

        #expect(abs(value(0.299) - value(0.3)) < 0.2)
        #expect(abs(value(0.3) - value(0.301)) < 0.2)
        #expect(abs(value(0.699) - value(0.7)) < 0.2)
        #expect(abs(value(0.7) - value(0.701)) < 0.2)
        #expect(abs(value(0.2) - (-12 + model(0.2) - model(0.3))) < 0.000_001)
        #expect(abs(value(0.8) - (8 + model(0.8) - model(0.7))) < 0.000_001)
    }

    @Test func inputChainFingerprintDetectsRelevantChanges() {
        let baseline = CalibrationInputChainFingerprint(
            deviceUID: "input-A",
            sampleRate: 48_000,
            channelCount: 1,
            formatDescription: "lpcm:float32:noninterleaved",
            inputGainScalar: 0.5
        )
        #expect(baseline.matchesCurrentInputChain(baseline))
        #expect(!baseline.matchesCurrentInputChain(CalibrationInputChainFingerprint(
            deviceUID: "input-B",
            sampleRate: 48_000,
            channelCount: 1,
            formatDescription: baseline.formatDescription,
            inputGainScalar: 0.5
        )))
        #expect(!baseline.matchesCurrentInputChain(CalibrationInputChainFingerprint(
            deviceUID: baseline.deviceUID,
            sampleRate: 44_100,
            channelCount: 1,
            formatDescription: baseline.formatDescription,
            inputGainScalar: 0.5
        )))
        #expect(!baseline.matchesCurrentInputChain(CalibrationInputChainFingerprint(
            deviceUID: baseline.deviceUID,
            sampleRate: 48_000,
            channelCount: 2,
            formatDescription: baseline.formatDescription,
            inputGainScalar: 0.5
        )))
        #expect(!baseline.matchesCurrentInputChain(CalibrationInputChainFingerprint(
            deviceUID: baseline.deviceUID,
            sampleRate: 48_000,
            channelCount: 1,
            formatDescription: "different-format",
            inputGainScalar: 0.5
        )))
        #expect(!baseline.matchesCurrentInputChain(CalibrationInputChainFingerprint(
            deviceUID: baseline.deviceUID,
            sampleRate: 48_000,
            channelCount: 1,
            formatDescription: baseline.formatDescription,
            inputGainScalar: 0.55
        )))
    }

    @Test func calibrationQualityGradesAndSaveGate() {
        #expect(quality(snr: 25, stability: 0.3, validation: 1).grade == .excellent)
        #expect(quality(snr: 20, stability: 0.5, validation: 1.5).grade == .good)
        #expect(quality(snr: 15, stability: 0.7, validation: 2).grade == .acceptable)
        #expect(quality(snr: 14.9, stability: 0.8, validation: 2.1).grade == .poor)
        #expect(CalibrationValidationPolicy.canSave(relativeValidationErrorDB: 2.0))
        #expect(!CalibrationValidationPolicy.canSave(relativeValidationErrorDB: 2.01))
        #expect(!CalibrationValidationPolicy.canSave(relativeValidationErrorDB: nil))

        var rejectedProfile = makeValidProfile(
            headphoneProfileID: UUID(),
            outputUID: "output-rejected"
        )
        rejectedProfile.quality.relativeValidationErrorDB = 2.01
        #expect(rejectedProfile.volumeValidationIssue == "相对音量曲线验证误差超过 2 dB")
    }

    @MainActor
    @Test func frequencyValidationAcceptsSkippedTopPointsButRequiresMandatoryBand() {
        let base = makeValidProfile(headphoneProfileID: UUID(), outputUID: "output-skip")

        // 跳过 12 kHz（开放式大耳高频不足时允许）——仍应有效。
        var skippedTop = base
        skippedTop.frequencyPoints = base.frequencyPoints.filter { abs($0.frequencyHz - 12_000) >= 0.5 }
        #expect(skippedTop.frequencyValidationIssue == nil)

        // 同时跳过 8 kHz 与 12 kHz（7 个必备频点）——仍应有效。
        var skippedBoth = base
        skippedBoth.frequencyPoints = base.frequencyPoints.filter { $0.frequencyHz < 8_000 }
        #expect(skippedBoth.frequencyValidationIssue == nil)

        // 跳过 63 Hz（必备频段）——应判无效。
        var missingBass = base
        missingBass.frequencyPoints = base.frequencyPoints.filter { abs($0.frequencyHz - 63) >= 0.5 }
        #expect(missingBass.frequencyValidationIssue != nil)

        // 只留 6 个点——应判无效。
        var tooFew = base
        tooFew.frequencyPoints = Array(base.frequencyPoints.prefix(6))
        #expect(tooFew.frequencyValidationIssue != nil)
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
        // 90 dBA 上限：满刻度 131 dBA 时压到 -41 dBFS，使声压恰好 90 dBA。
        #expect(try CalibrationToneGenerator.safeRMSDBFS(
            requested: -35,
            estimatedFullScaleDBA: 131
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
            inputChainFingerprint: CalibrationInputChainFingerprint(
                deviceUID: "input-A",
                sampleRate: 48_000,
                channelCount: 1,
                formatDescription: "test-lpcm",
                inputGainScalar: nil
            ),
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

    private func sine(
        frequencyHz: Double,
        rmsDBFS: Double,
        sampleRate: Double,
        duration: Double
    ) -> [Float] {
        let count = Int((sampleRate * duration).rounded())
        let peak = pow(10, rmsDBFS / 20) * sqrt(2)
        return (0..<count).map { index in
            Float(peak * sin(2 * Double.pi * frequencyHz * Double(index) / sampleRate))
        }
    }

    private func quality(
        snr: Double,
        stability: Double,
        validation: Double
    ) -> CalibrationQuality {
        CalibrationQuality(
            averageStabilityDB: stability / 2,
            maximumStabilityDB: stability,
            minimumSNRDB: snr,
            relativeValidationErrorDB: validation
        )
    }
}
