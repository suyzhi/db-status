import AppKit
import CoreAudio
import Foundation

if CommandLine.arguments.contains("--self-test-audio") {
    exit(Int32(runAudioSelfTest()))
}

if CommandLine.arguments.contains("--self-test-logic") {
    exit(Int32(runLogicSelfTest()))
}

if CommandLine.arguments.contains("--self-test-calibration-tone") {
    runCalibrationToneSelfTest()
}

@MainActor
private func runCalibrationToneSelfTest() -> Never {
    let app = NSApplication.shared
    Task { @MainActor in
        let tone = CalibrationToneGenerator()
        do {
            try await tone.playTone(
                frequencyHz: 1_000,
                duration: 0.5,
                rmsDBFS: -70,
                fadeIn: 0.1,
                fadeOut: 0.1
            )
            guard !tone.isPlaying else {
                print("calibration-tone-self-test: player did not stop")
                exit(21)
            }
            print("calibration-tone-self-test: passed; tone stopped")
            exit(0)
        } catch {
            print("calibration-tone-self-test: failed: \(error.localizedDescription)")
            tone.stop()
            exit(20)
        }
    }
    app.run()
    fatalError("NSApplication run loop returned unexpectedly")
}

private func runAudioSelfTest() -> Int {
    let monitor = SystemAudioLevelMonitor()
    monitor.start()
    defer { monitor.stop() }

    var lastSnapshot = monitor.snapshot()
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 0.2)
        let snapshot = monitor.snapshot()
        lastSnapshot = snapshot
        print(String(format: "status=%@ rmsA=%.1f peak=%.1f usable=%@",
                     statusDescription(snapshot.status),
                     snapshot.rmsAWeightedDBFS,
                     snapshot.peakUnweightedDBFS,
                     snapshot.hasUsableAudio ? "true" : "false"))

        if snapshot.hasUsableAudio {
            return 0
        }

        switch snapshot.status {
        case .noPermission:
            return 2
        case .failed:
            return 3
        default:
            break
        }
    }

    return lastSnapshot.status == .capturing || lastSnapshot.status == .noAudio ? 4 : 5
}

private func statusDescription(_ status: AudioCaptureStatus) -> String {
    switch status {
    case .idle:
        return "idle"
    case .starting:
        return "starting"
    case .capturing:
        return "capturing"
    case .noPermission:
        return "noPermission"
    case .noAudio:
        return "noAudio"
    case .failed(let message):
        return "failed(\(message))"
    }
}

private func runLogicSelfTest() -> Int {
    let profile = TransducerProfile(
        name: "self-test",
        deviceUID: "self-test",
        kind: .wiredHeadphones,
        sensitivity: .dbPerVolt(100),
        outputSource: OutputSourceProfile(
            maxOutputVRMS: 2,
            volumeCurve: [
                VolumeCurvePoint(volumeScalar: 0, attenuationDB: -65),
                VolumeCurvePoint(volumeScalar: 1, attenuationDB: 0)
            ]
        ),
        reference: "self-test",
        isConfirmed: true
    )
    guard let estimate = LevelEstimator.estimate(
        volumeScalar: 1,
        isMuted: false,
        rmsAWeightedDBFS: 0,
        profile: profile
    ), abs(estimate.estimatedLevelDBA - 106.0206) < 0.001 else {
        print("logic-self-test: voltage formula failed")
        return 10
    }

    let adultEnergy = ExposureMath.normalizedEnergyAt80(
        levelDBA: 80,
        duration: 40 * 60 * 60
    )
    guard abs(ExposureMath.doseFraction(
        normalizedEnergyAt80: adultEnergy,
        mode: .adult
    ) - 1) < 0.000_001 else {
        print("logic-self-test: exposure formula failed")
        return 11
    }

    let meter = AWeightingMeter(sampleRate: 48_000, channelCount: 2)
    guard abs(meter.frequencyResponseDB(at: 1_000)) < 0.01,
          abs(meter.frequencyResponseDB(at: 100) - (-19.1)) < 1.8 else {
        print("logic-self-test: A-weighting response failed")
        return 12
    }

    guard validateAudioBufferLayouts() else {
        print("logic-self-test: audio buffer layout failed")
        return 14
    }

    guard LevelEstimator.estimate(
        volumeScalar: 1,
        isMuted: false,
        rmsAWeightedDBFS: -10,
        profile: nil
    ) == nil else {
        print("logic-self-test: unknown device policy failed")
        return 13
    }

    print("logic-self-test: passed")
    return 0
}

private func validateAudioBufferLayouts() -> Bool {
    let frameCount = 4_800
    let amplitude: Float = 0.5
    let mono = (0..<frameCount).map { frame in
        amplitude * sin(2 * Float.pi * 1_000 * Float(frame) / 48_000)
    }
    var interleaved = mono.flatMap { [$0, $0] }
    let interleavedOK = interleaved.withUnsafeMutableBufferPointer { samples in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(samples, numberOfChannels: 2)
        )
        let meter = AWeightingMeter(sampleRate: 48_000, channelCount: 2)
        return withUnsafePointer(to: &list) { pointer in
            guard let result = meter.measure(pointer) else { return false }
            return (0.33...0.38).contains(result.rms) && abs(result.peak - amplitude) < 0.001
        }
    }

    var left = mono
    var right = mono
    let nonInterleavedOK = left.withUnsafeMutableBufferPointer { leftSamples in
        right.withUnsafeMutableBufferPointer { rightSamples in
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { list.unsafeMutablePointer.deallocate() }
            list.count = 2
            list[0] = AudioBuffer(leftSamples, numberOfChannels: 1)
            list[1] = AudioBuffer(rightSamples, numberOfChannels: 1)
            let meter = AWeightingMeter(sampleRate: 48_000, channelCount: 2)
            guard let result = meter.measure(list.unsafePointer) else { return false }
            return (0.33...0.38).contains(result.rms) && abs(result.peak - amplitude) < 0.001
        }
    }
    return interleavedOK && nonInterleavedOK
}

// MARK: - App Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
