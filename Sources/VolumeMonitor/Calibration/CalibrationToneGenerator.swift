import AudioToolbox
import AVFAudio
import CoreAudio
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
    /// 高音量点的首选测试音电平：信噪比够用，听起来也不刺耳。
    nonisolated static let comfortableCalibrationToneDBA: Double = 80

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
        let totalFrames = Int(frameCount)
        let outputChannelCount = Int(format.channelCount)
        let outputSampleRate = format.sampleRate
        // 最长 4.6 秒的逐样本合成放到后台线程，避免在校准流程里阻塞主线程。
        let toneSamples = await Task.detached(priority: .userInitiated) {
            Self.makeToneSamples(
                frameCount: totalFrames,
                sampleRate: outputSampleRate,
                frequencyHz: frequencyHz,
                rmsDBFS: rmsDBFS,
                fadeIn: fadeIn,
                fadeOut: fadeOut
            )
        }.value
        for channel in 0..<outputChannelCount {
            channels[channel].update(from: toneSamples, count: totalFrames)
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

    nonisolated private static func makeToneSamples(
        frameCount: Int,
        sampleRate: Double,
        frequencyHz: Double,
        rmsDBFS: Double,
        fadeIn: TimeInterval,
        fadeOut: TimeInterval
    ) -> [Float] {
        guard frameCount > 0, sampleRate > 0 else { return [] }
        let peakAmplitude = pow(10, rmsDBFS / 20) * sqrt(2)
        let fadeInFrames = max(1, Int(fadeIn * sampleRate))
        let fadeOutFrames = max(1, Int(fadeOut * sampleRate))
        var samples = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let inGain = min(1, Double(frame) / Double(fadeInFrames))
            let framesRemaining = frameCount - 1 - frame
            let outGain = min(1, Double(framesRemaining) / Double(fadeOutFrames))
            let envelope = min(inGain, outGain)
            samples[frame] = Float(
                peakAmplitude * envelope *
                sin(2 * Double.pi * frequencyHz * Double(frame) / sampleRate)
            )
        }
        return samples
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.reset()
        isPlaying = false
    }
}

enum CalibrationNoiseError: LocalizedError {
    case speakerUnavailable
    case outputUnitUnavailable
    case deviceSelectionFailed(OSStatus)
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .speakerUnavailable: "找不到 MacBook 内置扬声器，无法进行手机对标"
        case .outputUnitUnavailable: "无法创建扬声器输出"
        case .deviceSelectionFailed(let status): "无法切换到内置扬声器输出 (\(status))"
        case .bufferCreationFailed: "无法创建粉红噪声缓冲区"
        }
    }
}

/// 手机对标用：直接从内置扬声器放粉红噪声，不改动系统默认输出设备。
@MainActor
final class CalibrationNoisePlayer {
    static let builtInSpeakerUID = "BuiltInSpeakerDevice"

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var restoreVolume: (deviceID: AudioObjectID, volume: Float32)?

    var isPlaying: Bool { engine?.isRunning == true }

    static func builtInSpeakerDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid = builtInSpeakerUID as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                $0,
                &size,
                &deviceID
            )
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    /// 以固定数字电平循环播放粉红噪声，同时把扬声器音量设到 `deviceVolume`（结束后恢复）。
    func start(rmsDBFS: Double = -20, deviceVolume: Float32 = 0.5) throws {
        stop()
        guard let deviceID = Self.builtInSpeakerDeviceID() else {
            throw CalibrationNoiseError.speakerUnavailable
        }
        let engine = AVAudioEngine()
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw CalibrationNoiseError.outputUnitUnavailable
        }
        var selected = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selected,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else { throw CalibrationNoiseError.deviceSelectionFailed(status) }

        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CalibrationNoiseError.outputUnitUnavailable
        }
        let frames = AVAudioFrameCount(sampleRate * 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw CalibrationNoiseError.bufferCreationFailed
        }
        let samples = Self.makePinkNoise(frameCount: Int(frames), rmsDBFS: rmsDBFS)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(from: samples, count: samples.count)
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if let current = Self.volume(deviceID: deviceID) {
            restoreVolume = (deviceID, current)
        }
        Self.setVolume(deviceVolume, deviceID: deviceID)
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
        player.play()
        self.engine = engine
        self.player = player
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        if let restoreVolume {
            Self.setVolume(restoreVolume.volume, deviceID: restoreVolume.deviceID)
            self.restoreVolume = nil
        }
    }

    /// Paul Kellet 粉红滤波，按实际 RMS 归一化到目标电平。尾段交叉淡化进开头后丢弃，
    /// 循环播放时末尾样本与开头连续，没有接缝爆音。返回长度为 frameCount − 淡化长度。
    nonisolated static func makePinkNoise(frameCount: Int, rmsDBFS: Double) -> [Float] {
        guard frameCount > 0 else { return [] }
        var generator = SystemRandomNumberGenerator()
        var b = [Double](repeating: 0, count: 7)
        var raw = [Double](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let white = Double.random(in: -1...1, using: &generator)
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            raw[index] = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
        }
        let fade = min(frameCount / 4, 2_048)
        for index in 0..<fade {
            let gain = Double(index) / Double(fade)
            let tail = frameCount - fade + index
            raw[index] = raw[index] * gain + raw[tail] * (1 - gain)
        }
        let used = raw[0..<(frameCount - fade)]
        let mean = used.reduce(0, +) / Double(used.count)
        let rms = sqrt(used.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(used.count))
        guard rms > 0 else { return [Float](repeating: 0, count: frameCount) }
        let scale = pow(10, rmsDBFS / 20) / rms
        return used.map { Float(($0 - mean) * scale) }
    }

    private static func volume(deviceID: AudioObjectID) -> Float32? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private static func setVolume(_ volume: Float32, deviceID: AudioObjectID) {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value = volume
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
        }
    }
}
