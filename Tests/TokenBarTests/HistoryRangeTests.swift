import Foundation
import XCTest
@testable import TokenBar

final class HistoryRangeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_145_600)
    private let epoch = "12345678-1234-1234-1234-123456789abc"
    private func stamp(_ offset: TimeInterval = 0) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    private func document(_ range: QuotaHistoryRange, epoch: String? = nil, advertises: Bool = true) -> [String: Any] {
        let trend: [String: Any] = ["status": "ready", "metric": "quota", "unit": "percentage-points", "from": stamp(-range.duration), "to": stamp(),
            "bucketSeconds": range == .hour ? 300 : range == .day ? 3600 : 21600,
            "balancePoints": [["at": stamp(-120), "remaining": 80, "connect": false], ["at": stamp(), "remaining": 75, "connect": true]],
            "totalUsed": 5, "coverageSeconds": 120, "observedAt": stamp()]
        return ["schemaVersion": 1, "historyRange": range.rawValue, "historyRanges": advertises ? ["1h", "24h", "7d"] : ["1h"], "collectedAt": stamp(),
            "accounts": [["id": "codex-one", "product": "codex", "status": "connected", "checkedAt": stamp(), "lastSuccessAt": stamp(),
                "resetHistoryIdentity": epoch ?? self.epoch, "profile": ["email": "fixture@example.test"],
                "windows": [["id": "weekly", "label": "每周", "unit": "percent", "remainingPercent": 75, "usageTrend": trend]]]]]
    }
    private func write(_ object: Any, to file: URL) throws { try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic) }

    func testAdvertisedFixedSiblingProvidesOnlyMatchingWindowHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("snapshot.json"), sibling = root.appendingPathComponent("snapshot.json.range-24h.json")
        try write(document(.hour), to: primary); try write(document(.day), to: sibling)
        let config = AccountConfig(provider: .snapshot, name: "Fixture", method: .snapshotFile, location: primary.path)
        let client = ProviderClient(now: { self.now })
        let result = try await client.fetchCatalog(config, range: .day)
        let r = try XCTUnwrap(result.entries.first?.reading)
        XCTAssertEqual(r.windows.first?.usageTrend?.range, .day)
        XCTAssertEqual(r.windows.first?.remainingPercent, 75)
        XCTAssertEqual(r.lastSuccessAt, now)
        XCTAssertEqual(r.sourceCollectedAt, now)
        try write(document(.day, epoch: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), to: sibling)
        let mismatched = try await client.fetchCatalog(config, range: .day)
        XCTAssertNotEqual(mismatched.entries.first?.reading.windows.first?.usageTrend?.range, .day)
        try write(document(.week), to: sibling)
        let wrongRange = try await client.fetchCatalog(config, range: .day)
        XCTAssertNotEqual(wrongRange.entries.first?.reading.windows.first?.usageTrend?.range, .day)
    }

    func testLegacyUnadvertisedMissingAndSymlinkedHistoryCannotExpandSourceReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("snapshot.json"), sibling = root.appendingPathComponent("snapshot.json.range-7d.json"), target = root.appendingPathComponent("unrelated.json")
        let config = AccountConfig(provider: .snapshot, name: "Fixture", method: .snapshotFile, location: primary.path)
        let client = ProviderClient(now: { self.now })
        try write(document(.hour, advertises: false), to: primary); try write(document(.week), to: sibling)
        var result = try await client.fetchCatalog(config, range: .week)
        XCTAssertEqual(result.entries[0].reading.windows[0].usageTrend?.range, .hour)
        try write(document(.hour), to: primary); try FileManager.default.removeItem(at: sibling)
        result = try await client.fetchCatalog(config, range: .week)
        XCTAssertEqual(result.entries[0].reading.windows[0].remainingPercent, 75)
        XCTAssertNotEqual(result.entries[0].reading.windows[0].usageTrend?.range, .week)
        try write(document(.week), to: target); try FileManager.default.createSymbolicLink(at: sibling, withDestinationURL: target)
        result = try await client.fetchCatalog(config, range: .week)
        XCTAssertNotEqual(result.entries[0].reading.windows[0].usageTrend?.range, .week)
    }

    func testRangeMergeRejectsChangedQuotaDefinitionOrDifferentObservation() throws {
        let base = try SnapshotCatalog.parse(JSONSerialization.data(withJSONObject: document(.hour)), source: "fixture", at: now)
        let original = try SnapshotCatalog.parse(JSONSerialization.data(withJSONObject: document(.day)), source: "fixture", at: now)
        for mutation in 0...5 {
            var other = original
            switch mutation {
            case 0: other.entries[0].reading.windows[0].group = "additional"
            case 1: other.entries[0].reading.windows[0].resetsAt = now
            case 2: other.entries[0].reading.windows[0].remainingPercent = 74
            case 3: other.entries[0].reading.lastSuccessAt = now.addingTimeInterval(1)
            case 4: other.entries[0].reading.product = "another"
            default: other.entries[0].reading.email = "other@example.test"
            }
            let result = base.mergingHistory(other, range: .day)
            XCTAssertEqual(result.entries[0].reading.windows[0].usageTrend?.range, .hour)
            XCTAssertEqual(result.entries[0].reading.windows[0].remainingPercent, 75)
        }
    }

    @MainActor
    func testSingleAccountSnapshotLoadsRangesWithoutBecomingADiscoverySubscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HistoryRangeTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("snapshot.json")
        var base = document(.hour), history = document(.day)
        for key in ["primary", "history"] {
            var object = key == "primary" ? base : history
            var rows = object["accounts"] as! [[String: Any]]
            var sibling = rows[0]; sibling["id"] = "another-account"; rows.append(sibling); object["accounts"] = rows
            if key == "primary" { base = object } else { history = object }
        }
        try write(base, to: primary); try write(history, to: root.appendingPathComponent("snapshot.json.range-24h.json"))
        let config = AccountConfig(provider: .snapshot, name: "Only selected", method: .snapshotFile,
                                   location: primary.path, sourceAccountID: "codex-one")
        let client = ProviderClient(now: { self.now })
        let reading = try await client.fetch(config, range: .day)
        XCTAssertEqual(reading.windows.first?.usageTrend?.range, .day)
        let store = AppStore(directory: root.appendingPathComponent("app"), client: client, startTimers: false, defaults: defaults)
        store.accounts = [config]
        store.setTrendRange(.day)
        for _ in 0..<100 where store.readings[config.id]?.windows.first?.usageTrend?.range != .day {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(store.readings[config.id]?.windows.first?.usageTrend?.range, .day)
        XCTAssertEqual(store.accounts.map(\.id), [config.id]); XCTAssertTrue(store.snapshotSources.isEmpty)
    }

    @MainActor
    func testRangeChangesNeverReadDirectProviderCredentialsOrReplaceTheirReadings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HistoryRangeTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("snapshot.json")
        try write(document(.hour), to: primary)
        try write(document(.day), to: root.appendingPathComponent("snapshot.json.range-24h.json"))
        try write(document(.week), to: root.appendingPathComponent("snapshot.json.range-7d.json"))
        let calls = HistoryProviderCalls()
        let client = ProviderClient(now: { self.now }, credentialReader: { _, _ in calls.record(); throw ProviderError.needsAuth })
        let direct = AccountConfig(provider: .codex, name: "Independent direct", method: .keychain, location: "synthetic-keychain")
        let snapshot = AccountConfig(provider: .snapshot, name: "History", method: .snapshotFile, location: primary.path, sourceAccountID: "codex-one")
        let stored = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
                                    windows: [QuotaWindow(id: "weekly", label: "每周", remainingPercent: 42)])
        let store = AppStore(directory: root.appendingPathComponent("app"), client: client, startTimers: false, defaults: defaults)
        store.accounts = [direct, snapshot]; store.readings[direct.id] = stored
        for range in [QuotaHistoryRange.day, .week, .hour] {
            store.setTrendRange(range)
            for _ in 0..<100 where store.readings[snapshot.id]?.windows.first?.usageTrend?.range != range {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(store.readings[snapshot.id]?.windows.first?.usageTrend?.range, range)
            XCTAssertEqual(store.readings[direct.id], stored)
        }
        XCTAssertEqual(calls.count, 0)
    }

    @MainActor
    func testRapidRangeRoundTripSchedulesLatestRefreshAndPersistsOnlyLocalPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HistoryRangeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root, startTimers: false, defaults: defaults)
        var calls = 0
        store.beforeRefresh = { calls += 1; if calls == 1 { try? await Task.sleep(nanoseconds: 80_000_000) } }
        let task = Task { await store.refresh() }
        while !store.isRefreshing { await Task.yield() }
        store.setTrendRange(.day); store.setTrendRange(.hour)
        await task.value
        for _ in 0..<50 where calls < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(calls, 2)
        XCTAssertEqual(store.trendRange, .hour)
        XCTAssertEqual(AppStore(directory: root, startTimers: false, defaults: defaults).trendRange, .hour)
        XCTAssertFalse(try store.exportCloudRecords().keys.contains { $0.contains("trendRange") })
    }
}

private final class HistoryProviderCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
