import AVFAudio
import Foundation

enum CalibrationToneError: LocalizedError {
    case unsafeRequiredLevel
    case invalidOutputFormat
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsafeRequiredLevel: "当前耳机模型要求的安全测试电平过低，已停止测试"
        case .invalidOutputFormat: "当前输出设备不支持校准测试音格式"
        case .bufferCreationFailed: "无法创建校准测试音缓冲区"
        }
    }
}

@MainActor
final class CalibrationToneGenerator {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isPlaying = false

    init() {
        engine.attach(player)
    }

    /// 校准测试音的声压安全上限（仅在校准过程中出现，单点几秒、总计一两分钟）。
    /// 90 dBA 对短时暴露是安全的；此前用 84 dBA 偏保守，开放式大耳高频/低频点
    /// 输出低，加上上限后常常够不到 15 dB 信噪比门槛。
    nonisolated static let maximumCalibrationToneDBA: Double = 90

    nonisolated static func safeRMSDBFS(
        requested: Double = -25,
        estimatedFullScaleDBA: Float?
    ) throws -> Double {
        guard let estimatedFullScaleDBA, estimatedFullScaleDBA.isFinite else {
            return min(requested, -45)
        }
        let safe = min(requested, maximumCalibrationToneDBA - Double(estimatedFullScaleDBA))
        guard safe >= -70 else { throw CalibrationToneError.unsafeRequiredLevel }
        return safe
    }

    func playTone(
        frequencyHz: Double,
        duration: TimeInterval,
        rmsDBFS: Double,
        fadeIn: TimeInterval = 0.3,
        fadeOut: TimeInterval = 0.2
    ) async throws {
        stop()
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CalibrationToneError.invalidOutputFormat
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let frameCount = AVAudioFrameCount(max(1, (duration * format.sampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            throw CalibrationToneError.bufferCreationFailed
        }
        buffer.frameLength = frameCount
        let peakAmplitude = pow(10, rmsDBFS / 20) * sqrt(2)
        let fadeInFrames = max(1, Int(fadeIn * format.sampleRate))
        let fadeOutFrames = max(1, Int(fadeOut * format.sampleRate))
        let totalFrames = Int(frameCount)
        for frame in 0..<totalFrames {
            let inGain = min(1, Double(frame) / Double(fadeInFrames))
            let framesRemaining = totalFrames - 1 - frame
            let outGain = min(1, Double(framesRemaining) / Double(fadeOutFrames))
            let envelope = min(inGain, outGain)
            let sample = Float(
                peakAmplitude * envelope *
                sin(2 * Double.pi * frequencyHz * Double(frame) / format.sampleRate)
            )
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }

        engine.prepare()
        try engine.start()
        let schedulingTask = Task { @MainActor [player] in
            await player.scheduleBuffer(buffer, at: nil, options: [])
        }
        await Task.yield()
        player.play()
        isPlaying = true
        defer {
            schedulingTask.cancel()
            stop()
        }
        try await Task.sleep(for: .seconds(duration))
        _ = await schedulingTask.result
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.reset()
        isPlaying = false
    }
}
