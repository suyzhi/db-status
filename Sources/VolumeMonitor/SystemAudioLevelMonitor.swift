import Accelerate
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
    private let integrator = LoudnessIntegrator()
    /// 仅音频回调使用：上一块是否为纯静音。
    private var previousBlockWasSilent = false

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
        stateLock.unlock()

        captureQueue.async { [weak self] in
            guard let self else { return }
            // 启动竞态：本方法通常在 CoreAudio tap 配置完成之前就被调用。
            // 早期实现把 sampleRate 在调用线程读好再带进来，读到的往往是 nil，
            // 于是这里会把 configureCoreAudioTap 刚建好的引擎清成 nil，而且因为
            // requestedCalibrationID 已更新，后续同样参数的调用都会提前返回、
            // 再也不会重试 —— 表现为"校准随机失效"，两套结果相差 5 dB 以上。
            // 正确做法：sampleRate 在队列内现读；采集未就绪时保留请求，交给
            // configureCoreAudioTap 用 requestedCalibrationProfile 建引擎。
            guard let profile else {
                calibratedMeter = nil
                stateLock.lock()
                calibrationFallbackReason = nil
                stateLock.unlock()
                vm_atomic_u32_store(calibrationAppliedBits, 0)
                AppDiagnostics.log("calib: profile cleared, engine disabled")
                return
            }
            guard profile.frequencyCalibrationUsable else {
                calibratedMeter = nil
                stateLock.lock()
                calibrationFallbackReason = "FFT 校准引擎无法启用"
                stateLock.unlock()
                vm_atomic_u32_store(calibrationAppliedBits, 0)
                AppDiagnostics.log("calib: profile not usable, engine disabled")
                return
            }

            stateLock.lock()
            let currentSampleRate = sampleRate
            let channels = audioChannelCount
            stateLock.unlock()

            guard let currentSampleRate else {
                AppDiagnostics.log("calib: deferred until capture configured")
                return
            }
            guard let meter = CalibratedAudioLevelMeter(
                sampleRate: currentSampleRate,
                channelCount: channels,
                frequencyPoints: profile.frequencyPoints
            ) else {
                calibratedMeter = nil
                stateLock.lock()
                calibrationFallbackReason = "FFT 校准引擎无法启用"
                stateLock.unlock()
                vm_atomic_u32_store(calibrationAppliedBits, 0)
                AppDiagnostics.log("calib: engine init failed rate=\(currentSampleRate) ch=\(channels)")
                return
            }
            calibratedMeter = meter
            stateLock.lock()
            calibrationFallbackReason = nil
            stateLock.unlock()
            AppDiagnostics.log("calib: engine ready rate=\(currentSampleRate) ch=\(channels)")
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

        // 必须使用锁内拷贝出的 effectiveStatus，直接读属性是无保护的数据竞争。
        if effectiveStatus == .capturing {
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
        integrator.resetAudioThreadState()
        previousBlockWasSilent = false
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
                AppDiagnostics.log("calib: engine init failed at capture start")
            } else {
                AppDiagnostics.log("calib: engine built at capture start")
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

    /// 主线程：取走自上次以来累计的有声能量（用于声暴露积分与 LAFmax）。
    func drainLoudness() -> LoudnessIntegrator.Drained {
        integrator.drain()
    }

    fileprivate func processAudioBufferList(_ audioBufferList: UnsafePointer<AudioBufferList>?) {
        guard let audioBufferList else { return }
        let sampleRate = aWeightingMeter.sampleRate
        let block = Self.blockPeakAndFrames(audioBufferList)
        guard block.frames > 0 else { return }

        if block.peak == 0 {
            // 没有任何 App 出声时 tap 仍持续送零：跳过 IIR 与 FFT，只让 Fast 计权衰减。
            if !previousBlockWasSilent {
                aWeightingMeter.reset()
                calibratedMeter?.reset()
                previousBlockWasSilent = true
            }
            publishLevels(
                fastMeanSquare: integrator.addSilence(frames: block.frames, sampleRate: sampleRate),
                blockPeak: 0
            )
            return
        }
        previousBlockWasSilent = false

        // 校准引擎每个 FFT 窗口回调一次能量；窗口攒满之前（约 85 ms）用标准 A 加权兜底。
        var calibratedReady = false
        if let calibratedMeter {
            let integrator = integrator
            calibratedReady = calibratedMeter.measure(audioBufferList) { meanSquare, frames in
                integrator.add(meanSquare: meanSquare, frames: frames, sampleRate: sampleRate)
            } != nil
        }
        if !calibratedReady {
            guard let standard = aWeightingMeter.measure(audioBufferList) else { return }
            integrator.add(
                meanSquare: Double(standard.rms) * Double(standard.rms),
                frames: standard.frames,
                sampleRate: sampleRate
            )
        }
        vm_atomic_u32_store(calibrationAppliedBits, calibratedMeter == nil ? 0 : 1)
        publishLevels(fastMeanSquare: integrator.fastMeanSquare, blockPeak: block.peak)
    }

    /// 显示用电平：Fast（125 ms）计权的 A 加权电平；峰值为未加权采样峰值，按块衰减。
    private func publishLevels(fastMeanSquare: Double, blockPeak: Float) {
        let fastRMS = Float(sqrt(max(0, fastMeanSquare)))
        let oldPeak = Float(bitPattern: vm_atomic_u32_load(peakLinearBits))
        let heldPeak = max(blockPeak, oldPeak * 0.82)
        vm_atomic_u32_store(rmsLinearBits, fastRMS.bitPattern)
        vm_atomic_u32_store(peakLinearBits, heldPeak.bitPattern)
        vm_atomic_u32_store(rmsBits, Self.dbFS(fromLinear: fastRMS).bitPattern)
        vm_atomic_u32_store(peakBits, Self.dbFS(fromLinear: heldPeak).bitPattern)
        vm_atomic_u64_store(lastSampleBits, Self.monotonicTime().bitPattern)
    }

    private static func blockPeakAndFrames(
        _ audioBufferList: UnsafePointer<AudioBufferList>
    ) -> (peak: Float, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        var peak: Float = 0
        var frames = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(count))
            peak = max(peak, bufferPeak)
            frames = max(frames, count / max(1, Int(buffer.mNumberChannels)))
        }
        return (peak, frames)
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

private let systemAudioTapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<SystemAudioLevelMonitor>
        .fromOpaque(clientData)
        .takeUnretainedValue()
        .processAudioBufferList(inputData)
    return noErr
}
