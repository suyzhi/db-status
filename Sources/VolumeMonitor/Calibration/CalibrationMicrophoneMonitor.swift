import AVFoundation
import CoreAudio
import Foundation

struct CalibrationInputDevice: Sendable, Equatable, Identifiable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    var isExternal: Bool {
        transportType != kAudioDeviceTransportTypeBuiltIn
    }
}

enum CalibrationMicrophoneStatus: Sendable, Equatable {
    case idle
    case requestingPermission
    case running
    case noPermission
    case deviceChanged
    case failed(String)
}

struct CalibrationMicrophoneSnapshot: Sendable, Equatable {
    let status: CalibrationMicrophoneStatus
    let device: CalibrationInputDevice?
    let rmsDBFS: Double
    let peakDBFS: Double
    let clipping: Bool
    let noiseFloorDBFS: Double
    let stabilityDB: Double
    let inputChangeDB: Double
    let tapDetected: Bool

    var inputIsUsable: Bool {
        status == .running && rmsDBFS > -85 && !clipping
    }
}

struct CalibrationFrequencyMeasurement: Sendable, Equatable {
    let frequencyHz: Double
    let levelDBFS: Double
    let stabilityDB: Double
    let peakDBFS: Double
    let noiseFloorDBFS: Double
    let snrDB: Double
    let sampleCount: Int

    var isClipping: Bool { peakDBFS > -3 }
}

struct CalibrationFrequencyWindowAnalysis: Sendable, Equatable {
    let levelDBFS: Double
    let stabilityDB: Double
    let peakDBFS: Double
    let sampleCount: Int
    let windowLevelsDBFS: [Double]
}

enum CalibrationFrequencyAnalyzer {
    static let windowDurationSeconds = 1.0
    static let windowCount = 3

    static func analyze(
        samplesByChannel: [[Float]],
        sampleRate: Double,
        frequencyHz: Double,
        windowDuration: Double = windowDurationSeconds,
        windows: Int = windowCount
    ) -> CalibrationFrequencyWindowAnalysis? {
        guard sampleRate > 0, frequencyHz > 0, frequencyHz < sampleRate / 2,
              windowDuration >= 0.5, windows >= 2 else { return nil }
        let framesPerWindow = Int((sampleRate * windowDuration).rounded())
        let requiredFrames = framesPerWindow * windows
        guard framesPerWindow > 1 else { return nil }

        var strongest: CalibrationFrequencyWindowAnalysis?
        for channelSamples in samplesByChannel where channelSamples.count >= requiredFrames {
            let start = channelSamples.count - requiredFrames
            var levels: [Double] = []
            var peak = 0.0
            levels.reserveCapacity(windows)
            for windowIndex in 0..<windows {
                let lower = start + windowIndex * framesPerWindow
                let upper = lower + framesPerWindow
                let window = channelSamples[lower..<upper]
                levels.append(dbFS(goertzelRMS(
                    samples: window,
                    sampleRate: sampleRate,
                    frequencyHz: frequencyHz
                )))
                for sample in window { peak = max(peak, abs(Double(sample))) }
            }
            let result = CalibrationFrequencyWindowAnalysis(
                levelDBFS: energyMeanDB(levels),
                stabilityDB: standardDeviation(levels),
                peakDBFS: dbFS(peak),
                sampleCount: requiredFrames,
                windowLevelsDBFS: levels
            )
            if strongest == nil || result.levelDBFS > strongest!.levelDBFS {
                strongest = result
            }
        }
        return strongest
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count - 1)
        return sqrt(max(0, variance))
    }

    private static func energyMeanDB(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -96 }
        let meanPower = values.reduce(0) { $0 + pow(10, $1 / 10) } / Double(values.count)
        return 10 * log10(max(meanPower, 1e-12))
    }

    private static func dbFS(_ linear: Double) -> Double {
        guard linear > 0.000_015_848_9 else { return -96 }
        return min(0, max(-96, 20 * log10(linear)))
    }

    private static func goertzelRMS(
        samples: ArraySlice<Float>,
        sampleRate: Double,
        frequencyHz: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0
        var s2 = 0.0
        var windowSum = 0.0
        let denominator = Double(max(1, samples.count - 1))
        for (offset, sample) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(offset) / denominator)
            let current = Double(sample) * window + coefficient * s1 - s2
            s2 = s1
            s1 = current
            windowSum += window
        }
        let real = s1 - s2 * cos(omega)
        let imaginary = s2 * sin(omega)
        let peakAmplitude = windowSum > 0 ? 2 * hypot(real, imaginary) / windowSum : 0
        return peakAmplitude / sqrt(2)
    }
}

private final class MicrophoneCaptureState: @unchecked Sendable {
    let lock = NSLock()
    var status: CalibrationMicrophoneStatus = .idle
    var recentBroadbandLevels: [Double] = []
    var recentPeaks: [Double] = []
    var targetFrequencyHz: Double?
    var targetSamplesByChannel: [[Float]] = []
    var targetSampleRate = 0.0
    var tapWasDetected = false
}

@MainActor
final class CalibrationMicrophoneMonitor: ObservableObject {
    @Published private(set) var devices: [CalibrationInputDevice] = []
    @Published private(set) var snapshot = CalibrationMicrophoneSnapshot(
        status: .idle,
        device: nil,
        rmsDBFS: -96,
        peakDBFS: -96,
        clipping: false,
        noiseFloorDBFS: -96,
        stabilityDB: 0,
        inputChangeDB: 0,
        tapDetected: false
    )

    private let engine = AVAudioEngine()
    private nonisolated let captureState = MicrophoneCaptureState()
    private var selectedDevice: CalibrationInputDevice?
    private var updateTimer: Timer?
    private var tapInstalled = false
    private(set) var inputChainFingerprint: CalibrationInputChainFingerprint?

    func refreshDevices() {
        devices = Self.availableInputDevices()
        if let selectedDevice,
           let refreshed = devices.first(where: { $0.uid == selectedDevice.uid }) {
            self.selectedDevice = refreshed
        }
    }

    func preferredDevice() -> CalibrationInputDevice? {
        devices.first(where: \.isExternal) ?? devices.first
    }

    func start(device: CalibrationInputDevice) async {
        stop()
        selectedDevice = device
        setStatus(.requestingPermission)
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }
        guard granted else {
            setStatus(.noPermission)
            publishSnapshot()
            return
        }

        do {
            try configureEngine(device: device)
            setStatus(.running)
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishSnapshot() }
            }
            updateTimer?.tolerance = 0.025
            publishSnapshot()
        } catch {
            stopEngineOnly()
            setStatus(.failed(error.localizedDescription))
            publishSnapshot()
        }
    }

    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        stopEngineOnly()
        captureState.lock.lock()
        captureState.recentBroadbandLevels.removeAll(keepingCapacity: false)
        captureState.recentPeaks.removeAll(keepingCapacity: false)
        captureState.targetSamplesByChannel.removeAll(keepingCapacity: false)
        captureState.targetSampleRate = 0
        captureState.targetFrequencyHz = nil
        captureState.tapWasDetected = false
        captureState.status = .idle
        captureState.lock.unlock()
        inputChainFingerprint = nil
        publishSnapshot()
    }

    func beginFrequencyMeasurement(_ frequencyHz: Double) {
        captureState.lock.lock()
        captureState.targetFrequencyHz = frequencyHz
        captureState.targetSamplesByChannel.removeAll(keepingCapacity: true)
        captureState.targetSampleRate = 0
        captureState.lock.unlock()
    }

    func finishFrequencyMeasurement(
        noiseFloorDBFS: Double? = nil
    ) -> CalibrationFrequencyMeasurement? {
        captureState.lock.lock()
        let frequency = captureState.targetFrequencyHz
        let samplesByChannel = captureState.targetSamplesByChannel
        let sampleRate = captureState.targetSampleRate
        captureState.targetFrequencyHz = nil
        captureState.targetSamplesByChannel.removeAll(keepingCapacity: true)
        captureState.targetSampleRate = 0
        captureState.lock.unlock()

        guard let frequency,
              let analysis = CalibrationFrequencyAnalyzer.analyze(
                  samplesByChannel: samplesByChannel,
                  sampleRate: sampleRate,
                  frequencyHz: frequency
              ) else { return nil }
        let noise = noiseFloorDBFS ?? snapshot.noiseFloorDBFS
        return CalibrationFrequencyMeasurement(
            frequencyHz: frequency,
            levelDBFS: analysis.levelDBFS,
            stabilityDB: analysis.stabilityDB,
            peakDBFS: analysis.peakDBFS,
            noiseFloorDBFS: noise,
            snrDB: analysis.levelDBFS - noise,
            sampleCount: analysis.sampleCount
        )
    }

    func matchesCurrentInputChain() -> Bool {
        guard let expected = inputChainFingerprint,
              let current = currentInputChainFingerprint() else { return false }
        return expected.matchesCurrentInputChain(current)
    }

    func verifySelectedDeviceIsPresent() -> Bool {
        refreshDevices()
        guard let selectedDevice else { return false }
        let present = devices.contains { $0.uid == selectedDevice.uid }
        if !present {
            setStatus(.deviceChanged)
            publishSnapshot()
        }
        return present
    }

    private func configureEngine(device: CalibrationInputDevice) throws {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            throw NSError(
                domain: "VolumeMonitor.CalibrationMicrophone",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建麦克风音频单元"]
            )
        }
        var deviceID = device.id
        let setResult = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard setResult == noErr else {
            throw NSError(
                domain: "VolumeMonitor.CalibrationMicrophone",
                code: Int(setResult),
                userInfo: [NSLocalizedDescriptionKey: "无法选择输入设备（\(setResult)）"]
            )
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        inputChainFingerprint = makeInputChainFingerprint(device: device, format: inputNode.outputFormat(forBus: 0))
    }

    nonisolated private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return }

        var strongestRMS = 0.0
        var strongestPeak = 0.0
        var frequency: Double?
        captureState.lock.lock()
        frequency = captureState.targetFrequencyHz
        captureState.lock.unlock()

        for channel in 0..<channelCount {
            let samples = UnsafeBufferPointer(start: channels[channel], count: frameCount)
            var sumSquares = 0.0
            var peak = 0.0
            for sample in samples {
                let value = Double(sample)
                sumSquares += value * value
                peak = max(peak, abs(value))
            }
            strongestRMS = max(strongestRMS, sqrt(sumSquares / Double(frameCount)))
            strongestPeak = max(strongestPeak, peak)
        }

        let rmsDB = Self.dbFS(strongestRMS)
        let peakDB = Self.dbFS(strongestPeak)
        captureState.lock.lock()
        captureState.recentBroadbandLevels.append(rmsDB)
        captureState.recentPeaks.append(peakDB)
        if captureState.recentBroadbandLevels.count > 30 {
            captureState.recentBroadbandLevels.removeFirst()
        }
        if captureState.recentPeaks.count > 30 { captureState.recentPeaks.removeFirst() }
        if frequency != nil {
            if captureState.targetSamplesByChannel.isEmpty {
                captureState.targetSamplesByChannel = Array(repeating: [], count: channelCount)
                captureState.targetSampleRate = buffer.format.sampleRate
            }
            if captureState.targetSamplesByChannel.count == channelCount,
               abs(captureState.targetSampleRate - buffer.format.sampleRate) < 0.5 {
                let maximumFrames = Int(buffer.format.sampleRate * 5)
                for channel in 0..<channelCount {
                    captureState.targetSamplesByChannel[channel].append(
                        contentsOf: UnsafeBufferPointer(start: channels[channel], count: frameCount)
                    )
                    if captureState.targetSamplesByChannel[channel].count > maximumFrames {
                        captureState.targetSamplesByChannel[channel].removeFirst(
                            captureState.targetSamplesByChannel[channel].count - maximumFrames
                        )
                    }
                }
            }
        }
        if let minimum = captureState.recentBroadbandLevels.min(),
           let maximum = captureState.recentBroadbandLevels.max(),
           maximum - minimum >= 6 {
            captureState.tapWasDetected = true
        }
        captureState.lock.unlock()
    }

    private func publishSnapshot() {
        captureState.lock.lock()
        let levels = captureState.recentBroadbandLevels
        let peaks = captureState.recentPeaks
        let currentStatus = captureState.status
        let tapDetected = captureState.tapWasDetected
        captureState.lock.unlock()

        let rms = levels.last ?? -96
        let peak = peaks.last ?? -96
        let sorted = levels.sorted()
        let noiseIndex = sorted.isEmpty ? 0 : min(sorted.count - 1, sorted.count / 10)
        let noiseFloor = sorted.isEmpty ? -96 : sorted[noiseIndex]
        let change = ((levels.max() ?? -96) - (levels.min() ?? -96))
        snapshot = CalibrationMicrophoneSnapshot(
            status: currentStatus,
            device: selectedDevice,
            rmsDBFS: rms,
            peakDBFS: peak,
            clipping: peak > -3,
            noiseFloorDBFS: noiseFloor,
            stabilityDB: Self.standardDeviation(Array(levels.suffix(10))),
            inputChangeDB: change,
            tapDetected: tapDetected
        )
    }

    private func setStatus(_ newStatus: CalibrationMicrophoneStatus) {
        captureState.lock.lock()
        captureState.status = newStatus
        captureState.lock.unlock()
    }

    private func stopEngineOnly() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
    }

    nonisolated private static func dbFS(_ linear: Double) -> Double {
        guard linear > 0.000_015_848_9 else { return -96 }
        return min(0, max(-96, 20 * log10(linear)))
    }

    nonisolated private static func standardDeviation(_ values: [Double]) -> Double {
        CalibrationFrequencyAnalyzer.standardDeviation(values)
    }

    private func currentInputChainFingerprint() -> CalibrationInputChainFingerprint? {
        guard let selectedDevice else { return nil }
        return makeInputChainFingerprint(
            device: selectedDevice,
            format: engine.inputNode.outputFormat(forBus: 0)
        )
    }

    private func makeInputChainFingerprint(
        device: CalibrationInputDevice,
        format: AVAudioFormat
    ) -> CalibrationInputChainFingerprint {
        let stream = format.streamDescription.pointee
        let description = [
            stream.mFormatID,
            stream.mFormatFlags,
            stream.mBytesPerPacket,
            stream.mFramesPerPacket,
            stream.mBytesPerFrame,
            stream.mBitsPerChannel,
            format.isInterleaved ? 1 : 0
        ].map(String.init).joined(separator: ":")
        return CalibrationInputChainFingerprint(
            deviceUID: device.uid,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            formatDescription: description,
            inputGainScalar: Self.readInputGain(deviceID: device.id)
        )
    }

    private static func availableInputDevices() -> [CalibrationInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard inputChannelCount(deviceID: deviceID) > 0,
                  let uid = readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = readString(deviceID: deviceID, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return CalibrationInputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                transportType: readUInt32(
                    deviceID: deviceID,
                    selector: kAudioDevicePropertyTransportType
                ) ?? 0
            )
        }.sorted {
            if $0.isExternal != $1.isExternal { return $0.isExternal && !$1.isExternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func inputChannelCount(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func readInputGain(deviceID: AudioObjectID) -> Float? {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        let values = elements.compactMap { element -> Float? in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { return nil }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr, value.isFinite else { return nil }
            return min(max(value, 0), 1)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    private static func readString(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard result == noErr else {
            return nil
        }
        return value as String
    }

    private static func readUInt32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
