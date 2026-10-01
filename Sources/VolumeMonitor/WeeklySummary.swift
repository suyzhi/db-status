import Foundation

/// 一个自然周（周一 00:00 起）的声暴露汇总。
///
/// 分钟级明细只保留 8 周，周汇总单独存档并永久保留。保存的是原始能量与时长，
/// 暴露百分比按查看时选择的 WHO 模式换算。
struct WeeklySummary: Codable, Sendable, Equatable, Identifiable {
    var id: Date { weekStart }
    let weekStart: Date
    var energy: Double
    var listeningSeconds: Double
    var maxLAF: Double?
    /// 周一到周日，每天的能量与收听时长。
    var dailyEnergy: [Double]
    var dailySeconds: [Double]
    var appEnergy: [String: Double]
    var deviceEnergy: [String: Double]

    init(weekStart: Date) {
        self.weekStart = weekStart
        energy = 0
        listeningSeconds = 0
        maxLAF = nil
        dailyEnergy = Array(repeating: 0, count: 7)
        dailySeconds = Array(repeating: 0, count: 7)
        appEnergy = [:]
        deviceEnergy = [:]
    }

    func dosePercent(mode: ExposureMode) -> Double {
        ExposureMath.doseFraction(normalizedEnergyAt80: energy, mode: mode) * 100
    }

    var equivalentLevelDBA: Double? {
        ExposureMath.equivalentLevelDBA(normalizedEnergyAt80: energy, duration: listeningSeconds)
    }

    /// 能量最高的一天（0 = 周一）。
    var loudestDay: (index: Int, levelDBA: Double?, seconds: Double)? {
        guard let index = dailyEnergy.indices.max(by: { dailyEnergy[$0] < dailyEnergy[$1] }),
              dailyEnergy[index] > 0 else { return nil }
        return (
            index,
            ExposureMath.equivalentLevelDBA(
                normalizedEnergyAt80: dailyEnergy[index],
                duration: dailySeconds[index]
            ),
            dailySeconds[index]
        )
    }

    /// 未能归到具体 App 的能量（旧数据或识别失败）。
    var unattributedEnergy: Double {
        max(0, energy - appEnergy.values.reduce(0, +))
    }
}

enum WeeklySummaryBuilder {
    /// 周一为一周的第一天，与本地时区一致。
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func weekStart(for date: Date, calendar: Calendar = calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func build(
        from buckets: [ExposureBucket],
        calendar: Calendar = calendar
    ) -> [WeeklySummary] {
        var weeks: [Date: WeeklySummary] = [:]
        // 日历计算很慢（每次数微秒），5 万条分钟记录逐条算会卡界面：按本地日期缓存。
        var dayCache: [Int: (start: Date, day: Int)] = [:]
        let timeZone = calendar.timeZone
        for bucket in buckets where bucket.measuredDuration > 0 {
            let local = bucket.minute.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: bucket.minute))
            let dayKey = Int((local / 86_400).rounded(.down))
            let cached: (start: Date, day: Int)
            if let hit = dayCache[dayKey] {
                cached = hit
            } else {
                let start = weekStart(for: bucket.minute, calendar: calendar)
                let day = min(6, max(0, calendar.dateComponents(
                    [.day],
                    from: start,
                    to: calendar.startOfDay(for: bucket.minute)
                ).day ?? 0))
                cached = (start, day)
                dayCache[dayKey] = cached
            }
            let start = cached.start
            let day = cached.day
            var summary = weeks[start] ?? WeeklySummary(weekStart: start)
            summary.energy += bucket.normalizedEnergyAt80Seconds
            summary.listeningSeconds += bucket.measuredDuration
            summary.dailyEnergy[day] += bucket.normalizedEnergyAt80Seconds
            summary.dailySeconds[day] += bucket.measuredDuration
            summary.maxLAF = max(summary.maxLAF ?? bucket.peakDBA, bucket.peakDBA)
            summary.deviceEnergy[bucket.deviceUID, default: 0] += bucket.normalizedEnergyAt80Seconds
            for (app, energy) in bucket.appEnergy ?? [:] {
                summary.appEnergy[app, default: 0] += energy
            }
            weeks[start] = summary
        }
        return weeks.values.sorted { $0.weekStart < $1.weekStart }
    }
}

private struct WeeklySummaryFile: Codable {
    var schemaVersion = 1
    var weeks: [WeeklySummary] = []
}

/// 已结束的周汇总存档（永久保留），本周按分钟明细实时计算。
@MainActor
final class WeeklySummaryStore {
    static let shared = WeeklySummaryStore()
    static let fileName = "weekly-summaries-v1.json"

    private(set) var archivedWeeks: [WeeklySummary] = []
    private let fileURL: URL?
    private let dataStore: LocalDataStore

    init(
        directoryURL: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("VolumeMonitor", isDirectory: true),
        dataStore: LocalDataStore = .shared
    ) {
        fileURL = directoryURL?.appendingPathComponent(Self.fileName)
        self.dataStore = dataStore
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            archivedWeeks = (try? decoder.decode(WeeklySummaryFile.self, from: data).weeks) ?? []
        }
    }

    /// 分钟明细保留期，与 ExposureService 的裁剪一致。
    static let detailRetention: TimeInterval = 8 * 7 * 24 * 60 * 60

    /// 把已结束的周写入存档。明细仍完整保留的周按最新数据更新；
    /// 已被裁剪过的周只在没有存档时写入，绝不用残缺数据覆盖旧存档。
    @discardableResult
    func archiveCompletedWeeks(now: Date = .now) -> Bool {
        let calendar = WeeklySummaryBuilder.calendar
        let currentWeek = WeeklySummaryBuilder.weekStart(for: now, calendar: calendar)
        let pruneCutoff = now.addingTimeInterval(-Self.detailRetention)
        var byWeek = Dictionary(uniqueKeysWithValues: archivedWeeks.map { ($0.weekStart, $0) })
        var changed = false
        for week in WeeklySummaryBuilder.build(from: dataStore.exposureBuckets, calendar: calendar)
        where week.weekStart < currentWeek {
            let detailIntact = week.weekStart >= pruneCutoff
            guard detailIntact || byWeek[week.weekStart] == nil,
                  byWeek[week.weekStart] != week else { continue }
            byWeek[week.weekStart] = week
            changed = true
        }
        guard changed else { return false }
        archivedWeeks = byWeek.values.sorted { $0.weekStart < $1.weekStart }
        persist()
        return true
    }

    /// 本周（进行中）的实时汇总。
    func currentWeek(now: Date = .now) -> WeeklySummary {
        let calendar = WeeklySummaryBuilder.calendar
        let start = WeeklySummaryBuilder.weekStart(for: now, calendar: calendar)
        let buckets = dataStore.exposureBuckets.filter { $0.minute >= start }
        return WeeklySummaryBuilder.build(from: buckets, calendar: calendar).first
            ?? WeeklySummary(weekStart: start)
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(WeeklySummaryFile(weeks: archivedWeeks))
                .write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("VolumeMonitor weekly summary persistence failed: %@", error.localizedDescription)
        }
    }
}
