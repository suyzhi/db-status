import CoreAudio
import Foundation
import Testing
@testable import VolumeMonitor

@Suite struct CalibratedAudioLevelMeterTests {
    @Test(arguments: [100.0, 1_000.0, 4_000.0, 10_000.0])
    func zeroResponseMatchesExistingAWeighting(frequencyHz: Double) throws {
        let frames = 96_000
        var samples = stereoSine(
            frequencyHz: frequencyHz,
            frames: frames,
            leftAmplitude: 0.25,
            rightAmplitude: 0.25
        )
        let result = samples.withUnsafeMutableBufferPointer { pointer -> (Float, Float)? in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(pointer, numberOfChannels: 2)
            )
            return withUnsafePointer(to: &list) { audio in
                let existing = AWeightingMeter(sampleRate: 48_000, channelCount: 2)
                    .measure(audio)?.rms
                let calibrated = CalibratedAudioLevelMeter(
                    sampleRate: 48_000,
                    channelCount: 2,
                    frequencyPoints: zeroResponsePoints()
                )?.measure(audio)?.rms
                guard let existing, let calibrated else { return nil }
                return (existing, calibrated)
            }
        }
        let levels = try #require(result)
        let difference = abs(20 * log10(levels.0) - 20 * log10(levels.1))
        #expect(difference < 0.5, "\(frequencyHz) Hz differs by \(difference) dB")
    }

    @Test func loudestChannelWinsInsteadOfStereoAverage() throws {
        var samples = stereoSine(
            frequencyHz: 1_000,
            frames: 48_000,
            leftAmplitude: 0.5,
            rightAmplitude: 0.1
        )
        let rms = samples.withUnsafeMutableBufferPointer { pointer -> Float? in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(pointer, numberOfChannels: 2)
            )
            return withUnsafePointer(to: &list) {
                CalibratedAudioLevelMeter(
                    sampleRate: 48_000,
                    channelCount: 2,
                    frequencyPoints: zeroResponsePoints()
                )?.measure($0)?.rms
            }
        }
        #expect(abs(try #require(rms) - 0.3535) < 0.02)
    }

    @Test func threeDBHeadphoneResponseAddsThreeDBInPowerDomain() throws {
        var samples = stereoSine(
            frequencyHz: 1_000,
            frames: 48_000,
            leftAmplitude: 0.2,
            rightAmplitude: 0.2
        )
        let levels = samples.withUnsafeMutableBufferPointer { pointer -> (Float, Float)? in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(pointer, numberOfChannels: 2)
            )
            return withUnsafePointer(to: &list) { audio in
                let zero = CalibratedAudioLevelMeter(
                    sampleRate: 48_000,
                    channelCount: 2,
                    frequencyPoints: zeroResponsePoints()
                )?.measure(audio)?.rms
                let boosted = CalibratedAudioLevelMeter(
                    sampleRate: 48_000,
                    channelCount: 2,
                    frequencyPoints: CalibrationProfile.requiredFrequenciesHz.map {
                        FrequencyCalibrationPoint(frequencyHz: $0, relativeDB: 3, stabilityDB: 0)
                    }
                )?.measure(audio)?.rms
                guard let zero, let boosted else { return nil }
                return (zero, boosted)
            }
        }
        let result = try #require(levels)
        #expect(abs(20 * log10(result.1 / result.0) - 3) < 0.05)
    }

    private func zeroResponsePoints() -> [FrequencyCalibrationPoint] {
        CalibrationProfile.requiredFrequenciesHz.map {
            FrequencyCalibrationPoint(frequencyHz: $0, relativeDB: 0, stabilityDB: 0)
        }
    }

    private func stereoSine(
        frequencyHz: Double,
        frames: Int,
        leftAmplitude: Float,
        rightAmplitude: Float
    ) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let phase = 2 * Double.pi * frequencyHz * Double(frame) / 48_000
            return [leftAmplitude * Float(sin(phase)), rightAmplitude * Float(sin(phase))]
        }
    }
}
