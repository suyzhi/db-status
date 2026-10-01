import Foundation
import Testing
@testable import VolumeMonitor

@Suite @MainActor struct PersistenceTests {
    /// 与已发布的 v1 文件结构一致，用于迁移测试。
    private struct LegacyState: Codable {
        var schemaVersion: Int = 1
        var profiles: [TransducerProfile] = []
        var exposureBuckets: [ExposureBucket] = []
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeMonitorTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore() -> (LocalDataStore, URL) {
        let directory = makeDirectory()
        return (LocalDataStore(directoryURL: directory), directory)
    }

    private func bucket(
        minute: Date,
        energy: Double,
        peak: Double = 80,
        uid: String = "device"
    ) -> ExposureBucket {
        ExposureBucket(
            minute: minute,
            normalizedEnergyAt80Seconds: energy,
            measuredDuration: 60,
            peakDBA: peak,
            deviceUID: uid
        )
    }

    private func profile(name: String, uid: String) -> TransducerProfile {
        TransducerProfile(
            name: name,
            deviceUID: uid,
            kind: .wiredHeadphones,
            reference: "unit-test",
            isConfirmed: true
        )
    }

    @Test func mergeAccumulatesSameMinuteAndSurvivesReload() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let minute = Date(timeIntervalSince1970: 1_700_000_000)

        try store.merge(bucket: bucket(minute: minute, energy: 2))
        try store.merge(bucket: bucket(minute: minute, energy: 3, peak: 90))

        #expect(store.exposureBuckets.count == 1)
        #expect(store.exposureBuckets[0].normalizedEnergyAt80Seconds == 5)
        #expect(store.exposureBuckets[0].peakDBA == 90)

        // 追加写了同一分钟两行，重载时应合并为一条。
        let reloaded = LocalDataStore(directoryURL: directory)
        #expect(reloaded.exposureBuckets.count == 1)
        #expect(reloaded.exposureBuckets[0].normalizedEnergyAt80Seconds == 5)
        #expect(reloaded.exposureBuckets[0].peakDBA == 90)
    }

    @Test func outOfOrderMergeUpdatesTheIndexedBucket() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = base
        let second = base.addingTimeInterval(60)
        let third = base.addingTimeInterval(120)

        try store.merge(bucket: bucket(minute: first, energy: 1))
        try store.merge(bucket: bucket(minute: third, energy: 3))
        try store.merge(bucket: bucket(minute: second, energy: 2))
        try store.merge(bucket: bucket(minute: first, energy: 10))

        #expect(store.exposureBuckets.count == 3)
        let updated = try #require(store.exposureBuckets.first { $0.minute == first })
        #expect(updated.normalizedEnergyAt80Seconds == 11)
    }

    @Test func pruneKeepsIndexConsistent() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try store.merge(bucket: bucket(minute: now.addingTimeInterval(-1_000), energy: 1))
        try store.merge(bucket: bucket(minute: now, energy: 2))
        try store.pruneBuckets(before: now.addingTimeInterval(-500))
        #expect(store.exposureBuckets.count == 1)

        // 裁剪后下标必须仍然指向正确的桶。
        try store.merge(bucket: bucket(minute: now, energy: 5))
        #expect(store.exposureBuckets.count == 1)
        #expect(store.exposureBuckets[0].normalizedEnergyAt80Seconds == 7)

        let reloaded = LocalDataStore(directoryURL: directory)
        #expect(reloaded.exposureBuckets.count == 1)
        #expect(reloaded.exposureBuckets[0].normalizedEnergyAt80Seconds == 7)
    }

    @Test func pruningWithNothingToRemoveDoesNotThrow() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.merge(bucket: bucket(minute: now, energy: 2))
        try store.pruneBuckets(before: now.addingTimeInterval(-500))
        #expect(store.exposureBuckets.count == 1)
    }

    @Test func migratesLegacyV1FileAndKeepsItUntouched() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let minute = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = LegacyState(
            profiles: [profile(name: "legacy", uid: "dev-legacy")],
            exposureBuckets: [bucket(minute: minute, energy: 4, peak: 88, uid: "dev-legacy")]
        )
        let legacyURL = directory.appendingPathComponent("monitoring-data-v1.json")
        let legacyData = try JSONEncoder().encode(legacy)
        try legacyData.write(to: legacyURL)

        let store = LocalDataStore(directoryURL: directory)
        #expect(store.profiles.count == 1)
        #expect(store.exposureBuckets.count == 1)
        #expect(store.exposureBuckets[0].normalizedEnergyAt80Seconds == 4)

        // v2 文件已生成，v1 原文件一字未动。
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("profiles-v2.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("exposure-buckets-v2.ndjson").path
        ))
        #expect(try Data(contentsOf: legacyURL) == legacyData)

        // 再次打开走 v2，数据保持一致。
        let reopened = LocalDataStore(directoryURL: directory)
        #expect(reopened.profiles.count == 1)
        #expect(reopened.exposureBuckets.count == 1)
        #expect(reopened.exposureBuckets[0].normalizedEnergyAt80Seconds == 4)
        #expect(reopened.exposureBuckets[0].peakDBA == 88)
    }

    @Test func corruptLegacyFileFallsBackToEmptyWithWarning() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("这不是 JSON".utf8).write(
            to: directory.appendingPathComponent("monitoring-data-v1.json")
        )

        let store = LocalDataStore(directoryURL: directory)
        #expect(store.profiles.isEmpty)
        #expect(store.exposureBuckets.isEmpty)
        #expect(store.lastLoadWarning != nil)
    }

    @Test func skipsCorruptNdjsonLines() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let minute = Date(timeIntervalSince1970: 1_700_000_000)
        let bucketsURL = directory.appendingPathComponent("exposure-buckets-v2.ndjson")
        var content = Data("这不是 JSON\n".utf8)
        content.append(try JSONEncoder().encode(bucket(minute: minute, energy: 3)))
        content.append(0x0A)
        try content.write(to: bucketsURL)

        let store = LocalDataStore(directoryURL: directory)
        #expect(store.exposureBuckets.count == 1)
        #expect(store.lastLoadWarning != nil)
    }

    @Test func appendRepairsTornTrailingLine() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(60)
        // 模拟上次写入被打断：文件结尾没有换行。
        try JSONEncoder().encode(bucket(minute: first, energy: 1)).write(
            to: directory.appendingPathComponent("exposure-buckets-v2.ndjson")
        )

        let store = LocalDataStore(directoryURL: directory)
        try store.merge(bucket: bucket(minute: second, energy: 2))

        let reopened = LocalDataStore(directoryURL: directory)
        #expect(reopened.exposureBuckets.count == 2)
    }

    @Test func profileRoundTripUsesSeparateFile() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.upsert(profile: profile(name: "wired", uid: "dev-1"))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("profiles-v2.json").path
        ))

        let reloaded = LocalDataStore(directoryURL: directory)
        #expect(reloaded.profiles.count == 1)
        #expect(reloaded.profiles[0].deviceUID == "dev-1")

        try reloaded.removeProfile(deviceUID: "dev-1")
        #expect(LocalDataStore(directoryURL: directory).profiles.isEmpty)
    }
}

extension PersistenceTests {
    @Test func annotationsPersistInDateOrder() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let later = ExposureAnnotation(
            date: Date(timeIntervalSince1970: 2_000),
            title: "校准偏移变更",
            detail: "+10.0 dB → 无"
        )
        let earlier = ExposureAnnotation(
            date: Date(timeIntervalSince1970: 1_000),
            title: "保存 EM258 校准",
            detail: "测试"
        )
        try store.addAnnotation(later)
        try store.addAnnotation(earlier)

        let reloaded = LocalDataStore(directoryURL: directory)
        #expect(reloaded.annotations.map(\.id) == [earlier.id, later.id])
        #expect(reloaded.annotations.last?.detail == "+10.0 dB → 无")
    }
}
