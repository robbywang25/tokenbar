import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class WidgetRankingGraceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_763_200)

    @MainActor
    func testCursorUsesOnlyCaseInsensitiveAPIWithoutFallingBackToAutoOrChangingColumns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        var config = fixture.account
        config.serviceLabel = "Cursor"
        store.accounts = [config]
        let reset = now.addingTimeInterval(86_400), start = reset.addingTimeInterval(-30 * 86_400)
        let auto = QuotaWindow(id: "auto", label: "Cursor 模型", remainingPercent: 99.99, resetsAt: reset, startsAt: start)
        let api = QuotaWindow(id: "API", label: "其他模型", remainingPercent: 0, resetsAt: reset, startsAt: start)
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [auto, api])
        var row = try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0]
        XCTAssertEqual(row.urgencyWindow?.label, "其他模型")
        XCTAssertEqual(row.urgencyWindow?.remainingPercent, 0)
        XCTAssertNil(row.urgency(at: now))
        XCTAssertNil(row.rankingUrgency(at: now))
        XCTAssertEqual(row.metrics.map(\.remainingPercent), [99.99, 0])
        store.readings[config.id]?.windows = [auto]
        row = try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0]
        XCTAssertNil(row.urgencyWindow)
        XCTAssertEqual(row.metrics.first?.remainingPercent, 99.99)
        var missingCycle = api; missingCycle.startsAt = nil
        store.readings[config.id]?.windows = [auto, missingCycle]
        XCTAssertNil(try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0].urgencyWindow)
        config.serviceLabel = "Other"
        store.accounts = [config]
        store.readings[config.id]?.windows = [auto, api]
        row = try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0]
        XCTAssertEqual(row.urgencyWindow?.label, "Cursor 模型")
        XCTAssertEqual(row.urgency(at: now)?.level, .urgent)
    }

    func testGrayHistoricalScoreFreezesUntilExactHourThenRanksBelowZeroAndUnknown() throws {
        var historical = account(observed: now, percent: 80)
        historical.status = .stale; historical.freshUntil = nil
        let reference = try XCTUnwrap(historical.rankingUrgency(at: now.addingTimeInterval(121)))
        XCTAssertEqual(reference.requiredDailyPercent, 40, accuracy: 0.000001)
        XCTAssertEqual(historical.rankingUrgency(at: now.addingTimeInterval(1_000)), reference)
        XCTAssertNil(historical.urgency(at: now.addingTimeInterval(121)))
        XCTAssertEqual(historical.displayStatus(at: now.addingTimeInterval(121)), .stale)
        let zero = account(observed: now.addingTimeInterval(121), percent: 0)
        let unknown = TokenBarWidgetAccount(id: UUID(), email: nil, provider: "Unknown", plan: nil,
            status: .unavailable, observedAt: nil, freshUntil: nil, metrics: [])
        let snapshot = TokenBarWidgetSnapshot(generatedAt: now.addingTimeInterval(121), accounts: [unknown, zero, historical])
        XCTAssertEqual(snapshot.rankedAccounts(at: now.addingTimeInterval(121)).map(\.id), [historical.id, zero.id, unknown.id])
        XCTAssertEqual(historical.rankingTier(at: now.addingTimeInterval(3_599)), 0)
        XCTAssertEqual(historical.rankingTier(at: now.addingTimeInterval(3_600)), 2)
        XCTAssertNil(historical.rankingUrgency(at: now.addingTimeInterval(3_600)))
        XCTAssertEqual(snapshot.rankedAccounts(at: now.addingTimeInterval(3_600)).map(\.id), [zero.id, unknown.id, historical.id])
    }

    @MainActor
    func testRequiredSourceObservationAnchorsGraceAndRepeatedHostWritesCannotRenewIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let config = fixture.account
        store.accounts = [config]
        store.readings[config.id] = reading(source: now.addingTimeInterval(-100))
        let first = try XCTUnwrap(store.widgetSnapshot(at: now))
        try first.validate()
        XCTAssertEqual(first.accounts[0].rankingObservedAt, now.addingTimeInterval(-100))
        XCTAssertEqual(first.accounts[0].rankingExpiresAt, now.addingTimeInterval(3_500))
        XCTAssertEqual(first.accounts[0].freshUntil, now.addingTimeInterval(20))
        let later = try XCTUnwrap(store.widgetSnapshot(at: now.addingTimeInterval(600)))
        try later.validate()
        XCTAssertNotEqual(later.generatedAt, first.generatedAt)
        XCTAssertEqual(later.accounts[0].rankingObservedAt, first.accounts[0].rankingObservedAt)
        XCTAssertEqual(later.accounts[0].rankingExpiresAt, first.accounts[0].rankingExpiresAt)
        XCTAssertNotNil(later.accounts[0].urgencyWindow)
        XCTAssertNil(later.accounts[0].urgency(at: now.addingTimeInterval(600)))
        XCTAssertNotNil(later.accounts[0].rankingUrgency(at: now.addingTimeInterval(3_499)))
        XCTAssertNil(later.accounts[0].rankingUrgency(at: now.addingTimeInterval(3_500)))
    }

    @MainActor
    func testInvalidRequiredSourcePreventsLegacyFallbackAndDoesNotInventRankingObservation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let config = fixture.account
        store.accounts = [config]
        for source: Date? in [nil, now.addingTimeInterval(61), .distantFuture] {
            store.readings[config.id] = reading(source: source)
            let snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
            try snapshot.validate()
            let restored = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: JSONEncoder().encode(snapshot)).accounts[0]
            XCTAssertEqual(restored.rankingObservedAtPresent, true)
            XCTAssertNil(restored.rankingObservedAt)
            XCTAssertNil(restored.rankingExpiresAt)
            XCTAssertNil(restored.rankingUrgency(at: now))
            XCTAssertNil(restored.urgencyWindow)
            XCTAssertEqual(restored.rankingTier(at: now), 1)
            XCTAssertNotNil(restored.observedAt)
        }
    }

    func testLegacySnapshotFallbackUsesObservationAndNeverGenerationDate() throws {
        var legacy = account(observed: now, percent: 80)
        legacy.rankingObservedAt = nil; legacy.rankingObservedAtPresent = nil
        let snapshot = TokenBarWidgetSnapshot(generatedAt: now.addingTimeInterval(3_000), accounts: [legacy])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("rankingObservedAt"))
        let restored = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: data).accounts[0]
        XCTAssertEqual(restored.rankingExpiresAt, now.addingTimeInterval(3_600))
        XCTAssertTrue(restored.isWithinRankingGrace(at: now.addingTimeInterval(3_599)))
        XCTAssertFalse(restored.isWithinRankingGrace(at: now.addingTimeInterval(3_600)))
    }

    func testRankingTimestampValidationRejectsFutureOrFreshnessExtendingAnchors() throws {
        var snapshot = TokenBarWidgetSnapshot(generatedAt: now, accounts: [account(observed: now, percent: 80)])
        XCTAssertNoThrow(try snapshot.validate())
        snapshot.accounts[0].rankingObservedAt = now.addingTimeInterval(1)
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.accounts[0] = account(observed: now.addingTimeInterval(61), percent: 80)
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.accounts[0].rankingObservedAt = nil
        snapshot.accounts[0].rankingObservedAtPresent = nil
        XCTAssertThrowsError(try snapshot.validate(), "A legacy fallback must not accept a future observation anchor.")
        snapshot.accounts[0] = account(observed: now, percent: 80)
        snapshot.accounts[0].rankingObservedAt = now.addingTimeInterval(-30)
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.accounts[0].rankingObservedAt = nil
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.accounts[0].status = .stale; snapshot.accounts[0].freshUntil = nil
        XCTAssertNoThrow(try snapshot.validate())
    }

    func testAuthenticationStateRemainsTruthfulAndFreshObservationRestoresRank() throws {
        var old = account(observed: now, percent: 80)
        old.status = .needsAuth; old.freshUntil = nil
        XCTAssertEqual(old.displayStatus(at: now.addingTimeInterval(300)), .needsAuth)
        XCTAssertNil(old.urgency(at: now.addingTimeInterval(300)))
        XCTAssertNotNil(old.rankingUrgency(at: now.addingTimeInterval(300)))
        XCTAssertEqual(old.rankingTier(at: now.addingTimeInterval(3_600)), 2)
        let fresh = account(observed: now.addingTimeInterval(3_601), percent: 80)
        XCTAssertEqual(fresh.rankingTier(at: now.addingTimeInterval(3_601)), 0)
        XCTAssertNotNil(fresh.urgency(at: now.addingTimeInterval(3_601)))
        XCTAssertEqual(fresh.rankingExpiresAt, now.addingTimeInterval(7_201))
        let snapshot = TokenBarWidgetSnapshot(generatedAt: now.addingTimeInterval(3_601), accounts: [old, fresh])
        XCTAssertEqual(snapshot.rankedAccounts(at: now.addingTimeInterval(3_601)).map(\.id), [fresh.id, old.id])
    }

    func testPastResetKeepsOnlyFrozenHistoricalRankingUntilGraceExpires() throws {
        var row = account(observed: now, percent: 80)
        row.urgencyWindow = QuotaUrgencyWindow(label: "每周", remainingPercent: 80,
            startsAt: now.addingTimeInterval(-604_740), resetsAt: now.addingTimeInterval(60))
        row.freshUntil = now.addingTimeInterval(60)
        let score = try XCTUnwrap(row.rankingUrgency(at: now.addingTimeInterval(120)))
        XCTAssertNil(row.urgency(at: now.addingTimeInterval(120)))
        XCTAssertEqual(row.rankingUrgency(at: now.addingTimeInterval(3_599)), score)
        XCTAssertNil(row.rankingUrgency(at: now.addingTimeInterval(3_600)))
    }

    private func account(observed: Date, percent: Double) -> TokenBarWidgetAccount {
        TokenBarWidgetAccount(id: UUID(), email: nil, provider: "Codex", plan: nil, status: .connected,
            observedAt: observed, freshUntil: observed.addingTimeInterval(120), metrics: [],
            urgencyWindow: QuotaUrgencyWindow(label: "每周", remainingPercent: percent,
                startsAt: observed.addingTimeInterval(-432_000), resetsAt: observed.addingTimeInterval(172_800)),
            rankingObservedAt: observed, rankingObservedAtPresent: true)
    }

    private func reading(source: Date?) -> AccountReading {
        AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: [QuotaWindow(id: "weekly", label: "每周", remainingPercent: 80,
                resetsAt: now.addingTimeInterval(172_800), startsAt: now.addingTimeInterval(-432_000))],
            sourceCollectedAt: source, sourceCollectedAtPresent: true)
    }

    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let account = AccountConfig(provider: .snapshot, name: "Unused", method: .snapshotFile, location: "/fixture/unused.json", serviceLabel: "Codex")
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-RankingGrace-\(UUID().uuidString)")
            suite = "TokenBar.RankingGraceTests." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        }
        @MainActor func store() -> AppStore { AppStore(directory: root, startTimers: false, defaults: defaults) }
        func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
}
