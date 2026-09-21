import Foundation
import UserNotifications

/// v1 单文件格式：档案与声暴露桶放在同一个 JSON 里整体重写。
private struct LegacyPersistedState: Codable {
    var schemaVersion = 1
    var profiles: [TransducerProfile] = []
    var exposureBuckets: [ExposureBucket] = []
}

/// v2 档案文件：内容小、变更少，整体原子重写即可。
private struct ProfilesFile: Codable {
    var schemaVersion = 2
    var profiles: [TransducerProfile] = []
}

@MainActor
final class LocalDataStore {
    static let shared = LocalDataStore()

    static let profilesFileName = "profiles-v2.json"
    static let bucketsFileName = "exposure-buckets-v2.ndjson"
    static let legacyFileName = "monitoring-data-v1.json"

    private(set) var profiles: [TransducerProfile]
    private(set) var exposureBuckets: [ExposureBucket]
    /// minute → exposureBuckets 下标。避免每分钟都做一次 O(n) 线性查找。
    private var bucketIndexByMinute: [Date: Int] = [:]
    /// 载入或迁移过程中的降级说明，供诊断使用。
    private(set) var lastLoadWarning: String?

    private let profilesURL: URL?
    private let bucketsURL: URL?
    private let legacyURL: URL?

    init(directoryURL: URL? = LocalDataStore.defaultDirectoryURL()) {
        let profilesURL = directoryURL?.appendingPathComponent(Self.profilesFileName)
        let bucketsURL = directoryURL?.appendingPathComponent(Self.bucketsFileName)
        let legacyURL = directoryURL?.appendingPathComponent(Self.legacyFileName)
        self.profilesURL = profilesURL
        self.bucketsURL = bucketsURL
        self.legacyURL = legacyURL

        let fileManager = FileManager.default
        let profilesExist = profilesURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let bucketsExist = bucketsURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

        var warning: String?
        // 只有 v2 文件缺失时才去解析体积较大的 v1 文件。
        var legacyState: LegacyPersistedState?
        if (!profilesExist || !bucketsExist), let legacyURL,
           fileManager.fileExists(atPath: legacyURL.path) {
            if let data = try? Data(contentsOf: legacyURL),
               let state = try? JSONDecoder().decode(LegacyPersistedState.self, from: data) {
                legacyState = state
            } else {
                warning = "旧的监测数据文件无法读取，已从空数据开始（原文件未改动）"
            }
        }

        if profilesExist, let profilesURL,
           let data = try? Data(contentsOf: profilesURL),
           let state = try? JSONDecoder().decode(ProfilesFile.self, from: data) {
            profiles = state.profiles
        } else {
            profiles = legacyState?.profiles ?? []
        }

        if bucketsExist, let bucketsURL {
            let result = LocalDataStore.readBucketFile(at: bucketsURL)
            exposureBuckets = result.buckets
            warning = result.warning ?? warning
        } else if let legacyState {
            exposureBuckets = LocalDataStore.coalesced(legacyState.exposureBuckets)
        } else {
            exposureBuckets = []
        }

        lastLoadWarning = warning
        rebuildBucketIndex()

        if !profilesExist || !bucketsExist {
            migrateLegacyFilesIfNeeded(
                hasLegacyState: legacyState != nil,
                profilesExist: profilesExist,
                bucketsExist: bucketsExist
            )
        }
        if let warning {
            NSLog("VolumeMonitor monitoring data: %@", warning)
        }
    }

    func upsert(profile: TransducerProfile) throws {
        profiles.removeAll { $0.id == profile.id || $0.deviceUID == profile.deviceUID }
        profiles.append(profile)
        try writeProfilesFile()
    }

    func removeProfile(deviceUID: String) throws {
        profiles.removeAll { $0.deviceUID == deviceUID }
        try writeProfilesFile()
    }

    /// 合并一个分钟桶：内存按下标 O(1) 合并，磁盘只追加一行。
    func merge(bucket: ExposureBucket) throws {
        if let index = bucketIndexByMinute[bucket.minute], index < exposureBuckets.count {
            exposureBuckets[index].normalizedEnergyAt80Seconds += bucket.normalizedEnergyAt80Seconds
            exposureBuckets[index].measuredDuration += bucket.measuredDuration
            exposureBuckets[index].peakDBA = max(exposureBuckets[index].peakDBA, bucket.peakDBA)
            exposureBuckets[index].deviceUID = bucket.deviceUID
        } else {
            bucketIndexByMinute[bucket.minute] = exposureBuckets.count
            exposureBuckets.append(bucket)
        }
        try appendBucketLine(bucket)
    }

    func pruneBuckets(before cutoff: Date) throws {
        guard exposureBuckets.contains(where: { $0.minute < cutoff }) else { return }
        exposureBuckets.removeAll { $0.minute < cutoff }
        rebuildBucketIndex()
        try compactBucketsFile()
    }

    private func rebuildBucketIndex() {
        bucketIndexByMinute.removeAll(keepingCapacity: true)
        bucketIndexByMinute.reserveCapacity(exposureBuckets.count)
        for (index, bucket) in exposureBuckets.enumerated() {
            bucketIndexByMinute[bucket.minute] = index
        }
    }

    // MARK: - 磁盘读写

    private func migrateLegacyFilesIfNeeded(
        hasLegacyState: Bool,
        profilesExist: Bool,
        bucketsExist: Bool
    ) {
        guard hasLegacyState else { return }
        var migrated = false
        if !profilesExist {
            do {
                try writeProfilesFile()
                migrated = true
            } catch {
                NSLog("VolumeMonitor profile migration failed: %@", error.localizedDescription)
            }
        }
        if !bucketsExist {
            do {
                try compactBucketsFile()
                migrated = true
            } catch {
                NSLog("VolumeMonitor bucket migration failed: %@", error.localizedDescription)
            }
        }
        if migrated {
            // v1 原文件保持不动，随时可以回退到旧版本。
            NSLog("VolumeMonitor migrated monitoring data to v2 format")
        }
    }

    private func writeProfilesFile() throws {
        guard let profilesURL else { return }
        try FileManager.default.createDirectory(
            at: profilesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ProfilesFile(profiles: profiles))
        try data.write(to: profilesURL, options: [.atomic, .completeFileProtection])
    }

    /// 追加一行 NDJSON；崩溃留下的半行会先补换行，避免两条记录粘连。
    private func appendBucketLine(_ bucket: ExposureBucket) throws {
        guard let bucketsURL else { return }
        try FileManager.default.createDirectory(
            at: bucketsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = try encoder.encode(bucket)
        payload.append(0x0A)

        guard FileManager.default.fileExists(atPath: bucketsURL.path) else {
            try payload.write(to: bucketsURL, options: [.atomic, .completeFileProtection])
            return
        }

        let handle = try FileHandle(forUpdating: bucketsURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if lastByte?.first != 0x0A {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.write(contentsOf: payload)
    }

    /// 全量重写（迁移与裁剪时使用）。
    private func compactBucketsFile() throws {
        guard let bucketsURL else { return }
        try FileManager.default.createDirectory(
            at: bucketsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for bucket in exposureBuckets.sorted(by: { $0.minute < $1.minute }) {
            data.append(try encoder.encode(bucket))
            data.append(0x0A)
        }
        try data.write(to: bucketsURL, options: [.atomic, .completeFileProtection])
    }

    private struct BucketReadResult {
        var buckets: [ExposureBucket]
        var warning: String?
    }

    private static func readBucketFile(at url: URL) -> BucketReadResult {
        guard let data = try? Data(contentsOf: url) else {
            return BucketReadResult(buckets: [], warning: "声暴露数据无法读取，已从空数据开始")
        }
        let decoder = JSONDecoder()
        var buckets: [ExposureBucket] = []
        var indexByMinute: [Date: Int] = [:]
        var skipped = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let bucket = try? decoder.decode(ExposureBucket.self, from: line) else {
                skipped += 1
                continue
            }
            if let index = indexByMinute[bucket.minute] {
                buckets[index].normalizedEnergyAt80Seconds += bucket.normalizedEnergyAt80Seconds
                buckets[index].measuredDuration += bucket.measuredDuration
                buckets[index].peakDBA = max(buckets[index].peakDBA, bucket.peakDBA)
                buckets[index].deviceUID = bucket.deviceUID
            } else {
                indexByMinute[bucket.minute] = buckets.count
                buckets.append(bucket)
            }
        }
        buckets.sort { $0.minute < $1.minute }
        return BucketReadResult(
            buckets: buckets,
            warning: skipped > 0 ? "\(skipped) 条声暴露记录无法解析，已跳过" : nil
        )
    }

    /// 同一分钟的重复记录按「能量/时长相加、峰值取大」合并。
    static func coalesced(_ buckets: [ExposureBucket]) -> [ExposureBucket] {
        var result: [ExposureBucket] = []
        var indexByMinute: [Date: Int] = [:]
        for bucket in buckets {
            if let index = indexByMinute[bucket.minute] {
                result[index].normalizedEnergyAt80Seconds += bucket.normalizedEnergyAt80Seconds
                result[index].measuredDuration += bucket.measuredDuration
                result[index].peakDBA = max(result[index].peakDBA, bucket.peakDBA)
                result[index].deviceUID = bucket.deviceUID
            } else {
                indexByMinute[bucket.minute] = result.count
                result.append(bucket)
            }
        }
        result.sort { $0.minute < $1.minute }
        return result
    }

    private static func defaultDirectoryURL() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("VolumeMonitor", isDirectory: true)
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
    private var lastPruneDate: Date?

    init(
        store: LocalDataStore = .shared,
        preferences: AppPreferences = .shared
    ) {
        self.store = store
        self.preferences = preferences
        lastNotifiedThreshold = preferences.lastExposureNotificationThreshold
        reloadSevenDayEnergy()
        pruneOldBuckets()
        lastPruneDate = .now
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
            pruneOldBucketsIfDue()
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

    /// 长时间不重启也要定期清理 8 周以前的桶，否则文件会无限增长。
    private func pruneOldBucketsIfDue(now: Date = .now) {
        if let lastPruneDate, now.timeIntervalSince(lastPruneDate) < 6 * 60 * 60 { return }
        lastPruneDate = now
        pruneOldBuckets(now: now)
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
