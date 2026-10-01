import Foundation
import Testing
@testable import VolumeMonitor

@Suite struct WeeklySummaryTests {
    private let calendar = WeeklySummaryBuilder.calendar

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func bucket(_ minute: Date, energy: Double, seconds: Double = 60, peak: Double = 70,
                        device: String = "jack", apps: [String: Double]? = nil) -> ExposureBucket {
        ExposureBucket(minute: minute, normalizedEnergyAt80Seconds: energy, measuredDuration: seconds,
                       peakDBA: peak, deviceUID: device, appEnergy: apps)
    }

    @Test func weeksStartOnMondayAndSplitDays() {
        // 2026-09-28 是周一，10-04 周日，10-05 下一周周一。
        let buckets = [
            bucket(date(2026, 9, 28), energy: 1),
            bucket(date(2026, 9, 30), energy: 3, peak: 82, apps: ["a": 2, "b": 1]),
            bucket(date(2026, 10, 4, 23), energy: 2),
            bucket(date(2026, 10, 5, 0), energy: 5)
        ]
        let weeks = WeeklySummaryBuilder.build(from: buckets, calendar: calendar)
        #expect(weeks.count == 2)
        let first = weeks[0]
        #expect(first.weekStart == date(2026, 9, 28, 0))
        #expect(first.energy == 6)
        #expect(first.dailyEnergy == [1, 0, 3, 0, 0, 0, 2])
        #expect(first.maxLAF == 82)
        #expect(first.appEnergy == ["a": 2, "b": 1])
        #expect(first.unattributedEnergy == 3)
        #expect(first.loudestDay?.index == 2)
        #expect(weeks[1].energy == 5)
    }

    @Test @MainActor func archiveKeepsCompletedWeeksAndNeverOverwritesPrunedOnes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = LocalDataStore(directoryURL: directory)
        try data.merge(bucket: bucket(date(2026, 9, 21), energy: 4))
        try data.merge(bucket: bucket(date(2026, 9, 29), energy: 2))

        let store = WeeklySummaryStore(directoryURL: directory, dataStore: data)
        let now = date(2026, 10, 1)
        #expect(store.archiveCompletedWeeks(now: now))
        #expect(store.archivedWeeks.map(\.energy) == [4])           // 本周不归档
        #expect(store.currentWeek(now: now).energy == 2)

        // 8 周后明细被裁剪：存档保持原值，不会被覆盖或删除。
        try data.pruneBuckets(before: date(2026, 9, 25))
        let later = date(2026, 11, 30)
        store.archiveCompletedWeeks(now: later)
        let reloaded = WeeklySummaryStore(directoryURL: directory, dataStore: data)
        #expect(reloaded.archivedWeeks.first?.energy == 4)
        #expect(reloaded.archivedWeeks.count == 2)
    }
}

@Suite struct ProfileTransferTests {
    @Test func bundleRoundTripsAndRebindsCalibrations() throws {
        let profile = TransducerProfile(
            name: "DT 1990", deviceUID: "old-jack", kind: .wiredHeadphones,
            sensitivity: .dbPerVolt(110), sensitivityReferenceHz: 500,
            outputSource: OutputSourceProfile(maxOutputVRMS: 1, volumeCurve: []),
            reference: "spec", isConfirmed: true
        )
        let calibration = CalibrationProfile(
            headphoneProfileID: profile.id, headphoneName: profile.name,
            outputDeviceUID: "old-jack", outputDeviceName: "旧耳机孔",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)   // ISO 8601 只存到秒
        )
        let bundle = ProfileExportBundle(exportedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                         profiles: [profile], calibrations: [calibration])
        let decoded = try ProfileExportBundle.decode(bundle.encoded())
        #expect(decoded == bundle)
        #expect(decoded.profiles.first?.sensitivityReferenceHz == 500)

        let rebound = decoded.calibrations(for: profile, reboundTo: "new-jack", deviceName: "外置耳机")
        #expect(rebound.map(\.outputDeviceUID) == ["new-jack"])
        #expect(rebound.first?.outputDeviceName == "外置耳机")
        #expect(decoded.calibrations(for: profile).map(\.outputDeviceUID) == ["old-jack"])
    }

    @Test func rejectsForeignJSON() {
        #expect(throws: (any Error).self) {
            try ProfileExportBundle.decode(Data(#"{"format":"other","version":1,"exportedAt":"2026-10-01T00:00:00Z","profiles":[],"calibrations":[]}"#.utf8))
        }
    }
}

@Suite struct AppAttributionTests {
    @Test func helperProcessesFoldIntoTheirApps() {
        #expect(AppAudioAttributionMonitor.appKey(bundleID: "com.google.Chrome.helper", pid: 1) == "com.google.Chrome")
        #expect(AppAudioAttributionMonitor.appKey(bundleID: "com.google.Chrome.helper.renderer", pid: 1) == "com.google.Chrome")
        #expect(AppAudioAttributionMonitor.appKey(bundleID: "com.microsoft.edgemac.helper", pid: 1) == "com.microsoft.edgemac")
        #expect(AppAudioAttributionMonitor.appKey(bundleID: "com.apple.WebKit.GPU", pid: 1) == AppNames.webKitKey)
        #expect(AppAudioAttributionMonitor.appKey(bundleID: "org.mozilla.plugincontainer", pid: 1) == "org.mozilla.firefox")
        #expect(AppAudioAttributionMonitor.appKey(bundleID: "com.netease.163music", pid: 1) == "com.netease.163music")
    }

    @Test @MainActor func exposureIsSplitByAppShareAndSumsToTotal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = LocalDataStore(directoryURL: directory)
        let defaults = try #require(UserDefaults(suiteName: "VolumeMonitorTests-\(UUID().uuidString)"))
        let service = ExposureService(store: data, preferences: AppPreferences(defaults: defaults))
        let minute = Date(timeIntervalSince1970: 1_790_000_040)
        _ = service.ingest(levelDBA: 80, peakDBA: 85, duration: 10, deviceUID: "jack",
                           currentLevelDBA: 80, appEnergy: ["music": 3, "chrome": 1], at: minute)
        _ = service.ingest(levelDBA: 80, peakDBA: 85, duration: 10, deviceUID: "jack",
                           currentLevelDBA: 80, appEnergy: [:], at: minute.addingTimeInterval(1))
        service.flush()
        let bucket = try #require(data.exposureBuckets.first)
        #expect(abs(bucket.normalizedEnergyAt80Seconds - 20) < 1e-9)
        #expect(abs((bucket.appEnergy?["music"] ?? 0) - 7.5) < 1e-9)
        #expect(abs((bucket.appEnergy?["chrome"] ?? 0) - 2.5) < 1e-9)

        let reloaded = LocalDataStore(directoryURL: directory)
        #expect(reloaded.exposureBuckets.first?.appEnergy == bucket.appEnergy)
    }
}
