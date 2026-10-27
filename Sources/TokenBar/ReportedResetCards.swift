import Foundation
import TokenBarWidgetShared

/// An independently dated observation, never a native balance. Official-web
/// observations and the owner's dated notes preserve their own provenance.
struct ReportedResetCards: Codable, Equatable {
    enum Provenance: String, Codable {
        case officialWeb = "official-web"
        case ownerConfirmed = "owner-confirmed"
    }

    enum ObservationState: Equatable {
        case officialFresh, officialHistorical, officialUnknown, ownerConfirmed
    }

    var available: Int
    var detailsAt: Date?
    var provenance: Provenance
    var cards: [ResetCard]

    func observationState(at now: Date) -> ObservationState {
        if provenance == .ownerConfirmed { return .ownerConfirmed }
        guard let detailsAt, TokenBarResetCardCount.validExpiration(detailsAt), detailsAt <= now else { return .officialUnknown }
        return now.timeIntervalSince(detailsAt) > 300 ? .officialHistorical : .officialFresh
    }

    func sourceLabel(at now: Date) -> String {
        switch observationState(at: now) {
        case .officialFresh: return "官网核验"
        case .officialHistorical: return "官网上次记录"
        case .officialUnknown: return "官网记录 · 核验时间未知"
        case .ownerConfirmed: return "本人确认 · 待自动核验"
        }
    }

    func availability(at now: Date) -> ResetCardAvailability {
        ResetCardAvailability(reportedCount: available, cards: cards, at: now)
    }

    static func forDisplay(reading: AccountReading) -> Self? {
        guard reading.resetCardsAvailable == nil, reading.resetCards.isEmpty else { return nil }
        return reading.reportedResetCards
    }

    static func parse(_ raw: Any?) -> Self? {
        guard let value = raw as? [String: Any],
              let amount = QuotaUsageTrend.number(value["available"]), amount.rounded() == amount,
              amount >= 0, amount <= Double(TokenBarWidgetConstants.maximumResetCards),
              let source = value["provenance"] as? String, let provenance = Provenance(rawValue: source) else { return nil }
        func optionalInstant(_ raw: Any?) -> (valid: Bool, date: Date?) {
            if raw == nil || raw is NSNull { return (true, nil) }
            guard let date = QuotaUsageTrend.instant(raw) else { return (false, nil) }
            return (true, date)
        }
        let observed = optionalInstant(value["detailsAt"])
        guard observed.valid else { return nil }
        let rows: [[String: Any]]
        if let rawCards = value["cards"], !(rawCards is NSNull) {
            guard let list = rawCards as? [[String: Any]], list.count <= 100 else { return nil }
            rows = list
        } else { rows = [] }
        var cards: [ResetCard] = []
        for row in rows {
            guard let status = row["status"] as? String,
                  ["available", "redeemed", "expired", "redeeming", "unknown"].contains(status) else { return nil }
            let expires = optionalInstant(row["expiresAt"]), starts = optionalInstant(row["startsAt"]), granted = optionalInstant(row["grantedAt"])
            guard expires.valid, starts.valid, granted.valid else { return nil }
            var resetType: String?
            if let rawType = row["resetType"], !(rawType is NSNull) {
                guard let type = rawType as? String, ["full", "five_hour", "weekly"].contains(type) else { return nil }
                resetType = type
            }
            cards.append(ResetCard(status: status, expiresAt: expires.date, startsAt: starts.date,
                                   grantedAt: granted.date, resetType: resetType))
        }
        return Self(available: Int(amount), detailsAt: observed.date, provenance: provenance, cards: cards)
    }
}

extension ResetCard {
    var displayTitle: String {
        switch resetType {
        case "full": return "完整重置卡"
        case "five_hour": return "5 小时重置卡"
        case "weekly": return "每周重置卡"
        default: return "重置卡"
        }
    }
}
