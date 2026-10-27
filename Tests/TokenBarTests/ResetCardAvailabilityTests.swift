import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class ResetCardAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testAggregateSubtractsOnlyKnownExpiredAvailableCardsAtExactBoundary() {
        let reading = makeReading(count: 6, cards: [
            ResetCard(status: "available", expiresAt: now.addingTimeInterval(-1)),
            ResetCard(status: "available", expiresAt: now),
            ResetCard(status: "available", expiresAt: now.addingTimeInterval(1)),
            ResetCard(status: "available", expiresAt: nil),
            ResetCard(status: "redeemed", expiresAt: now.addingTimeInterval(-1)),
            ResetCard(status: "expired", expiresAt: now.addingTimeInterval(-1))
        ])
        XCTAssertEqual(ResetCardAvailability(reading: reading, at: now.addingTimeInterval(-0.5)).availableCount, 5)
        XCTAssertEqual(ResetCardAvailability(reading: reading, at: now).availableCount, 4)
        XCTAssertEqual(ResetCardAvailability(reading: reading, at: now.addingTimeInterval(1)).availableCount, 3)
        XCTAssertEqual(reading.resetCardsAvailable, 6)
        XCTAssertEqual(reading.resetCards.count, 6, "Display deductions cannot delete source history or alter sync data.")
    }

    func testMissingOrPartialDetailsDoNotReplaceTheObservedAggregate() {
        XCTAssertEqual(ResetCardAvailability(reading: makeReading(count: 7), at: now).availableCount, 7)
        let unknownExpiry = ResetCard(status: "available", expiresAt: nil)
        XCTAssertEqual(ResetCardAvailability(reading: makeReading(count: 7, cards: [unknownExpiry]), at: now).availableCount, 7)
        XCTAssertNil(ResetCardAvailability(reading: makeReading(count: nil, cards: [unknownExpiry]), at: now).availableCount)
        let excessiveExpiredDetails = Array(repeating: ResetCard(status: "available", expiresAt: now), count: 4)
        XCTAssertEqual(ResetCardAvailability(reading: makeReading(count: 2, cards: excessiveExpiredDetails), at: now).availableCount, 0)
        for count in [-1, TokenBarWidgetConstants.maximumResetCards + 1, Int.max] {
            XCTAssertNil(ResetCardAvailability(reading: makeReading(count: count), at: now).availableCount)
        }
    }

    func testDetailsHideExpiredCardsAndPreserveOriginalNumbersAndUnknownDates() {
        let reading = makeReading(count: 4, cards: [
            ResetCard(status: "expired", expiresAt: nil),
            ResetCard(status: "available", expiresAt: now),
            ResetCard(status: "redeemed", expiresAt: now),
            ResetCard(status: "redeeming", expiresAt: now.addingTimeInterval(60)),
            ResetCard(status: "available", expiresAt: nil),
            ResetCard(status: "unknown", expiresAt: .distantFuture)
        ])
        let view = ResetCardAvailability(reading: reading, at: now)
        XCTAssertEqual(view.visibleCards.map(\.index), [3, 4, 5])
        XCTAssertEqual(view.availableCount, 3)
        XCTAssertTrue(view.pendingExpirations.isEmpty)
        XCTAssertEqual(reading.resetCards.map(\.status), ["expired", "available", "redeemed", "redeeming", "available", "unknown"])
    }

    func testInvalidExpiryIsUnknownAndAStaleReadingStillLosesKnownExpiredCards() {
        let invalid = [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan), Date.distantPast]
        let cards = invalid.map { ResetCard(status: "available", expiresAt: $0) }
        XCTAssertEqual(ResetCardAvailability(reading: makeReading(count: 3, cards: cards), at: now).availableCount, 3)
        XCTAssertEqual(ResetCardAvailability(reading: makeReading(count: 3, cards: cards), at: now).visibleCards.count, 3)
        var stale = makeReading(count: 3, cards: [ResetCard(status: "available", expiresAt: now)])
        stale.status = .stale
        stale.lastSuccessAt = now.addingTimeInterval(-300)
        XCTAssertEqual(ResetCardAvailability(reading: stale, at: now).availableCount, 2)
        XCTAssertEqual(stale.status, .stale)
    }

    @MainActor
    func testWidgetExpiresCardsWithoutHostRefreshAndNeverDeductsAnOldExpiryTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-CardAvailability-\(UUID().uuidString)")
        let suite = "TokenBar.CardAvailability." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root, startTimers: false, defaults: defaults)
        let account = AccountConfig(provider: .snapshot, name: "Synthetic", method: .snapshotFile,
                                    location: "/fixture/unused.json", serviceLabel: "Codex")
        store.accounts = [account]
        let nextExpiry = now.addingTimeInterval(60)
        store.readings[account.id] = makeReading(count: 5, cards: [
            ResetCard(status: "available", expiresAt: now.addingTimeInterval(-1)),
            ResetCard(status: "available", expiresAt: nextExpiry),
            ResetCard(status: "available", expiresAt: nextExpiry),
            ResetCard(status: "available", expiresAt: nil)
        ])
        let snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        let decoded = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        let row = try XCTUnwrap(decoded.accounts.first)
        XCTAssertEqual(row.resetCards, 4)
        XCTAssertEqual(row.resetCardExpirations, [nextExpiry, nextExpiry])
        XCTAssertEqual(row.resetCardsLabel(at: now), "重置卡 4")
        XCTAssertEqual(row.resetCardsLabel(at: nextExpiry.addingTimeInterval(-0.001)), "重置卡 4")
        XCTAssertEqual(row.resetCardsLabel(at: nextExpiry), "重置卡 2")
        XCTAssertEqual(row.resetCardsLabel(at: now.addingTimeInterval(300)), "上次重置卡 2")
        XCTAssertEqual(decoded.resetCardBoundaryDates(after: now), [nextExpiry])
        XCTAssertEqual(decoded.resetCardBoundaryDates(after: nextExpiry), [])

        let republished = try XCTUnwrap(store.widgetSnapshot(at: now.addingTimeInterval(90)))
        try republished.validate()
        XCTAssertEqual(republished.accounts[0].resetCards, 2)
        XCTAssertNil(republished.accounts[0].resetCardExpirations)
        XCTAssertEqual(republished.accounts[0].resetCardsLabel(at: now.addingTimeInterval(90)), "重置卡 2")
        XCTAssertEqual(store.readings[account.id]?.resetCardsAvailable, 5)
    }

    func testLegacyWidgetWithoutExpirationsRetainsAggregateAndRejectsBadNewMetadata() throws {
        let row = TokenBarWidgetAccount(id: UUID(), email: nil, provider: "Codex", plan: nil, status: .connected,
            observedAt: now, freshUntil: now.addingTimeInterval(120), metrics: [], resetCards: 4)
        var snapshot = TokenBarWidgetSnapshot(generatedAt: now, accounts: [row])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("resetCardExpirations"))
        let restored = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: data)
        try restored.validate()
        XCTAssertEqual(restored.accounts[0].resetCardsLabel(at: now.addingTimeInterval(300)), "上次重置卡 4")
        XCTAssertEqual(restored.resetCardBoundaryDates(after: now), [])

        for expirations in [[now], [.distantFuture], Array(repeating: now.addingTimeInterval(60), count: 5)] {
            snapshot.accounts[0].resetCardExpirations = expirations
            XCTAssertThrowsError(try snapshot.validate())
        }
        snapshot.accounts[0].resetCardExpirations = [now.addingTimeInterval(60)]
        snapshot.accounts[0].resetCards = nil
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.accounts[0].resetCards = 101
        snapshot.accounts[0].resetCardExpirations = Array(repeating: now.addingTimeInterval(60), count: 101)
        XCTAssertThrowsError(try snapshot.validate())
    }

    private func makeReading(count: Int?, cards: [ResetCard] = []) -> AccountReading {
        AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
                       resetCardsAvailable: count, resetCards: cards)
    }
}
