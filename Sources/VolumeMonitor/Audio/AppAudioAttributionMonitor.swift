import Accelerate
import AppKit
import CoreAudio
import Darwin
import Foundation

/// 按 App 统计声暴露。
///
/// 给每个正在出声的进程各开一个轻量 tap，只用来算各 App 占当前能量的**比例**；
/// 声暴露总量仍以全局 tap 为准，再按比例分摊，所以各 App 加起来恒等于总量。
/// 份额按未加权能量计算（只做比例，省去每个进程一套 A 加权滤波）。
///
/// 浏览器等多进程 App 的辅助进程会归并到主 App；网页内容只能统计到浏览器这一层。
final class AppAudioAttributionMonitor: @unchecked Sendable {
    static let maxSlots = 16
    private static let pollInterval: DispatchTimeInterval = .seconds(2)

    private let captureQueue = DispatchQueue(label: "com.volumemonitor.app-attribution")
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // 实时线程使用的固定容量缓冲：IOProc 内不分配内存。
    private let pending: UnsafeMutablePointer<Double>
    private let shared: UnsafeMutablePointer<Double>
    /// 当前配置的进程数。仅在 IOProc 停止时由 captureQueue 修改。
    private var activeSlotCount = 0

    // 受 lock 保护：当前配置下每个槽位对应的 App，以及重配置时结转的能量。
    private var slotKeys: [String] = []
    private var carryOver: [String: Double] = [:]

    // captureQueue 独占。
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var currentProcessIDs: [AudioObjectID] = []
    private var pollTimer: DispatchSourceTimer?

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: Self.maxSlots)
        pending.initialize(repeating: 0, count: Self.maxSlots)
        shared = .allocate(capacity: Self.maxSlots)
        shared.initialize(repeating: 0, count: Self.maxSlots)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        pending.deallocate()
        shared.deallocate()
    }

    func start() {
        captureQueue.async { [weak self] in
            guard let self, pollTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: captureQueue)
            timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.refreshProcessesOnQueue() }
            pollTimer = timer
            timer.resume()
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            pollTimer?.cancel()
            pollTimer = nil
            teardownOnQueue()
            currentProcessIDs = []
        }
    }

    /// 主线程：取走自上次以来各 App 的能量（相对值），键为归并后的 App 标识。
    func drain() -> [String: Double] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        var result = carryOver
        carryOver.removeAll(keepingCapacity: true)
        for (slot, key) in slotKeys.enumerated() where shared[slot] > 0 {
            result[key, default: 0] += shared[slot]
            shared[slot] = 0
        }
        return result
    }

    // MARK: - 进程发现与 tap 重建（captureQueue）

    private func refreshProcessesOnQueue() {
        guard #available(macOS 14.2, *) else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = Self.outputtingProcesses()
            .filter { $0.pid != ownPID }
            .prefix(Self.maxSlots)
        let ids = processes.map(\.objectID)
        guard ids != currentProcessIDs else { return }

        teardownOnQueue()
        currentProcessIDs = ids
        guard !processes.isEmpty else { return }
        do {
            try buildOnQueue(processes: Array(processes))
        } catch {
            AppDiagnostics.log("attribution: build failed \(error)")
            teardownOnQueue()
        }
    }

    @available(macOS 14.2, *)
    private func buildOnQueue(processes: [AudioProcessInfo]) throws {
        var createdTaps: [AudioObjectID] = []
        var tapUIDs: [String] = []
        for process in processes {
            let description = CATapDescription(stereoMixdownOfProcesses: [process.objectID])
            description.name = "VolumeMonitor App \(process.pid)"
            description.isPrivate = true
            description.muteBehavior = CATapMuteBehavior.unmuted
            var tapID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr else {
                createdTaps.forEach { AudioHardwareDestroyProcessTap($0) }
                throw AudioMonitorError.processTapCreationFailed(status)
            }
            createdTaps.append(tapID)
            tapUIDs.append(description.uuid.uuidString)
        }
        tapIDs = createdTaps

        let aggregateDescription: NSDictionary = [
            kAudioAggregateDeviceNameKey: "VolumeMonitor App Attribution",
            kAudioAggregateDeviceUIDKey: "com.volumemonitor.app-attribution.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapUIDs.map { [kAudioSubTapUIDKey: $0] }
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(aggregateDescription, &newAggregate)
        guard status == noErr else { throw AudioMonitorError.aggregateCreationFailed(status) }
        aggregateID = newAggregate

        activeSlotCount = processes.count
        os_unfair_lock_lock(lock)
        slotKeys = processes.map(\.appKey)
        os_unfair_lock_unlock(lock)

        var newIOProc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(
            newAggregate,
            appAttributionIOProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &newIOProc
        )
        guard status == noErr, let newIOProc else { throw AudioMonitorError.ioProcCreationFailed(status) }
        ioProcID = newIOProc
        status = AudioDeviceStart(newAggregate, newIOProc)
        guard status == noErr else { throw AudioMonitorError.startFailed(status) }
        AppDiagnostics.log("attribution: tracking \(processes.map(\.appKey))")
    }

    private func teardownOnQueue() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if #available(macOS 14.2, *) {
            tapIDs.forEach { AudioHardwareDestroyProcessTap($0) }
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapIDs = []

        // IOProc 已停：把未合并与已合并的能量按旧配置结转，避免重建时丢份额。
        os_unfair_lock_lock(lock)
        for (slot, key) in slotKeys.enumerated() {
            let energy = shared[slot] + pending[slot]
            if energy > 0 { carryOver[key, default: 0] += energy }
            shared[slot] = 0
            pending[slot] = 0
        }
        slotKeys = []
        os_unfair_lock_unlock(lock)
        activeSlotCount = 0
    }

    // MARK: - 实时线程

    fileprivate func process(_ audioBufferList: UnsafePointer<AudioBufferList>?) {
        guard let audioBufferList else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let slots = activeSlotCount
        guard slots > 0 else { return }
        // 每个 tap 是一路立体声输入：缓冲区数与进程数相同时一一对应（交错），
        // 否则按声道位置每 2 声道一个进程（非交错）。
        let oneBufferPerTap = buffers.count == slots
        var any = false
        var channelOffset = 0
        for (index, buffer) in buffers.enumerated() {
            let slot = oneBufferPerTap ? index : channelOffset / 2
            channelOffset += max(1, Int(buffer.mNumberChannels))
            guard slot < slots, let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var sumSquares: Float = 0
            vDSP_svesq(data.assumingMemoryBound(to: Float.self), 1, &sumSquares, vDSP_Length(count))
            if sumSquares > 0 {
                pending[slot] += Double(sumSquares)
                any = true
            }
        }
        guard any, os_unfair_lock_trylock(lock) else { return }
        for slot in 0..<Self.maxSlots where pending[slot] > 0 {
            shared[slot] += pending[slot]
            pending[slot] = 0
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: - CoreAudio 查询

    struct AudioProcessInfo {
        let objectID: AudioObjectID
        let pid: pid_t
        let appKey: String
    }

    @available(macOS 14.2, *)
    static func outputtingProcesses() -> [AudioProcessInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects.compactMap { object in
            guard readUInt32(object, kAudioProcessPropertyIsRunningOutput) == 1 else { return nil }
            let pid = pid_t(bitPattern: readUInt32(object, kAudioProcessPropertyPID) ?? 0)
            let bundleID = readString(object, kAudioProcessPropertyBundleID) ?? ""
            return AudioProcessInfo(
                objectID: object,
                pid: pid,
                appKey: appKey(bundleID: bundleID, pid: pid)
            )
        }
    }

    /// 把辅助进程归并到主 App：Chrome/Edge/Electron 的 "*.helper*"、Firefox 的
    /// plugin-container、WebKit 的网页内容进程。
    static func appKey(bundleID: String, pid: pid_t) -> String {
        if bundleID.isEmpty {
            var name = [CChar](repeating: 0, count: 256)
            let length = proc_name(pid, &name, UInt32(name.count))
            return length > 0 ? "process:\(String(cString: name))" : "process:\(pid)"
        }
        if bundleID.hasPrefix("com.apple.WebKit.") { return AppNames.webKitKey }
        if bundleID == "org.mozilla.plugincontainer" { return "org.mozilla.firefox" }
        if let range = bundleID.range(of: ".helper", options: .caseInsensitive) {
            return String(bundleID[..<range.lowerBound])
        }
        return bundleID
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

private let appAttributionIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<AppAudioAttributionMonitor>
        .fromOpaque(clientData)
        .takeUnretainedValue()
        .process(inputData)
    return noErr
}

/// App 标识 → 显示名称。
@MainActor
enum AppNames {
    nonisolated static let webKitKey = "com.apple.WebKit"
    private static var cache: [String: String] = [:]

    static func displayName(for key: String) -> String {
        if let cached = cache[key] { return cached }
        let name: String
        if key == webKitKey {
            name = "Safari / 网页内容"
        } else if key.hasPrefix("process:") {
            name = String(key.dropFirst("process:".count))
        } else if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == key }),
            let localized = running.localizedName {
            name = localized
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        } else {
            name = key
        }
        cache[key] = name
        return name
    }
}
