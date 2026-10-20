import Foundation
import XCTest
@testable import TokenBar

final class MenuRetentionTests: XCTestCase {
    @MainActor
    func testServiceGroupingKeepsClaudeCardsAndSwitchesAdjacentWithoutChangingSelectionIDs() throws {
        let f = try MenuFixture(); defer { f.remove() }
        let store = f.store()
        let services = ["Codex", "Claude Code", "Cursor", "Grok Build", "Claude", "Codex"]
        store.accounts = services.enumerated().map { i, label in
            AccountConfig(provider: .snapshot, name: "Fixture", method: .snapshotFile, location: "/fixture/\(i)", serviceLabel: label)
        }
        let original = store.accounts.map(\.id), now = Date()
        for account in store.accounts {
            store.readings[account.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
                windows: [QuotaWindow(id: "week", label: "每周", remainingPercent: 63)])
            store.setMenuQuota(accountID: account.id, windowID: "week", enabled: true)
        }
        XCTAssertEqual(store.orderedAccounts.map(\.id), [original[0], original[5], original[1], original[4], original[2], original[3]])
        XCTAssertEqual(store.availableMenuMetrics.map(\.accountID), store.orderedAccounts.map(\.id))
        XCTAssertEqual(store.accounts.map(\.id), original)
        XCTAssertEqual(store.selectedMenuMetricIDs.count, 6)
    }

    @MainActor
    func testFailedRefreshRetainsNumbersAcrossRestartButNeverMakesAlertsOrReadingFresh() async throws {
        let f = try MenuFixture(); defer { f.remove() }
        try f.write(percent: 67)
        let store = f.store(); try await store.connect(f.account)
        let observed = try XCTUnwrap(store.readings[f.account.id]?.lastSuccessAt)
        try Data("unavailable fixture".utf8).write(to: f.file)
        await store.refresh()
        XCTAssertEqual(store.menuTitle, "~67%")
        XCTAssertTrue(store.menuTooltip.contains("上次成功读取"))
        XCTAssertTrue(store.menuTooltip.contains("暂时不可用"))
        XCTAssertNil(store.readings[f.account.id]?.lastSuccessAt)
        XCTAssertFalse(store.readings[f.account.id]!.isFresh(at: Date()))
        XCTAssertNil(store.takeNextExpiryNotice())
        let restored = f.store()
        XCTAssertEqual(restored.menuTitle, "~67%")
        let data = try JSONDecoder().decode([UUID: MenuReadingCache].self, from: Data(contentsOf: f.state.appendingPathComponent("menu-readings.json")))
        XCTAssertEqual(data[f.account.id]?.reading.lastSuccessAt, observed)
        try f.write(percent: 54)
        await restored.refresh()
        XCTAssertEqual(restored.menuTitle, "54%")
        XCTAssertFalse(restored.menuTooltip.contains("上次成功读取"))
    }

    @MainActor
    func testCachedValuesCannotCrossEmailIdentityEpochOrSourceChanges() async throws {
        for change in ["email", "identity", "epoch", "source"] {
            let f = try MenuFixture(); defer { f.remove() }
            try f.write(percent: 67)
            let store = f.store(); try await store.connect(f.account)
            if change == "source" {
                var account = f.account; account.location += ".different"
                try JSONEncoder().encode([account]).write(to: f.state.appendingPathComponent("accounts.json"))
                XCTAssertEqual(f.store().menuTitle, "—")
                continue
            }
            try f.write(percent: nil, status: "needs_auth", email: change == "email" ? "new@example.test" : "old@example.test",
                identity: change == "identity" ? "different" : "one",
                epoch: change == "epoch" ? "12345678-1234-1234-1234-123456789abc" : "12345678-1234-1234-1234-123456789aaa")
            await store.refresh()
            XCTAssertEqual(store.menuTitle, "—", change)
            XCTAssertEqual(f.store().menuTitle, "—", change)
        }
    }

    @MainActor
    func testSameIdentityAuthenticationFailureKeepsLastValueAndRemovalDeletesIt() async throws {
        let f = try MenuFixture(); defer { f.remove() }
        try f.write(percent: 67); let store = f.store(); try await store.connect(f.account)
        try f.write(percent: nil, status: "needs_auth"); await store.refresh()
        XCTAssertEqual(store.menuTitle, "~67%")
        XCTAssertTrue(store.menuTooltip.contains("需要登录"))
        store.remove(f.account)
        XCTAssertEqual(f.store().menuTitle, "—")
        let cache = try JSONDecoder().decode([UUID: MenuReadingCache].self, from: Data(contentsOf: f.state.appendingPathComponent("menu-readings.json")))
        XCTAssertTrue(cache.isEmpty)
    }

    @MainActor
    func testExplicitInvalidDataClearsFallbackAndDemoDoesNotReplaceLiveCache() async throws {
        let f = try MenuFixture(); defer { f.remove() }
        try f.write(percent: 67); let store = f.store(); try await store.connect(f.account)
        let file = f.state.appendingPathComponent("menu-readings.json"), before = try Data(contentsOf: file)
        store.loadDemo(); await store.refresh()
        XCTAssertEqual(try Data(contentsOf: file), before)
        store.exitDemo()
        try f.write(percent: nil, status: "unavailable", reason: "invalid_data"); await store.refresh()
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertEqual(f.store().menuTitle, "—")
    }

    @MainActor
    func testBadOrFutureCacheTimestampNeverDisplaysOrCrashes() throws {
        for time in [Date?.none, Date?.some(Date().addingTimeInterval(3600))] {
            let f = try MenuFixture(); defer { f.remove() }
            try JSONEncoder().encode([f.account]).write(to: f.state.appendingPathComponent("accounts.json"))
            let reading = AccountReading(status: .connected, checkedAt: Date(), lastSuccessAt: time,
                windows: [QuotaWindow(id: "weekly", label: "每周", remainingPercent: 99)])
            let cache = MenuReadingCache(account: f.account, reading: reading)
            try JSONEncoder().encode([f.account.id: cache]).write(to: f.state.appendingPathComponent("menu-readings.json"))
            let store = f.store()
            XCTAssertEqual(store.menuTitle, "—")
        }
    }

    @MainActor
    func testTenSecondDefaultAndSavedIntervalChoices() throws {
        let f = try MenuFixture(); defer { f.remove() }
        let store = f.store(); XCTAssertEqual(store.refreshSeconds, 10)
        store.updateRefreshInterval(15); XCTAssertEqual(f.store().refreshSeconds, 15)
        store.updateRefreshInterval(30); XCTAssertEqual(f.store().refreshSeconds, 30)
        store.updateRefreshInterval(10); XCTAssertEqual(f.store().refreshSeconds, 10)
        store.updateRefreshInterval(1); XCTAssertEqual(store.refreshSeconds, 10)
    }
}

private final class MenuFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let id = UUID(), suite = "MenuRetention." + UUID().uuidString
    var state: URL { root.appendingPathComponent("state") }
    var file: URL { root.appendingPathComponent("source.json") }
    var account: AccountConfig { AccountConfig(id: id, provider: .snapshot, name: "Fixture", method: .snapshotFile, location: file.path) }
    init() throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        UserDefaults(suiteName: suite)!.set(false, forKey: "showsAgentPrefix.v1")
    }
    @MainActor func store() -> AppStore { AppStore(directory: state, startTimers: false, defaults: UserDefaults(suiteName: suite)!) }
    func write(percent: Double?, status: String = "connected", email: String = "old@example.test", identity: String = "one", epoch: String = "12345678-1234-1234-1234-123456789aaa", reason: String? = nil) throws {
        let now = Date()
        var row: [String: Any] = ["status": status, "profile": ["email": email], "identity": ["provider": "fixture", "accountID": identity], "resetHistoryIdentity": epoch,
            "checkedAt": now.timeIntervalSince1970, "windows": []]
        if let percent {
            row["lastSuccessAt"] = now.timeIntervalSince1970
            row["windows"] = [["id": "weekly", "label": "每周", "remainingPercent": percent,
                               "startsAt": now.addingTimeInterval(-600000).timeIntervalSince1970, "resetsAt": now.addingTimeInterval(3600).timeIntervalSince1970]]
        }
        if let reason { row["reason"] = reason }
        try JSONSerialization.data(withJSONObject: row).write(to: file)
    }
    func remove() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
