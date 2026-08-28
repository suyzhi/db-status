import CoreAudio
import Darwin
import Foundation
import VolumeMonitorAtomics

struct AudioLevelSnapshot: Sendable {
    let rmsAWeightedDBFS: Float
    let peakUnweightedDBFS: Float
    let rmsLinear: Float
    let peakLinear: Float
    let status: AudioCaptureStatus
    let lastSampleMonotonicTime: Double?
    let sampleRate: Double?
    let formatDescription: String?
    let frequencyCalibrationApplied: Bool
    let calibrationFallbackReason: String?

    var hasUsableAudio: Bool {
        status == .capturing && rmsAWeightedDBFS > -80
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

enum AudioMonitorError: LocalizedError {
    case processTapUnsupported
    case permissionRequired(OSStatus)
    case audioUnavailable(OSStatus)
    case processTapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case unsupportedAudioFormat(String)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .processTapUnsupported:
            "当前系统不支持 CoreAudio 系统音频 tap"
        case .permissionRequired:
            "系统音频权限未授权"
        case .audioUnavailable:
            "当前没有可读取的系统输出音频"
        case .processTapCreationFailed(let status):
            "系统音频 tap 创建失败 (\(Self.describe(status)))"
        case .aggregateCreationFailed(let status):
            "系统音频读取设备创建失败 (\(Self.describe(status)))"
        case .unsupportedAudioFormat(let description):
            "不支持的系统音频格式 (\(description))"
        case .ioProcCreationFailed(let status):
            "系统音频读取回调创建失败 (\(Self.describe(status)))"
        case .startFailed(let status):
            "系统音频读取启动失败 (\(Self.describe(status)))"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let code = UInt32(bitPattern: status)
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }),
           let fourCC = String(bytes: bytes, encoding: .macOSRoman) {
            return "\(status) / \(fourCC)"
        }
        return "\(status)"
    }
}

final class SystemAudioLevelMonitor: NSObject, @unchecked Sendable {
    private let stateLock = NSLock()
    private let captureQueue = DispatchQueue(label: "com.volumemonitor.audio-capture")

    private let rmsBits = vm_atomic_u32_create(Float(-96).bitPattern)!
    private let peakBits = vm_atomic_u32_create(Float(-96).bitPattern)!
    private let rmsLinearBits = vm_atomic_u32_create(Float(0).bitPattern)!
    private let peakLinearBits = vm_atomic_u32_create(Float(0).bitPattern)!
    private let lastSampleBits = vm_atomic_u64_create(0)!
    private let calibrationAppliedBits = vm_atomic_u32_create(0)!

    // These resources are owned exclusively by captureQueue.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var aWeightingMeter = AWeightingMeter(sampleRate: 48_000, channelCount: 2)
    private var calibratedMeter: CalibratedAudioLevelMeter?

    private var status: AudioCaptureStatus = .idle
    private var shouldRun = false
    private var captureStartedMonotonicTime: Double?
    private var sampleRate: Double?
    private var audioFormatDescription: String?
    private var audioChannelCount = 2
    private var requestedCalibrationProfile: CalibrationProfile?
    private var requestedCalibrationID: UUID?
    private var calibrationFallbackReason: String?

    deinit {
        vm_atomic_u32_destroy(rmsBits)
        vm_atomic_u32_destroy(peakBits)
        vm_atomic_u32_destroy(rmsLinearBits)
        vm_atomic_u32_destroy(peakLinearBits)
        vm_atomic_u64_destroy(lastSampleBits)
        vm_atomic_u32_destroy(calibrationAppliedBits)
    }

    var hasStarted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldRun
    }

    func start() {
        stateLock.lock()
        guard !shouldRun else {
            stateLock.unlock()
            return
        }
        shouldRun = true
        status = .starting
        captureStartedMonotonicTime = Self.monotonicTime()
        stateLock.unlock()

        captureQueue.async { [weak self] in self?.startCaptureOnQueue() }
    }

    func stop() {
        stateLock.lock()
        shouldRun = false
        status = .idle
        captureStartedMonotonicTime = nil
        stateLock.unlock()
        captureQueue.async { [weak self] in self?.stopCaptureOnQueue() }
    }

    func setCalibrationProfile(_ profile: CalibrationProfile?) {
        stateLock.lock()
        let newID = profile?.id
        guard requestedCalibrationID != newID else {
            stateLock.unlock()
            return
        }
        requestedCalibrationID = newID
        requestedCalibrationProfile = profile
        let currentSampleRate = sampleRate
        let channels = audioChannelCount
        stateLock.unlock()

        captureQueue.async { [weak self] in
            guard let self else { return }
            guard let profile,
                  profile.frequencyCalibrationUsable,
                  let currentSampleRate,
                  let meter = CalibratedAudioLevelMeter(
                    sampleRate: currentSampleRate,
                    channelCount: channels,
                    frequencyPoints: profile.frequencyPoints
                  ) else {
                calibratedMeter = nil
                stateLock.lock()
                calibrationFallbackReason = profile == nil ? nil : "FFT 校准引擎无法启用"
                stateLock.unlock()
                vm_atomic_u32_store(calibrationAppliedBits, 0)
                return
            }
            calibratedMeter = meter
            stateLock.lock()
            calibrationFallbackReason = nil
            stateLock.unlock()
        }
    }

    func snapshot() -> AudioLevelSnapshot {
        let rms = Float(bitPattern: vm_atomic_u32_load(rmsBits))
        let peak = Float(bitPattern: vm_atomic_u32_load(peakBits))
        let linearRMS = Float(bitPattern: vm_atomic_u32_load(rmsLinearBits))
        let linearPeak = Float(bitPattern: vm_atomic_u32_load(peakLinearBits))
        let lastSampleRaw = vm_atomic_u64_load(lastSampleBits)
        let lastSample = lastSampleRaw == 0 ? nil : Double(bitPattern: lastSampleRaw)

        stateLock.lock()
        var effectiveStatus = status
        let started = captureStartedMonotonicTime
        let currentSampleRate = sampleRate
        let currentFormat = audioFormatDescription
        let fallbackReason = calibrationFallbackReason
        stateLock.unlock()

        if status == .capturing {
            let now = Self.monotonicTime()
            if let lastSample, now - lastSample > 2 {
                effectiveStatus = .noAudio
            } else if lastSample == nil, let started, now - started > 2 {
                effectiveStatus = .noAudio
            } else if rms <= -80 {
                effectiveStatus = .noAudio
            }
        }

        return AudioLevelSnapshot(
            rmsAWeightedDBFS: rms,
            peakUnweightedDBFS: peak,
            rmsLinear: linearRMS,
            peakLinear: linearPeak,
            status: effectiveStatus,
            lastSampleMonotonicTime: lastSample,
            sampleRate: currentSampleRate,
            formatDescription: currentFormat,
            frequencyCalibrationApplied: vm_atomic_u32_load(calibrationAppliedBits) != 0,
            calibrationFallbackReason: fallbackReason
        )
    }

    private func startCaptureOnQueue() {
        stopCaptureOnQueue(resetStatus: false)
        do {
            try configureCoreAudioTap()
            guard readShouldRun() else {
                stopCaptureOnQueue()
                return
            }
            setStatus(.capturing)
        } catch AudioMonitorError.permissionRequired(_) {
            finishStartFailure(.noPermission)
        } catch AudioMonitorError.audioUnavailable(_) {
            finishStartFailure(.noAudio)
        } catch {
            finishStartFailure(.failed(error.localizedDescription))
        }
    }

    private func finishStartFailure(_ failureStatus: AudioCaptureStatus) {
        stopCaptureOnQueue(resetStatus: false)
        stateLock.lock()
        shouldRun = false
        status = failureStatus
        stateLock.unlock()
    }

    private func stopCaptureOnQueue(resetStatus: Bool = true) {
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        aWeightingMeter.reset()
        calibratedMeter = nil
        resetAtomicLevels()

        stateLock.lock()
        sampleRate = nil
        audioFormatDescription = nil
        if resetStatus, !shouldRun { status = .idle }
        stateLock.unlock()
    }

    private func configureCoreAudioTap() throws {
        guard #available(macOS 14.2, *) else {
            throw AudioMonitorError.processTapUnsupported
        }

        let excludedProcessIDs = currentProcessObjectID().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessIDs)
        description.name = "VolumeMonitor System Audio"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var result = AudioHardwareCreateProcessTap(description, &newTapID)
        guard result == noErr else { throw Self.errorForTap(result) }

        let aggregateDescription: NSDictionary = [
            kAudioAggregateDeviceNameKey: "VolumeMonitor Audio Tap",
            kAudioAggregateDeviceUIDKey: "com.volumemonitor.audio-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        result = AudioHardwareCreateAggregateDevice(aggregateDescription, &newAggregateID)
        guard result == noErr else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw Self.errorForAggregate(result)
        }

        guard let streamFormat = Self.streamFormat(deviceID: newAggregateID) else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw AudioMonitorError.unsupportedAudioFormat("无法读取流格式")
        }
        let formatText = Self.describe(streamFormat)
        guard streamFormat.mFormatID == kAudioFormatLinearPCM,
              streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              streamFormat.mBitsPerChannel == 32,
              streamFormat.mSampleRate > 0,
              streamFormat.mChannelsPerFrame > 0 else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw AudioMonitorError.unsupportedAudioFormat(formatText)
        }

        aWeightingMeter = AWeightingMeter(
            sampleRate: streamFormat.mSampleRate,
            channelCount: Int(streamFormat.mChannelsPerFrame)
        )
        stateLock.lock()
        sampleRate = streamFormat.mSampleRate
        audioChannelCount = Int(streamFormat.mChannelsPerFrame)
        audioFormatDescription = formatText
        let calibrationProfile = requestedCalibrationProfile
        stateLock.unlock()
        if let calibrationProfile, calibrationProfile.frequencyCalibrationUsable {
            calibratedMeter = CalibratedAudioLevelMeter(
                sampleRate: streamFormat.mSampleRate,
                channelCount: Int(streamFormat.mChannelsPerFrame),
                frequencyPoints: calibrationProfile.frequencyPoints
            )
            if calibratedMeter == nil {
                stateLock.lock()
                calibrationFallbackReason = "FFT 校准引擎初始化失败"
                stateLock.unlock()
            }
        }

        var newIOProcID: AudioDeviceIOProcID?
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        result = AudioDeviceCreateIOProcID(
            newAggregateID,
            systemAudioTapIOProc,
            clientData,
            &newIOProcID
        )
        guard result == noErr, let newIOProcID else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw Self.errorForIOProc(result)
        }

        result = AudioDeviceStart(newAggregateID, newIOProcID)
        guard result == noErr else {
            AudioDeviceDestroyIOProcID(newAggregateID, newIOProcID)
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw Self.errorForStart(result)
        }

        tapID = newTapID
        aggregateDeviceID = newAggregateID
        ioProcID = newIOProcID
    }

    private func currentProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
        let result = withUnsafePointer(to: &pid) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                $0,
                &dataSize,
                &processObjectID
            )
        }
        return result == noErr && processObjectID != kAudioObjectUnknown ? processObjectID : nil
    }

    fileprivate func processAudioBufferList(_ audioBufferList: UnsafePointer<AudioBufferList>?) {
        guard let audioBufferList,
              let standardLevels = aWeightingMeter.measure(audioBufferList) else { return }
        let calibratedLevels = calibratedMeter?.measure(audioBufferList)
        let levels = calibratedLevels ?? standardLevels
        vm_atomic_u32_store(calibrationAppliedBits, calibratedLevels == nil ? 0 : 1)

        let oldRMS = Float(bitPattern: vm_atomic_u32_load(rmsLinearBits))
        let oldPeak = Float(bitPattern: vm_atomic_u32_load(peakLinearBits))
        let smoothing: Float = levels.rms > oldRMS ? 0.55 : 0.16
        let smoothedRMS = oldRMS + (levels.rms - oldRMS) * smoothing
        let smoothedPeak = max(levels.peak, oldPeak * 0.82)

        vm_atomic_u32_store(rmsLinearBits, smoothedRMS.bitPattern)
        vm_atomic_u32_store(peakLinearBits, smoothedPeak.bitPattern)
        vm_atomic_u32_store(rmsBits, Self.dbFS(fromLinear: smoothedRMS).bitPattern)
        vm_atomic_u32_store(peakBits, Self.dbFS(fromLinear: smoothedPeak).bitPattern)
        vm_atomic_u64_store(lastSampleBits, Self.monotonicTime().bitPattern)
    }

    private func readShouldRun() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldRun
    }

    private func setStatus(_ newStatus: AudioCaptureStatus) {
        stateLock.lock()
        status = newStatus
        stateLock.unlock()
    }

    private func resetAtomicLevels() {
        vm_atomic_u32_store(rmsBits, Float(-96).bitPattern)
        vm_atomic_u32_store(peakBits, Float(-96).bitPattern)
        vm_atomic_u32_store(rmsLinearBits, Float(0).bitPattern)
        vm_atomic_u32_store(peakLinearBits, Float(0).bitPattern)
        vm_atomic_u64_store(lastSampleBits, 0)
        vm_atomic_u32_store(calibrationAppliedBits, 0)
    }

    private static func dbFS(fromLinear value: Float) -> Float {
        guard value > 0.000001 else { return -96 }
        return max(-96, min(0, 20 * log10(value)))
    }

    private static func monotonicTime() -> Double {
        Double(mach_continuous_time()) * secondsPerTick
    }

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static func streamFormat(deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format) == noErr {
                return format
            }
        }
        return nil
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return String(
            format: "%.0f Hz / %u ch / %u bit / %@",
            format.mSampleRate,
            format.mChannelsPerFrame,
            format.mBitsPerChannel,
            interleaved ? "interleaved" : "non-interleaved"
        )
    }

    private static func isPermissionStatus(_ status: OSStatus) -> Bool {
        status == kAudioDevicePermissionsError || status == kAudioHardwareIllegalOperationError
    }

    private static func isAudioUnavailableStatus(_ status: OSStatus) -> Bool {
        status == kAudioHardwareNotRunningError ||
        status == kAudioHardwareNotReadyError ||
        status == kAudioHardwareBadDeviceError ||
        status == kAudioHardwareBadObjectError
    }

    private static func errorForTap(_ status: OSStatus) -> AudioMonitorError {
        if isPermissionStatus(status) { return .permissionRequired(status) }
        if isAudioUnavailableStatus(status) { return .audioUnavailable(status) }
        return .processTapCreationFailed(status)
    }

    private static func errorForAggregate(_ status: OSStatus) -> AudioMonitorError {
        if isPermissionStatus(status) { return .permissionRequired(status) }
        if isAudioUnavailableStatus(status) { return .audioUnavailable(status) }
        return .aggregateCreationFailed(status)
    }

    private static func errorForIOProc(_ status: OSStatus) -> AudioMonitorError {
        if isPermissionStatus(status) { return .permissionRequired(status) }
        if isAudioUnavailableStatus(status) { return .audioUnavailable(status) }
        return .ioProcCreationFailed(status)
    }

    private static func errorForStart(_ status: OSStatus) -> AudioMonitorError {
        if isPermissionStatus(status) { return .permissionRequired(status) }
        if isAudioUnavailableStatus(status) { return .audioUnavailable(status) }
        return .startFailed(status)
    }
}

struct BiquadCoefficients: Sendable {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static func bilinear(
        sampleRate: Double,
        numerator: (Double, Double, Double),
        denominator: (Double, Double, Double)
    ) -> BiquadCoefficients {
        let c = 2 * sampleRate
        let c2 = c * c
        let (b2s, b1s, b0s) = numerator
        let (a2s, a1s, a0s) = denominator
        let b0 = b2s * c2 + b1s * c + b0s
        let b1 = -2 * b2s * c2 + 2 * b0s
        let b2 = b2s * c2 - b1s * c + b0s
        let a0 = a2s * c2 + a1s * c + a0s
        let a1 = -2 * a2s * c2 + 2 * a0s
        let a2 = a2s * c2 - a1s * c + a0s
        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    func magnitude(frequency: Double, sampleRate: Double) -> Double {
        let omega = -2 * Double.pi * frequency / sampleRate
        let z1 = Complex(cos(omega), sin(omega))
        let z2 = z1 * z1
        let numerator = Complex(b0, 0) + z1 * b1 + z2 * b2
        let denominator = Complex(1, 0) + z1 * a1 + z2 * a2
        return (numerator / denominator).magnitude
    }
}

private struct BiquadState {
    let coefficients: BiquadCoefficients
    var z1 = 0.0
    var z2 = 0.0

    mutating func process(_ input: Double) -> Double {
        let output = coefficients.b0 * input + z1
        z1 = coefficients.b1 * input - coefficients.a1 * output + z2
        z2 = coefficients.b2 * input - coefficients.a2 * output
        return output
    }
}

private struct ChannelAWeightingFilter {
    var sections: [BiquadState]
    let gain: Double

    mutating func process(_ input: Double) -> Double {
        var output = input
        for index in sections.indices {
            output = sections[index].process(output)
        }
        return output * gain
    }
}

final class AWeightingMeter {
    let sampleRate: Double
    private let coefficients: [BiquadCoefficients]
    private let normalizationGain: Double
    private var filters: [ChannelAWeightingFilter]

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        let sectionCoefficients = Self.makeCoefficients(sampleRate: sampleRate)
        coefficients = sectionCoefficients
        let magnitudeAt1K = sectionCoefficients.reduce(1.0) {
            $0 * $1.magnitude(frequency: 1_000, sampleRate: sampleRate)
        }
        let gain = magnitudeAt1K > 0 ? 1 / magnitudeAt1K : 1
        normalizationGain = gain
        filters = (0..<max(1, channelCount)).map { _ in
            ChannelAWeightingFilter(
                sections: sectionCoefficients.map { BiquadState(coefficients: $0) },
                gain: gain
            )
        }
    }

    func reset() {
        filters = filters.map { _ in
            ChannelAWeightingFilter(
                sections: coefficients.map { BiquadState(coefficients: $0) },
                gain: normalizationGain
            )
        }
    }

    func frequencyResponseDB(at frequency: Double) -> Double {
        let magnitude = coefficients.reduce(normalizationGain) {
            $0 * $1.magnitude(frequency: frequency, sampleRate: sampleRate)
        }
        return 20 * log10(max(magnitude, .leastNonzeroMagnitude))
    }

    func measure(_ audioBufferList: UnsafePointer<AudioBufferList>) -> (rms: Float, peak: Float)? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        var sumSquares = 0.0
        var peak: Float = 0
        var sampleCount = 0
        var channelOffset = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let frameCount = count / channelCount
            guard frameCount > 0, channelOffset + channelCount <= filters.count else { return nil }
            let samples = data.bindMemory(to: Float.self, capacity: count)

            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let sample = samples[frame * channelCount + channel]
                    peak = max(peak, abs(sample))
                    let weighted = filters[channelOffset + channel].process(Double(sample))
                    sumSquares += weighted * weighted
                }
            }
            sampleCount += frameCount * channelCount
            channelOffset += channelCount
        }

        guard sampleCount > 0 else { return nil }
        return (
            rms: min(max(Float(sqrt(sumSquares / Double(sampleCount))), 0), 1),
            peak: min(max(peak, 0), 1)
        )
    }

    private static func makeCoefficients(sampleRate: Double) -> [BiquadCoefficients] {
        let w1 = 2 * Double.pi * 20.598997
        let w2 = 2 * Double.pi * 107.65265
        let w3 = 2 * Double.pi * 737.86223
        let w4 = 2 * Double.pi * 12_194.217
        return [
            .bilinear(
                sampleRate: sampleRate,
                numerator: (1, 0, 0),
                denominator: (1, 2 * w1, w1 * w1)
            ),
            .bilinear(
                sampleRate: sampleRate,
                numerator: (0, 1, 0),
                denominator: (1, w2 + w3, w2 * w3)
            ),
            .bilinear(
                sampleRate: sampleRate,
                numerator: (0, 1, 0),
                denominator: (1, 2 * w4, w4 * w4)
            )
        ]
    }
}

private struct Complex {
    let real: Double
    let imaginary: Double

    init(_ real: Double, _ imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    var magnitude: Double { hypot(real, imaginary) }

    static func +(lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real + rhs.real, lhs.imaginary + rhs.imaginary)
    }

    static func *(lhs: Complex, rhs: Complex) -> Complex {
        Complex(
            lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }

    static func *(lhs: Complex, rhs: Double) -> Complex {
        Complex(lhs.real * rhs, lhs.imaginary * rhs)
    }

    static func /(lhs: Complex, rhs: Complex) -> Complex {
        let denominator = rhs.real * rhs.real + rhs.imaginary * rhs.imaginary
        return Complex(
            (lhs.real * rhs.real + lhs.imaginary * rhs.imaginary) / denominator,
            (lhs.imaginary * rhs.real - lhs.real * rhs.imaginary) / denominator
        )
    }
}

private let systemAudioTapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<SystemAudioLevelMonitor>
        .fromOpaque(clientData)
        .takeUnretainedValue()
        .processAudioBufferList(inputData)
    return noErr
}
