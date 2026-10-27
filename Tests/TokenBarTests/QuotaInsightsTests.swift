import Foundation
import XCTest
@testable import TokenBar

final class QuotaInsightsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_145_600)
    private let account = AccountConfig(provider: .snapshot, name: "Fixture", method: .snapshotFile, location: "/fixture.json")
    private func reading(_ percent: Double, at now: Date, reset: Date? = nil) -> AccountReading {
        AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: [QuotaWindow(id: "weekly", label: "每周", remainingPercent: percent, resetsAt: reset ?? now.addingTimeInterval(3600))],
            resetHistoryIdentity: "12345678-1234-1234-1234-123456789abc")
    }
    func testLowThresholdsDeduplicateAndRearmOnlyAboveHysteresis() throws {
        var state = QuotaInsightState(); let preferences = QuotaInsightPreferences()
        let reset = now.addingTimeInterval(3600)
        func update(_ percent: Double, _ seconds: Double) {
            let at = now.addingTimeInterval(seconds)
            state.update(accounts: [account], readings: [account.id: reading(percent, at: at, reset: reset)], preferences: preferences, now: at)
        }
        update(8, 0)
        XCTAssertEqual(state.events.count, 1); XCTAssertEqual(state.events[0].threshold, 10)
        update(8, 10); update(11, 20); update(8, 30)
        XCTAssertEqual(state.events.count, 1)
        update(23, 40); update(8, 50)
        XCTAssertEqual(state.events.count, 2)
        XCTAssertEqual(Set(state.events.map(\.id)).count, 2)
        let saved = try JSONDecoder().decode(QuotaInsightState.self, from: JSONEncoder().encode(state))
        state = saved; update(8, 60)
        XCTAssertEqual(state.events.count, 2)
    }
    func testResetRequiresAnElapsedPreviousDeadlineAndNewSourceObservation() {
        var state = QuotaInsightState(); let preferences = QuotaInsightPreferences()
        state.update(accounts: [account], readings: [account.id: reading(50, at: now, reset: now.addingTimeInterval(60))], preferences: preferences, now: now)
        let next = now.addingTimeInterval(120)
        state.update(accounts: [account], readings: [account.id: reading(100, at: next, reset: next.addingTimeInterval(3600))], preferences: preferences, now: next)
        XCTAssertEqual(state.events.filter { $0.kind == .reset }.count, 1)
        state.update(accounts: [account], readings: [account.id: reading(100, at: next, reset: next.addingTimeInterval(3600))], preferences: preferences, now: next.addingTimeInterval(10))
        XCTAssertEqual(state.events.filter { $0.kind == .reset }.count, 1)
    }
    func testStaleUnknownAndReserveCannotTriggerLowUsageOrInventZero() {
        var state = QuotaInsightState(), stale = reading(5, at: now.addingTimeInterval(-300))
        state.update(accounts: [account], readings: [account.id: stale], preferences: QuotaInsightPreferences(), now: now)
        XCTAssertTrue(state.events.isEmpty)
        stale = reading(0, at: now); stale.windows[0].group = "reserve"
        state.update(accounts: [account], readings: [account.id: stale], preferences: QuotaInsightPreferences(), now: now)
        XCTAssertTrue(state.events.isEmpty)
        stale.windows = []; stale.status = .unavailable
        state.update(accounts: [account], readings: [account.id: stale], preferences: QuotaInsightPreferences(), now: now)
        XCTAssertTrue(state.events.isEmpty)
    }
    func testAuthenticationIsLatchedAcrossTransportErrorsAndHistoryDropsOnIdentityChange() {
        var state = QuotaInsightState(), r = reading(5, at: now)
        state.update(accounts: [account], readings: [account.id: r], preferences: QuotaInsightPreferences(), now: now)
        r.status = .needsAuth
        state.update(accounts: [account], readings: [account.id: r], preferences: QuotaInsightPreferences(), now: now.addingTimeInterval(1))
        r.status = .unavailable
        state.update(accounts: [account], readings: [account.id: r], preferences: QuotaInsightPreferences(), now: now.addingTimeInterval(2))
        r.status = .needsAuth
        state.update(accounts: [account], readings: [account.id: r], preferences: QuotaInsightPreferences(), now: now.addingTimeInterval(3))
        XCTAssertEqual(state.events.filter { $0.kind == .authentication }.count, 1)
        r = reading(90, at: now.addingTimeInterval(4)); r.resetHistoryIdentity = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        state.update(accounts: [account], readings: [account.id: r], preferences: QuotaInsightPreferences(), now: now.addingTimeInterval(4))
        XCTAssertTrue(state.events.isEmpty)
    }
    func testCardExpiryOnlyUsesKnownAvailableFutureCards() {
        var state = QuotaInsightState(), r = reading(90, at: now)
        r.resetCards = [ResetCard(status: "available", expiresAt: now.addingTimeInterval(3600)),
                       ResetCard(status: "available", expiresAt: nil), ResetCard(status: "available", expiresAt: now),
                       ResetCard(status: "redeemed", expiresAt: now.addingTimeInterval(3600))]
        state.update(accounts: [account], readings: [account.id: r], preferences: QuotaInsightPreferences(), now: now)
        XCTAssertEqual(state.events.filter { $0.kind == .expiry }.count, 1)
        state.update(accounts: [account], readings: [account.id: r], preferences: QuotaInsightPreferences(), now: now.addingTimeInterval(15))
        XCTAssertEqual(state.events.filter { $0.kind == .expiry }.count, 1)
    }
    func testResolvedQueuedEventsCannotShowAndVerifiedEmailChangeRebindsLegacySlot() throws {
        var state = QuotaInsightState(), r = reading(5, at: now)
        r.resetHistoryIdentity = nil; r.identityKey = String(repeating: "a", count: 64); r.email = "first@example.test"
        let preferences = QuotaInsightPreferences()
        state.update(accounts: [account], readings: [account.id: r], preferences: preferences, now: now)
        let event = try XCTUnwrap(state.events.first)
        XCTAssertTrue(state.isActionable(event, account: account, reading: r, preferences: preferences, now: now))
        var recovered = r; recovered.windows[0].remainingPercent = 80
        XCTAssertFalse(state.isActionable(event, account: account, reading: recovered, preferences: preferences, now: now))
        var changed = r; changed.email = "second@example.test"
        XCTAssertFalse(state.isActionable(event, account: account, reading: changed, preferences: preferences, now: now))
        state.update(accounts: [account], readings: [account.id: changed], preferences: preferences, now: now.addingTimeInterval(1))
        XCTAssertEqual(state.events.count, 1); XCTAssertNotEqual(state.events[0].identity, event.identity)
        let newEvent = state.events[0]
        changed.email = nil
        state.update(accounts: [account], readings: [account.id: changed], preferences: preferences, now: now.addingTimeInterval(2))
        XCTAssertEqual(state.events[0].identity, newEvent.identity)
        try state.validate()
    }

    func testReportedCardRemindersRequireFreshOfficialEvidenceAndNeverOverrideNativeZero() {
        var r = reading(90, at: now)
        let card = ResetCard(status: "available", expiresAt: now.addingTimeInterval(600))
        r.reportedResetCards = ReportedResetCards(available: 1, detailsAt: now, provenance: .officialWeb, cards: [card])
        XCTAssertEqual(QuotaInsightState.remindableCards(r, now: now).count, 1)
        r.reportedResetCards?.detailsAt = now.addingTimeInterval(-301)
        XCTAssertTrue(QuotaInsightState.remindableCards(r, now: now).isEmpty)
        r.reportedResetCards?.detailsAt = now; r.reportedResetCards?.provenance = .ownerConfirmed
        XCTAssertTrue(QuotaInsightState.remindableCards(r, now: now).isEmpty)
        r.reportedResetCards?.provenance = .officialWeb; r.resetCardsAvailable = 0; r.resetCards = [card]
        XCTAssertTrue(QuotaInsightState.remindableCards(r, now: now).isEmpty)
    }

    @MainActor
    func testCommonPopupGateHonorsQuietTimeAndFavoritesStayIndependentOfEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "QuotaInsights." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root, startTimers: false, defaults: defaults)
        store.setCalendarTimeZone("UTC")
        store.accounts = [account]; store.readings = [account.id: reading(90, at: now)]
        store.toggleFavorite(account)
        var preferences = store.insightPreferences; preferences.filter = .favorites
        store.updateInsightPreferences(preferences)
        XCTAssertEqual(store.visibleDashboardAccounts.count, 1)
        XCTAssertTrue(store.accounts[0].enabled)
        let formatter = ISO8601DateFormatter()
        XCTAssertFalse(store.passiveNoticesAllowed(at: formatter.date(from: "2026-10-28T23:00:00Z")!))
        XCTAssertTrue(store.passiveNoticesAllowed(at: formatter.date(from: "2026-10-28T12:00:00Z")!))
        XCTAssertFalse(try store.exportCloudRecords().keys.contains { $0.contains("insight") || $0.contains("favorite") })
    }

    func testQuietHoursCrossMidnightAndDoNotSuppressRecording() {
        var prefs = QuotaInsightPreferences(); let utc = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        XCTAssertTrue(prefs.isQuiet(at: formatter.date(from: "2026-10-28T23:00:00Z")!, timeZone: utc))
        XCTAssertTrue(prefs.isQuiet(at: formatter.date(from: "2026-10-28T07:00:00Z")!, timeZone: utc))
        XCTAssertFalse(prefs.isQuiet(at: formatter.date(from: "2026-10-28T08:00:00Z")!, timeZone: utc))
        prefs.quietEnd = prefs.quietStart
        XCTAssertFalse(prefs.isQuiet(at: now, timeZone: utc))
        var state = QuotaInsightState()
        state.update(accounts: [account], readings: [account.id: reading(5, at: now)], preferences: prefs, now: now)
        XCTAssertEqual(state.events.count, 1)
    }
}
