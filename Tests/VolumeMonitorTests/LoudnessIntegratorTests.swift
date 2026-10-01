import Foundation
import Testing
@testable import VolumeMonitor

@Suite struct LoudnessIntegratorTests {
    @Test func steadySignalIntegratesExactEnergyAndDuration() {
        let integrator = LoudnessIntegrator()
        // 2 秒、每块 512 帧、−20 dBFS RMS（均方 0.01）。
        for _ in 0..<(96_000 / 512) {
            integrator.add(meanSquare: 0.01, frames: 512, sampleRate: 48_000)
        }
        let drained = integrator.drain()
        #expect(abs(drained.activeSeconds - 2) < 0.011)
        #expect(abs(drained.meanSquare - 0.01) < 1e-12)
        #expect(integrator.drain() == .empty)
    }

    @Test func silenceIsNotCountedAsListeningTime() {
        let integrator = LoudnessIntegrator()
        integrator.add(meanSquare: 0.01, frames: 48_000, sampleRate: 48_000)
        integrator.addSilence(frames: 48_000 * 5, sampleRate: 48_000)
        let drained = integrator.drain()
        #expect(abs(drained.activeSeconds - 1) < 1e-9)
        #expect(abs(drained.meanSquare - 0.01) < 1e-12)
    }

    @Test func energyAverageIsNotBiasedByLoudBursts() {
        // 一半时间 −10 dBFS、一半 −30 dBFS：LAeq 应为能量平均 ≈ −13 dB，
        // 旧的"快升慢降"平滑会明显偏高。
        let integrator = LoudnessIntegrator()
        for _ in 0..<50 {
            integrator.add(meanSquare: 0.1, frames: 480, sampleRate: 48_000)
            integrator.add(meanSquare: 0.001, frames: 480, sampleRate: 48_000)
        }
        let level = 10 * log10(integrator.drain().meanSquare)
        #expect(abs(level - 10 * log10(0.0505)) < 1e-9)
    }

    @Test func fastTimeWeightingReaches63PercentAt125Milliseconds() {
        let integrator = LoudnessIntegrator()
        for _ in 0..<125 {
            integrator.add(meanSquare: 1, frames: 48, sampleRate: 48_000)
        }
        #expect(abs(integrator.fastMeanSquare - (1 - exp(-1))) < 0.001)
        #expect(integrator.drain().maxFastMeanSquare <= 1)
    }

    @Test func maxFastTracksTheLoudestMomentSinceLastDrain() {
        let integrator = LoudnessIntegrator()
        integrator.add(meanSquare: 1, frames: 48_000, sampleRate: 48_000)
        integrator.add(meanSquare: 0.01, frames: 48_000, sampleRate: 48_000)
        let first = integrator.drain()
        #expect(first.maxFastMeanSquare > 0.99)
        integrator.add(meanSquare: 0.01, frames: 48_000, sampleRate: 48_000)
        #expect(integrator.drain().maxFastMeanSquare < 0.02)
    }
}

@Suite @MainActor struct ExposureIngestTests {
    @Test func durationComesFromAudioFramesNotWallClock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: "VolumeMonitorTests-\(UUID().uuidString)"))
        let service = ExposureService(
            store: LocalDataStore(directoryURL: directory),
            preferences: AppPreferences(defaults: defaults)
        )
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        // 主线程隔了 5 秒才来取数（App Nap），但音频线程记录了 5 秒有声时间：一秒都不丢。
        let summary = service.ingest(
            levelDBA: 80, peakDBA: 86, duration: 5,
            deviceUID: "dev", currentLevelDBA: 80, at: start
        )
        let expected = ExposureMath.doseFraction(
            normalizedEnergyAt80: 5,
            mode: .adult
        )
        #expect(abs(summary.doseFraction - expected) < 1e-12)
        #expect(summary.sessionPeakDBA == 86)
        #expect(summary.sessionLAeq.map { abs($0 - 80) < 1e-9 } == true)

        let none = service.ingest(
            levelDBA: nil, peakDBA: nil, duration: 0,
            deviceUID: "dev", currentLevelDBA: nil, at: start.addingTimeInterval(1)
        )
        #expect(none.doseFraction == summary.doseFraction)
    }
}
