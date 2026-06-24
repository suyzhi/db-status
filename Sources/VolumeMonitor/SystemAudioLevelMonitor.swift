import CoreAudio
import Foundation

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

enum AudioMonitorError: LocalizedError {
    case processTapUnsupported
    case permissionRequired(OSStatus)
    case audioUnavailable(OSStatus)
    case processTapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .processTapUnsupported:
            return "当前系统不支持 CoreAudio 系统音频 tap"
        case .permissionRequired:
            return "系统音频权限未授权"
        case .audioUnavailable:
            return "当前没有可读取的系统输出音频"
        case .processTapCreationFailed(let status):
            return "系统音频 tap 创建失败 (\(Self.describe(status)))"
        case .aggregateCreationFailed(let status):
            return "系统音频读取设备创建失败 (\(Self.describe(status)))"
        case .ioProcCreationFailed(let status):
            return "系统音频读取回调创建失败 (\(Self.describe(status)))"
        case .startFailed(let status):
            return "系统音频读取启动失败 (\(Self.describe(status)))"
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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var rmsLinear: Float = 0
    private var peakLinear: Float = 0
    private var rmsDBFS: Float = -96
    private var peakDBFS: Float = -96
    private var aWeightingMeter = AWeightingMeter(sampleRate: 48_000)
    private var status: AudioCaptureStatus = .idle
    private var lastSampleTime: Date?
    private var shouldRun = false
    private var isStarting = false

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
        stateLock.unlock()

        startCapture()
    }

    func stop() {
        stateLock.lock()
        shouldRun = false
        stateLock.unlock()

        stopCapture()
    }

    func snapshot() -> AudioLevelSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }

        var effectiveStatus = status
        if status == .capturing {
            if let lastSampleTime, Date().timeIntervalSince(lastSampleTime) > 2.0 {
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

    private func startCapture() {
        guard beginStarting() else { return }
        defer { markStartFinished() }

        setStatus(.starting)

        do {
            try configureCoreAudioTap()
            setStatus(.capturing)
        } catch AudioMonitorError.permissionRequired(_) {
            finishStartFailure(.noPermission)
        } catch AudioMonitorError.audioUnavailable(_) {
            finishStartFailure(.noAudio)
        } catch {
            finishStartFailure(.failed(error.localizedDescription))
        }
    }

    private func finishStartFailure(_ newStatus: AudioCaptureStatus) {
        setStatus(newStatus)
        stopCapture()

        stateLock.lock()
        shouldRun = false
        stateLock.unlock()
    }

    private func stopCapture() {
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

        stateLock.lock()
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        rmsLinear = 0
        peakLinear = 0
        rmsDBFS = -96
        peakDBFS = -96
        aWeightingMeter.reset()
        lastSampleTime = nil
        if !shouldRun {
            status = .idle
        }
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
        guard result == noErr else {
            if Self.isPermissionStatus(result) {
                throw AudioMonitorError.permissionRequired(result)
            }
            if Self.isAudioUnavailableStatus(result) {
                throw AudioMonitorError.audioUnavailable(result)
            }
            throw AudioMonitorError.processTapCreationFailed(result)
        }

        let aggregateUID = "com.volumemonitor.audio-tap.\(UUID().uuidString)"
        let aggregateDescription: NSDictionary = [
            kAudioAggregateDeviceNameKey: "VolumeMonitor Audio Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
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
            if Self.isPermissionStatus(result) {
                throw AudioMonitorError.permissionRequired(result)
            }
            if Self.isAudioUnavailableStatus(result) {
                throw AudioMonitorError.audioUnavailable(result)
            }
            throw AudioMonitorError.aggregateCreationFailed(result)
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
            if Self.isPermissionStatus(result) {
                throw AudioMonitorError.permissionRequired(result)
            }
            if Self.isAudioUnavailableStatus(result) {
                throw AudioMonitorError.audioUnavailable(result)
            }
            throw AudioMonitorError.ioProcCreationFailed(result)
        }

        if let sampleRate = Self.nominalSampleRate(deviceID: newAggregateID) {
            aWeightingMeter = AWeightingMeter(sampleRate: sampleRate)
        }

        result = AudioDeviceStart(newAggregateID, newIOProcID)
        guard result == noErr else {
            AudioDeviceDestroyIOProcID(newAggregateID, newIOProcID)
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            if Self.isPermissionStatus(result) {
                throw AudioMonitorError.permissionRequired(result)
            }
            if Self.isAudioUnavailableStatus(result) {
                throw AudioMonitorError.audioUnavailable(result)
            }
            throw AudioMonitorError.startFailed(result)
        }

        stateLock.lock()
        tapID = newTapID
        aggregateDeviceID = newAggregateID
        ioProcID = newIOProcID
        stateLock.unlock()
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

        let result = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                pidPointer,
                &dataSize,
                &processObjectID
            )
        }

        guard result == noErr, processObjectID != kAudioObjectUnknown else { return nil }
        return processObjectID
    }

    fileprivate func processAudioBufferList(_ audioBufferList: UnsafePointer<AudioBufferList>?) {
        guard let audioBufferList,
              let levels = aWeightingMeter.measure(audioBufferList) else {
            return
        }

        updateLevels(rms: levels.rms, peak: levels.peak)
    }

    private func updateLevels(rms: Float, peak: Float) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let attack: Float = 0.55
        let release: Float = 0.16
        let smoothing = rms > rmsLinear ? attack : release

        rmsLinear = rmsLinear + (rms - rmsLinear) * smoothing
        peakLinear = max(peak, peakLinear * 0.82)
        rmsDBFS = Self.dbFS(fromLinear: rmsLinear)
        peakDBFS = Self.dbFS(fromLinear: peakLinear)
        lastSampleTime = Date()
        status = .capturing
    }

    private func setStatus(_ newStatus: AudioCaptureStatus) {
        stateLock.lock()
        status = newStatus
        stateLock.unlock()
    }

    private func beginStarting() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isStarting, aggregateDeviceID == kAudioObjectUnknown else { return false }
        isStarting = true
        return true
    }

    private func markStartFinished() {
        stateLock.lock()
        isStarting = false
        stateLock.unlock()
    }

    private static func dbFS(fromLinear value: Float) -> Float {
        guard value > 0.000001 else { return -96 }
        return max(-96, min(0, 20 * log10(value)))
    }

    private static func isPermissionStatus(_ status: OSStatus) -> Bool {
        status == kAudioDevicePermissionsError ||
        status == kAudioHardwareIllegalOperationError
    }

    private static func isAudioUnavailableStatus(_ status: OSStatus) -> Bool {
        status == kAudioHardwareNotRunningError ||
        status == kAudioHardwareNotReadyError ||
        status == kAudioHardwareBadDeviceError ||
        status == kAudioHardwareBadObjectError
    }

    private static func nominalSampleRate(deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let result = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard result == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }
}

private final class AWeightingMeter {
    private let coefficients: IIRCoefficients
    private var filters: [IIRFilter] = []

    init(sampleRate: Double) {
        coefficients = IIRCoefficients.aWeighting(sampleRate: sampleRate)
    }

    func reset() {
        filters.removeAll()
    }

    func measure(_ audioBufferList: UnsafePointer<AudioBufferList>) -> (rms: Float, peak: Float)? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )

        var sumSquares: Double = 0
        var peak: Float = 0
        var sampleCount = 0
        var channelOffset = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }

            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }

            let channelCount = max(1, Int(buffer.mNumberChannels))
            let frameCount = count / channelCount
            guard frameCount > 0 else { continue }

            ensureFilterCount(channelOffset + channelCount)
            let samples = data.bindMemory(to: Float.self, capacity: count)

            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let index = frame * channelCount + channel
                    let sample = samples[index]
                    let magnitude = abs(sample)
                    peak = max(peak, magnitude)

                    let weightedSample = filters[channelOffset + channel].process(Double(sample))
                    sumSquares += weightedSample * weightedSample
                }
            }

            sampleCount += frameCount * channelCount
            channelOffset += channelCount
        }

        guard sampleCount > 0 else { return nil }

        let rms = Float(sqrt(sumSquares / Double(sampleCount)))
        return (rms: min(max(rms, 0), 1), peak: min(max(peak, 0), 1))
    }

    private func ensureFilterCount(_ count: Int) {
        while filters.count < count {
            filters.append(IIRFilter(coefficients: coefficients))
        }
    }
}

private struct IIRCoefficients {
    let b: [Double]
    let a: [Double]

    static func aWeighting(sampleRate: Double) -> IIRCoefficients {
        let f1 = 20.598997
        let f2 = 107.65265
        let f3 = 737.86223
        let f4 = 12_194.217
        let a1000 = 1.9997

        let w1 = 2 * Double.pi * f1
        let w2 = 2 * Double.pi * f2
        let w3 = 2 * Double.pi * f3
        let w4 = 2 * Double.pi * f4

        var denominator = polyMultiply([1, 2 * w4, w4 * w4], [1, 2 * w1, w1 * w1])
        denominator = polyMultiply(denominator, [1, w3])
        denominator = polyMultiply(denominator, [1, w2])

        let order = denominator.count - 1
        let gain = w4 * w4 * pow(10, a1000 / 20)
        let numerator = [0, 0, gain, 0, 0, 0, 0]

        let digitalB = bilinearTransform(numerator, sampleRate: sampleRate, order: order)
        let digitalA = bilinearTransform(denominator, sampleRate: sampleRate, order: order)
        let a0 = digitalA[0]

        return IIRCoefficients(
            b: digitalB.map { $0 / a0 },
            a: digitalA.map { $0 / a0 }
        )
    }

    private static func bilinearTransform(_ coefficients: [Double], sampleRate: Double, order: Int) -> [Double] {
        let c = 2 * sampleRate
        var result = Array(repeating: 0.0, count: order + 1)

        for (index, coefficient) in coefficients.enumerated() where coefficient != 0 {
            let power = order - index
            let left = polyPower([1, -1], power)
            let right = polyPower([1, 1], order - power)
            let term = polyMultiply(left, right).map { $0 * coefficient * pow(c, Double(power)) }

            for termIndex in term.indices {
                result[termIndex] += term[termIndex]
            }
        }

        return result
    }

    private static func polyPower(_ polynomial: [Double], _ power: Int) -> [Double] {
        guard power > 0 else { return [1] }
        var result = [1.0]
        for _ in 0..<power {
            result = polyMultiply(result, polynomial)
        }
        return result
    }

    private static func polyMultiply(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: lhs.count + rhs.count - 1)
        for (leftIndex, leftValue) in lhs.enumerated() {
            for (rightIndex, rightValue) in rhs.enumerated() {
                result[leftIndex + rightIndex] += leftValue * rightValue
            }
        }
        return result
    }
}

private struct IIRFilter {
    private let coefficients: IIRCoefficients
    private var state: [Double]

    init(coefficients: IIRCoefficients) {
        self.coefficients = coefficients
        state = Array(repeating: 0, count: max(0, coefficients.b.count - 1))
    }

    mutating func process(_ input: Double) -> Double {
        guard !state.isEmpty else { return coefficients.b[0] * input }

        let output = coefficients.b[0] * input + state[0]
        for index in 1..<state.count {
            state[index - 1] = coefficients.b[index] * input + state[index] - coefficients.a[index] * output
        }
        state[state.count - 1] = coefficients.b[state.count] * input - coefficients.a[state.count] * output
        return output
    }
}

private let systemAudioTapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let monitor = Unmanaged<SystemAudioLevelMonitor>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    monitor.processAudioBufferList(inputData)
    return noErr
}
