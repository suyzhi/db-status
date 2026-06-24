import AppKit
import Foundation

if CommandLine.arguments.contains("--self-test-audio") {
    exit(Int32(runAudioSelfTest()))
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
        print(String(format: "status=%@ rms=%.1f peak=%.1f usable=%@",
                     statusDescription(snapshot.status),
                     snapshot.rmsDBFS,
                     snapshot.peakDBFS,
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

// MARK: - App Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
