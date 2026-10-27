import Foundation
import TokenBarWidgetShared

/// Presentation-only adjustment. Source records remain unchanged for history
/// and synchronization; an aggregate without card details stays an aggregate.
struct ResetCardAvailability {
    struct Item: Identifiable {
        let index: Int
        let card: ResetCard
        var id: Int { index }
    }

    let availableCount: Int?
    let visibleCards: [Item]
    let pendingExpirations: [Date]

    init(reading: AccountReading, at now: Date) {
        self.init(reportedCount: reading.resetCardsAvailable, cards: reading.resetCards, at: now)
    }

    init(reportedCount: Int?, cards: [ResetCard], at now: Date) {
        let availableExpirations = cards.compactMap { card -> Date? in
            guard card.status == "available", let expiry = card.expiresAt, TokenBarResetCardCount.validExpiration(expiry) else { return nil }
            return expiry
        }
        availableCount = TokenBarResetCardCount.available(reportedCount: reportedCount,
                                                         knownAvailableExpirations: availableExpirations, at: now)
        // The widget gets the count adjusted at publication plus only future
        // deductions. Already expired records can never be subtracted twice.
        pendingExpirations = Array(availableExpirations.filter { $0 > now }.sorted().prefix(availableCount ?? 0))
        visibleCards = cards.enumerated().compactMap { index, card in
            guard card.status != "expired" else { return nil }
            if let expiry = card.expiresAt, TokenBarResetCardCount.validExpiration(expiry), expiry <= now { return nil }
            return Item(index: index, card: card)
        }
    }

}
