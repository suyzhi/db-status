import CoreAudio
import Foundation

final class OutputDeviceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.volumemonitor.output-device")
    private var currentDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var currentSnapshot = OutputDeviceSnapshot.unavailable
    private var isStarted = false

    private lazy var defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshDefaultDeviceAndListeners()
    }

    private lazy var devicePropertyListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshSnapshot()
    }

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            defaultDeviceListener
        )
        listenerQueue.async { [weak self] in self?.refreshDefaultDeviceAndListeners() }
    }

    func stop() {
        lock.lock()
        let wasStarted = isStarted
        isStarted = false
        lock.unlock()
        guard wasStarted else { return }

        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            defaultDeviceListener
        )

        listenerQueue.sync { [weak self] in
            guard let self else { return }
            removeDeviceListeners(from: currentDeviceID)
            currentDeviceID = AudioObjectID(kAudioObjectUnknown)
            setSnapshot(.unavailable)
        }
    }

    func snapshot() -> OutputDeviceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }

    func refresh() {
        listenerQueue.async { [weak self] in self?.refreshSnapshot() }
    }

    func setVolumeScalar(_ value: Float) -> Bool {
        listenerQueue.sync {
            guard currentDeviceID != kAudioObjectUnknown else { return false }
            let clamped = min(max(value, 0), 1)
            let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
            var changed = false
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(currentDeviceID, &address) else { continue }
                var settable = DarwinBoolean(false)
                guard AudioObjectIsPropertySettable(currentDeviceID, &address, &settable) == noErr,
                      settable.boolValue else { continue }
                var newValue = Float32(clamped)
                if AudioObjectSetPropertyData(
                    currentDeviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &newValue
                ) == noErr {
                    changed = true
                    if element == kAudioObjectPropertyElementMain { break }
                }
            }
            if changed { refreshSnapshot() }
            return changed
        }
    }

    private func refreshDefaultDeviceAndListeners() {
        let newDeviceID = Self.readDefaultOutputDevice()
        if newDeviceID != currentDeviceID {
            removeDeviceListeners(from: currentDeviceID)
            currentDeviceID = newDeviceID
            installDeviceListeners(on: newDeviceID)
        }
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        guard currentDeviceID != kAudioObjectUnknown else {
            setSnapshot(.unavailable)
            return
        }

        let snapshot = OutputDeviceSnapshot(
            id: currentDeviceID,
            uid: Self.readString(
                deviceID: currentDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            ),
            name: Self.readString(
                deviceID: currentDeviceID,
                selector: kAudioObjectPropertyName
            ),
            volumeScalar: Self.readOutputVolume(deviceID: currentDeviceID),
            isMuted: Self.readMute(deviceID: currentDeviceID)
        )
        setSnapshot(snapshot)
    }

    private func setSnapshot(_ snapshot: OutputDeviceSnapshot) {
        lock.lock()
        currentSnapshot = snapshot
        lock.unlock()
    }

    private func installDeviceListeners(on deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        for var address in Self.observedDeviceAddresses {
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                listenerQueue,
                devicePropertyListener
            )
        }
    }

    private func removeDeviceListeners(from deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        for var address in Self.observedDeviceAddresses {
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &address,
                listenerQueue,
                devicePropertyListener
            )
        }
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static let observedDeviceAddresses: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 2
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    private static func readDefaultOutputDevice() -> AudioObjectID {
        var address = defaultOutputAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return result == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }

    private static func readOutputVolume(deviceID: AudioObjectID) -> Float? {
        if let main = readFloat(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return min(max(main, 0), 1)
        }

        let channels = [1, 2].compactMap {
            readFloat(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: AudioObjectPropertyElement($0)
            )
        }
        guard !channels.isEmpty else { return nil }
        return min(max(channels.reduce(0, +) / Float(channels.count), 0), 1)
    }

    private static func readMute(deviceID: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    private static func readFloat(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
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
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return result == noErr ? value as String : nil
    }
}
