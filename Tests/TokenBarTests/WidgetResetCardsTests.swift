import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class WidgetResetCardsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_676_800)

    func testLegacySnapshotWithoutResetCardsStillDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(cards: nil))) as? [String: Any])
        var rows = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        rows[0].removeValue(forKey: "resetCards")
        object["accounts"] = rows
        let decoded = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        try decoded.validate()
        XCTAssertNil(decoded.accounts[0].resetCards)
        XCTAssertNil(decoded.accounts[0].resetCardsLabel(at: now))
        XCTAssertEqual(decoded.accounts[0].displayMetrics().map(\.value), ["42%", "125 点"])
    }

    func testKnownZeroRoundTripsAndExpiresAsHistoryInsteadOfDisappearing() throws {
        let input = snapshot(cards: 0)
        try input.validate()
        let decoded = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: JSONEncoder().encode(input))
        let account = try XCTUnwrap(decoded.accounts.first)
        XCTAssertEqual(account.resetCards, 0)
        XCTAssertEqual(account.resetCardsLabel(at: now), "重置卡 0")
        XCTAssertEqual(account.resetCardsLabel(at: now.addingTimeInterval(120)), "上次重置卡 0")
        XCTAssertEqual(account.displayStatus(at: now.addingTimeInterval(120)), .stale)
        XCTAssertEqual(account.displayMetrics().map(\.id), ["weekly", "credits"])
    }

    func testCardsRequireObservationAndRejectInvalidCounts() throws {
        var invalid = snapshot(cards: -1)
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertNil(invalid.accounts[0].resetCardsLabel(at: now))
        invalid = snapshot(cards: TokenBarWidgetConstants.maximumResetCards)
        XCTAssertNoThrow(try invalid.validate())
        XCTAssertEqual(invalid.accounts[0].resetCardsLabel(at: now), "重置卡 1000000")
        for count in [TokenBarWidgetConstants.maximumResetCards + 1, Int.max] {
            invalid = snapshot(cards: count)
            XCTAssertThrowsError(try invalid.validate())
            XCTAssertNil(invalid.accounts[0].resetCardsLabel(at: now))
        }
        invalid = snapshot(cards: 2)
        invalid.accounts[0].status = .unavailable
        invalid.accounts[0].observedAt = nil
        invalid.accounts[0].freshUntil = nil
        invalid.accounts[0].metrics = []
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertNil(invalid.accounts[0].resetCardsLabel(at: now))
        invalid.accounts[0].resetCards = nil
        XCTAssertNoThrow(try invalid.validate())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(cards: nil))) as? [String: Any])
        var rows = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        rows[0]["resetCards"] = 1e100
        object["accounts"] = rows
        XCTAssertThrowsError(try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    @MainActor
    func testProjectionKeepsCardsAndPointsWithMoreThanThreeWindowsWithoutChangingPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-Cards-\(UUID().uuidString)")
        let suite = "TokenBar.Cards.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root, startTimers: false, defaults: defaults)
        let config = AccountConfig(provider: .codex, name: "Unused name", method: .localFile, location: "/fixture/unused.json")
        store.accounts = [config]
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: (0..<4).map { QuotaWindow(id: "window-\($0)", label: "额度 \($0)", remainingPercent: Double(40 + $0)) },
            credits: 0, resetCardsAvailable: 2, email: "cards@example.com")
        store.setMenuQuota(accountID: config.id, windowID: "window-0", enabled: true)
        store.setMenuQuota(accountID: config.id, windowID: "window-1", enabled: true)
        store.setMenuQuota(accountID: config.id, windowID: "window-2", enabled: true)
        let selection = store.selectedMenuMetricIDs
        let projected = try XCTUnwrap(store.widgetSnapshot(at: now))
        try projected.validate()
        let row = try XCTUnwrap(projected.accounts.first)
        XCTAssertEqual(row.resetCards, 2)
        XCTAssertEqual(row.metrics.map(\.id), ["window-0", "window-1", "credits"])
        XCTAssertEqual(row.displayMetrics().map(\.value), ["40%", "0 点"])
        XCTAssertEqual(row.resetCardsLabel(at: now), "重置卡 2")
        XCTAssertEqual(store.selectedMenuMetricIDs, selection)
        XCTAssertEqual(store.accounts, [config])
        store.readings[config.id]?.credits = nil
        let noPoints = try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0]
        XCTAssertEqual(noPoints.metrics.map(\.id), ["window-0", "window-1", "window-2"])
        XCTAssertEqual(noPoints.resetCards, 2)
    }

    @MainActor
    func testProjectionDoesNotInventCardsWithoutSuccessfulObservationAndPreservesKnownHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-Cards-\(UUID().uuidString)")
        let suite = "TokenBar.Cards.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root, startTimers: false, defaults: defaults)
        let config = AccountConfig(provider: .codex, name: "Unused", method: .localFile, location: "/fixture/unused.json")
        store.accounts = [config]
        store.readings[config.id] = AccountReading(status: .needsAuth, checkedAt: now, lastSuccessAt: nil, resetCardsAvailable: 0)
        var row = try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0]
        XCTAssertNil(row.resetCards)
        store.readings[config.id]?.lastSuccessAt = now.addingTimeInterval(-300)
        row = try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0]
        XCTAssertEqual(row.resetCards, 0)
        XCTAssertEqual(row.status, .needsAuth)
        XCTAssertFalse(row.isFresh(at: now))
        XCTAssertEqual(row.resetCardsLabel(at: now), "上次重置卡 0")
        store.readings[config.id]?.resetCardsAvailable = nil
        XCTAssertNil(try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0].resetCards)
        for count in [-1, TokenBarWidgetConstants.maximumResetCards + 1, Int.max] {
            store.readings[config.id]?.resetCardsAvailable = count
            XCTAssertNil(try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0].resetCards)
        }
    }

    func testDisplayPairUsesPointsOnceAndDoesNotRepeatLegacyCardsMetric() {
        var row = snapshot(cards: 2).accounts[0]
        row.metrics = [
            TokenBarWidgetMetric(id: "weekly", label: "每周", value: "42%", remainingPercent: 42),
            TokenBarWidgetMetric(id: "extra", label: "其他", value: "25%", remainingPercent: 25),
            TokenBarWidgetMetric(id: "credits", label: "点数", value: "0 点", remainingPercent: nil)
        ]
        XCTAssertEqual(row.displayMetrics().map(\.id), ["weekly", "credits"])
        XCTAssertEqual(row.displayMetrics(limit: 1).map(\.id), ["weekly"])
        XCTAssertTrue(row.displayMetrics(limit: 0).isEmpty)
        row.metrics = [row.metrics[2]]
        XCTAssertEqual(row.displayMetrics().map(\.id), ["credits"])
        row.metrics.append(TokenBarWidgetMetric(id: "reset-cards", label: "重置卡", value: "2 张", remainingPercent: nil))
        XCTAssertEqual(row.displayMetrics().map(\.id), ["credits"])
        XCTAssertEqual(row.resetCardsLabel(at: now), "重置卡 2")
    }

    private func snapshot(cards: Int?) -> TokenBarWidgetSnapshot {
        TokenBarWidgetSnapshot(generatedAt: now, accounts: [TokenBarWidgetAccount(id: UUID(), email: "cards@example.com", provider: "Codex", plan: "Pro",
            status: .connected, observedAt: now, freshUntil: now.addingTimeInterval(120),
            metrics: [TokenBarWidgetMetric(id: "weekly", label: "每周", value: "42%", remainingPercent: 42),
                      TokenBarWidgetMetric(id: "credits", label: "点数", value: "125 点", remainingPercent: nil)], resetCards: cards)])
    }
}
