import Foundation
import UserNotifications

private struct PersistedState: Codable {
    var schemaVersion = 1
    var profiles: [TransducerProfile] = []
    var exposureBuckets: [ExposureBucket] = []
}

@MainActor
final class LocalDataStore {
    static let shared = LocalDataStore()

    private(set) var profiles: [TransducerProfile]
    private(set) var exposureBuckets: [ExposureBucket]
    private let fileURL: URL?

    init(fileURL: URL? = LocalDataStore.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            profiles = state.profiles
            exposureBuckets = state.exposureBuckets
        } else {
            profiles = []
            exposureBuckets = []
        }
    }

    func upsert(profile: TransducerProfile) throws {
        profiles.removeAll { $0.id == profile.id || $0.deviceUID == profile.deviceUID }
        profiles.append(profile)
        try persist()
    }

    func removeProfile(deviceUID: String) throws {
        profiles.removeAll { $0.deviceUID == deviceUID }
        try persist()
    }

    func merge(bucket: ExposureBucket) throws {
        if let index = exposureBuckets.firstIndex(where: { $0.minute == bucket.minute }) {
            exposureBuckets[index].normalizedEnergyAt80Seconds += bucket.normalizedEnergyAt80Seconds
            exposureBuckets[index].measuredDuration += bucket.measuredDuration
            exposureBuckets[index].peakDBA = max(exposureBuckets[index].peakDBA, bucket.peakDBA)
            exposureBuckets[index].deviceUID = bucket.deviceUID
        } else {
            exposureBuckets.append(bucket)
        }
        try persist()
    }

    func pruneBuckets(before cutoff: Date) throws {
        exposureBuckets.removeAll { $0.minute < cutoff }
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let state = PersistedState(profiles: profiles, exposureBuckets: exposureBuckets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private static func defaultFileURL() -> URL? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return directory
            .appendingPathComponent("VolumeMonitor", isDirectory: true)
            .appendingPathComponent("monitoring-data-v1.json")
    }
}

@MainActor
final class ProfileRepository {
    private let store: LocalDataStore

    init(store: LocalDataStore = .shared) {
        self.store = store
    }

    func profile(for deviceUID: String?) -> TransducerProfile? {
        guard let deviceUID else { return nil }
        return store.profiles.first { $0.deviceUID == deviceUID }
    }

    func save(_ profile: TransducerProfile) throws {
        try store.upsert(profile: profile)
    }

    func removeProfile(for deviceUID: String) throws {
        try store.removeProfile(deviceUID: deviceUID)
    }
}

@MainActor
final class AppPreferences {
    static let shared = AppPreferences()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var monitoringEnabled: Bool {
        get { defaults.bool(forKey: "monitoringEnabled") }
        set { defaults.set(newValue, forKey: "monitoringEnabled") }
    }

    var exposureMode: ExposureMode {
        get {
            ExposureMode(rawValue: defaults.string(forKey: "exposureMode") ?? "") ?? .adult
        }
        set { defaults.set(newValue.rawValue, forKey: "exposureMode") }
    }

    var statusBarDisplayMode: StatusBarDisplayMode {
        get {
            StatusBarDisplayMode(rawValue: defaults.string(forKey: "statusBarDisplayMode") ?? "")
                ?? .estimatedDBA
        }
        set { defaults.set(newValue.rawValue, forKey: "statusBarDisplayMode") }
    }

    var lastExposureNotificationThreshold: Double {
        get { defaults.double(forKey: "lastExposureNotificationThreshold") }
        set { defaults.set(newValue, forKey: "lastExposureNotificationThreshold") }
    }

    var lastExposureNotificationDate: Date? {
        get { defaults.object(forKey: "lastExposureNotificationDate") as? Date }
        set { defaults.set(newValue, forKey: "lastExposureNotificationDate") }
    }
}

struct ExposureSummary: Sendable, Equatable {
    let doseFraction: Double
    let sessionLAeq: Double?
    let sessionPeakDBA: Double?
    let remainingTimeAtCurrentLevel: Double?
}

@MainActor
final class ExposureService {
    private let store: LocalDataStore
    private let preferences: AppPreferences
    private var currentMinute: Date?
    private var pendingBucket: ExposureBucket?
    private var lastIngestDate: Date?
    private var sessionEnergy = 0.0
    private var sessionDuration = 0.0
    private var sessionPeak: Double?
    private var cachedSevenDayEnergy = 0.0
    private var lastNotifiedThreshold = 0.0

    init(
        store: LocalDataStore = .shared,
        preferences: AppPreferences = .shared
    ) {
        self.store = store
        self.preferences = preferences
        lastNotifiedThreshold = preferences.lastExposureNotificationThreshold
        reloadSevenDayEnergy()
        pruneOldBuckets()
    }

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func ingest(levelDBA: Double?, deviceUID: String?, at date: Date = .now) -> ExposureSummary {
        defer { lastIngestDate = date }
        guard let levelDBA,
              levelDBA.isFinite,
              let deviceUID,
              let lastIngestDate else {
            return summary(currentLevel: levelDBA)
        }

        let duration = min(max(date.timeIntervalSince(lastIngestDate), 0), 2)
        guard duration > 0 else { return summary(currentLevel: levelDBA) }

        let minute = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
        if currentMinute != minute {
            flushPendingBucket()
            currentMinute = minute
            pendingBucket = ExposureBucket(
                minute: minute,
                normalizedEnergyAt80Seconds: 0,
                measuredDuration: 0,
                peakDBA: levelDBA,
                deviceUID: deviceUID
            )
        }

        let energy = ExposureMath.normalizedEnergyAt80(levelDBA: levelDBA, duration: duration)
        if var bucket = pendingBucket {
            bucket.normalizedEnergyAt80Seconds += energy
            bucket.measuredDuration += duration
            bucket.peakDBA = max(bucket.peakDBA, levelDBA)
            bucket.deviceUID = deviceUID
            pendingBucket = bucket
        }
        sessionEnergy += energy
        sessionDuration += duration
        sessionPeak = max(sessionPeak ?? levelDBA, levelDBA)

        let result = summary(currentLevel: levelDBA, includePending: true)
        notifyIfNeeded(doseFraction: result.doseFraction)
        return result
    }

    func currentSummary(levelDBA: Double?) -> ExposureSummary {
        summary(currentLevel: levelDBA, includePending: true)
    }

    func resetSession() {
        sessionEnergy = 0
        sessionDuration = 0
        sessionPeak = nil
    }

    func flush() {
        flushPendingBucket()
    }

    private func summary(currentLevel: Double?, includePending: Bool = true) -> ExposureSummary {
        let pendingEnergy = includePending ? pendingBucket?.normalizedEnergyAt80Seconds ?? 0 : 0
        let dose = ExposureMath.doseFraction(
            normalizedEnergyAt80: cachedSevenDayEnergy + pendingEnergy,
            mode: preferences.exposureMode
        )
        return ExposureSummary(
            doseFraction: dose,
            sessionLAeq: ExposureMath.equivalentLevelDBA(
                normalizedEnergyAt80: sessionEnergy,
                duration: sessionDuration
            ),
            sessionPeakDBA: sessionPeak,
            remainingTimeAtCurrentLevel: currentLevel.flatMap {
                ExposureMath.remainingTime(
                    levelDBA: $0,
                    currentDose: dose,
                    mode: preferences.exposureMode
                )
            }
        )
    }

    private func flushPendingBucket() {
        guard let bucket = pendingBucket, bucket.measuredDuration > 0 else {
            pendingBucket = nil
            return
        }
        do {
            try store.merge(bucket: bucket)
            reloadSevenDayEnergy()
        } catch {
            NSLog("VolumeMonitor exposure persistence failed: %@", error.localizedDescription)
        }
        pendingBucket = nil
    }

    private func reloadSevenDayEnergy(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        cachedSevenDayEnergy = store.exposureBuckets
            .filter { $0.minute >= cutoff }
            .reduce(0) { $0 + $1.normalizedEnergyAt80Seconds }
    }

    private func pruneOldBuckets(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-8 * 7 * 24 * 60 * 60)
        do {
            try store.pruneBuckets(before: cutoff)
        } catch {
            NSLog("VolumeMonitor exposure pruning failed: %@", error.localizedDescription)
        }
    }

    private func notifyIfNeeded(doseFraction: Double) {
        if doseFraction < 0.7 {
            lastNotifiedThreshold = 0
            preferences.lastExposureNotificationThreshold = 0
        }
        let threshold = doseFraction >= 1 ? 1.0 : doseFraction >= 0.8 ? 0.8 : 0
        let notifiedRecently = preferences.lastExposureNotificationDate.map {
            Date().timeIntervalSince($0) < 24 * 60 * 60
        } ?? false
        guard threshold > lastNotifiedThreshold || !notifiedRecently else { return }
        guard threshold > 0 else { return }
        lastNotifiedThreshold = threshold
        preferences.lastExposureNotificationThreshold = threshold
        preferences.lastExposureNotificationDate = .now

        let content = UNMutableNotificationContent()
        content.title = threshold >= 1 ? "过去 7 天的声暴露额度已用完" : "过去 7 天的声暴露额度已达 80%"
        content.body = "建议降低音量或暂停聆听。数值为估算，不是医疗或专业测量结果。"
        let request = UNNotificationRequest(
            identifier: "exposure-\(Int(threshold * 100))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
