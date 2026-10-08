import XCTest
@testable import TokenBar

final class ModelsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testLegacyMenuMetricPreferencesDecodeAndCreditsCannotCollideWithWindows() throws {
        let accountID = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["accountID": accountID.uuidString, "windowID": "credits", "accountName": "Personal", "windowLabel": "每周", "group": "default"])
        let legacy = try JSONDecoder().decode(MenuQuotaMetric.self, from: data)
        XCTAssertNil(legacy.kind)
        XCTAssertEqual(legacy.id, accountID.uuidString + "/credits")
        let credits = MenuQuotaMetric(accountID: accountID, windowID: "", accountName: "Personal", windowLabel: "剩余点数", group: "credits", kind: .credits)
        XCTAssertNotEqual(credits.id, legacy.id)
        XCTAssertNotEqual(credits.id, MenuQuotaMetric.selectionID(accountID: accountID, windowID: "#credits"))
        XCTAssertEqual(try JSONDecoder().decode(MenuQuotaMetric.self, from: JSONEncoder().encode(credits)), credits)
    }

    func testFreshnessNeverPromotesExpiredOrFutureReadings() {
        var reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now)
        XCTAssertTrue(reading.isFresh(at: now))
        reading.lastSuccessAt = now.addingTimeInterval(-121)
        XCTAssertFalse(reading.isFresh(at: now))
        XCTAssertEqual(reading.displayStatus(at: now), .stale)
        reading.lastSuccessAt = now.addingTimeInterval(61)
        XCTAssertFalse(reading.isFresh(at: now))
        reading.lastSuccessAt = now
        reading.windows = [QuotaWindow(id: "w", label: "每周", remainingPercent: 50, resetsAt: now)]
        XCTAssertFalse(reading.isFresh(at: now))
        reading.windows = []; reading.status = .needsAuth
        XCTAssertFalse(reading.isFresh(at: now))
        XCTAssertEqual(reading.displayStatus(at: now), .needsAuth)
    }

    func testUnknownAndZeroAreDistinct() {
        let unknown = QuotaWindow(id: "a", label: "额度", remainingPercent: nil)
        let zero = QuotaWindow(id: "b", label: "额度", remainingPercent: 0)
        XCTAssertEqual(unknown.displayValue, "未提供")
        XCTAssertEqual(zero.displayValue, "0%")
    }

    func testPacingOnlyAppliesToDefinedLongWindows() {
        var window = QuotaWindow(id: "w", label: "每周", remainingPercent: 94,
            resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-601200))
        XCTAssertEqual(window.alert(at: now), "即将重置")
        window.resetsAt = now.addingTimeInterval(172800)
        XCTAssertEqual(window.alert(at: now), "使用偏慢")
        window.startsAt = nil
        XCTAssertNil(window.alert(at: now))
        window.startsAt = now.addingTimeInterval(-14400); window.resetsAt = now.addingTimeInterval(3600)
        XCTAssertNil(window.alert(at: now))
    }

    @MainActor func testDemoDoesNotWriteAccountsOrCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TokenBarModelsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(directory: directory, startTimers: false, defaults: defaults)
        store.loadDemo()
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertEqual(store.menuTitle, "32%")
        let metric = try XCTUnwrap(store.availableMenuMetrics.last)
        store.setMenuQuota(accountID: metric.accountID, windowID: metric.windowID, enabled: true)
        XCTAssertEqual(store.menuTitle, "32% · 94%")
        XCTAssertNil(defaults.object(forKey: "menuQuotaSelection.v1"))
        XCTAssertNil(defaults.object(forKey: "menuQuotaMetrics.v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        store.exitDemo()
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertEqual(store.menuTitle, "—")
    }
}
