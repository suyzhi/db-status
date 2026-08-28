import CoreAudio
import Foundation
import Testing
@testable import VolumeMonitor

@Suite struct AWeightingTests {
    @Test func oneKilohertzIsNormalized() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            let meter = AWeightingMeter(sampleRate: sampleRate, channelCount: 2)
            #expect(abs(meter.frequencyResponseDB(at: 1_000)) <= 0.01)
        }
    }

    @Test func standardFrequencyResponseAt48K() {
        let meter = AWeightingMeter(sampleRate: 48_000, channelCount: 2)
        let expected: [(Double, Double)] = [
            (20, -50.5),
            (100, -19.1),
            (1_000, 0),
            (5_000, 0.5),
            (10_000, -2.5)
        ]
        for (frequency, target) in expected {
            #expect(abs(meter.frequencyResponseDB(at: frequency) - target) <= 1.8)
        }
    }

    @Test func interleavedAndNonInterleavedFloatBuffers() throws {
        let frames = 4_800
        let amplitude: Float = 0.5
        let mono = (0..<frames).map { frame in
            amplitude * sin(2 * Float.pi * 1_000 * Float(frame) / 48_000)
        }
        var interleaved = mono.flatMap { [$0, $0] }
        let interleavedResult = interleaved.withUnsafeMutableBufferPointer { samples in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(samples, numberOfChannels: 2)
            )
            return withUnsafePointer(to: &list) {
                AWeightingMeter(sampleRate: 48_000, channelCount: 2).measure($0)
            }
        }
        #expect(abs(try #require(interleavedResult).rms - 0.3535) <= 0.025)

        var left = mono
        var right = mono
        let nonInterleavedResult = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { list.unsafeMutablePointer.deallocate() }
                list.count = 2
                list[0] = AudioBuffer(leftSamples, numberOfChannels: 1)
                list[1] = AudioBuffer(rightSamples, numberOfChannels: 1)
                return AWeightingMeter(sampleRate: 48_000, channelCount: 2)
                    .measure(list.unsafePointer)
            }
        }
        #expect(abs(try #require(nonInterleavedResult).rms - 0.3535) <= 0.025)
    }
}
