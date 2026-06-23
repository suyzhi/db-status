import Foundation
import ScreenCaptureKit
import CoreAudio
import AVFoundation

// MARK: - Audio Level Snapshot
struct AudioLevelSnapshot: Sendable {
    let rmsDBFS: Float
    let peakDBFS: Float
    let rmsLinear: Float
    let peakLinear: Float
    let status: AudioCaptureStatus
    let lastSampleTime: Date?

    var hasUsableAudio: Bool {
        status == .capturing && rmsDBFS > -80
    }
}

enum AudioCaptureStatus: Sendable, Equatable {
    case idle
    case starting
    case capturing
    case noPermission
    case noAudio
    case failed(String)
}

// MARK: - System Audio Level Monitor (ScreenCaptureKit)
final class SystemAudioLevelMonitor: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private let streamQueue = DispatchQueue(label: "com.volumemonitor.audio")
    private var audioOutput: AudioCaptureOutput?

    private var rmsLinear: Float = 0
    private var peakLinear: Float = 0
    private var rmsDBFS: Float = -96
    private var peakDBFS: Float = -96
    private var status: AudioCaptureStatus = .idle
    private var lastSampleTime: Date?
    private(set) var hasStarted = false

    private let stateLock = NSLock()

    @MainActor
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        status = .starting

        Task { await self.setupStream() }
    }

    func stop() {
        hasStarted = false
        stream?.stopCapture()
        stream = nil
        status = .idle

        stateLock.lock()
        rmsLinear = 0
        peakLinear = 0
        rmsDBFS = -96
        peakDBFS = -96
        lastSampleTime = nil
        stateLock.unlock()
    }

    func snapshot() -> AudioLevelSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }

        var effectiveStatus = status
        if status == .capturing {
            if let t = lastSampleTime, Date().timeIntervalSince(t) > 2.0 {
                effectiveStatus = .noAudio
            } else if rmsDBFS <= -80 {
                effectiveStatus = .noAudio
            }
        }

        return AudioLevelSnapshot(
            rmsDBFS: rmsDBFS,
            peakDBFS: peakDBFS,
            rmsLinear: rmsLinear,
            peakLinear: peakLinear,
            status: effectiveStatus,
            lastSampleTime: lastSampleTime
        )
    }

    @MainActor
    private func setupStream() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                status = .noPermission
                return
            }

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let output = AudioCaptureOutput(monitor: self)
            self.audioOutput = output

            stream = SCStream(filter: filter, configuration: config, delegate: nil)

            try stream?.addStreamOutput(output, type: .audio, sampleHandlerQueue: streamQueue)

            try await stream?.startCapture()
            status = .capturing

        } catch {
            if let scError = error as? SCStreamError, scError.code == .userDeclined {
                status = .noPermission
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Called from background queue (streamQueue) — uses lock, no MainActor needed
    fileprivate func processAudioSamples(_ sampleBuffer: CMSampleBuffer) {
        guard let abuf = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length: Int = 0
        var data: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(abuf, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data)

        guard let data, length > 0 else { return }

        let sampleCount = length / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }

        let samples = data.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }

        var sumSquares: Double = 0
        var peak: Float = 0
        for i in 0..<sampleCount {
            let s = samples[i]
            let absS = abs(s)
            peak = max(peak, absS)
            sumSquares += Double(s * s)
        }

        let rms = Float(sqrt(sumSquares / Double(sampleCount)))

        stateLock.lock()
        let attack: Float = 0.55
        let release: Float = 0.16
        let smoothing = rms > rmsLinear ? attack : release
        rmsLinear = rmsLinear + (rms - rmsLinear) * smoothing
        peakLinear = max(peak, peakLinear * 0.82)
        rmsDBFS = rmsLinear > 0.000001 ? max(-96, min(0, 20 * log10(rmsLinear))) : -96
        peakDBFS = peakLinear > 0.000001 ? max(-96, min(0, 20 * log10(peakLinear))) : -96
        lastSampleTime = Date()
        status = .capturing
        stateLock.unlock()
    }
}

// MARK: - SCStreamOutput for audio
private class AudioCaptureOutput: NSObject, SCStreamOutput {
    private weak var monitor: SystemAudioLevelMonitor?

    init(monitor: SystemAudioLevelMonitor) {
        self.monitor = monitor
    }

    func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        monitor?.processAudioSamples(sampleBuffer)
    }
}
