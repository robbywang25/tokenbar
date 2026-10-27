import Foundation
import CryptoKit

enum QuotaAccountFilter: String, Codable, CaseIterable {
    case all, favorites, attention
    var title: String { self == .all ? "全部" : self == .favorites ? "关注" : "需处理" }
}

struct QuotaInsightPreferences: Codable, Equatable {
    var favorites: Set<UUID> = []
    var filter: QuotaAccountFilter = .all
    var thresholds: [Int] = [20, 10]
    var expiryHours = 24
    var quietStart = 22
    var quietEnd = 8
    var passiveNotices = false

    func normalized() -> Self {
        var result = self
        result.favorites = Set(favorites.sorted { $0.uuidString < $1.uuidString }.prefix(1000))
        result.thresholds = Array(Set(thresholds.filter { (1...99).contains($0) }).sorted(by: >).prefix(5))
        if result.thresholds.isEmpty { result.thresholds = [20, 10] }
        if ![6, 12, 24, 48].contains(result.expiryHours) { result.expiryHours = 24 }
        if !(0...23).contains(result.quietStart) { result.quietStart = 22 }
        if !(0...23).contains(result.quietEnd) { result.quietEnd = 8 }
        return result
    }

    func isQuiet(at now: Date, timeZone: TimeZone) -> Bool {
        guard quietStart != quietEnd else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: now)
        return quietStart < quietEnd ? hour >= quietStart && hour < quietEnd : hour >= quietStart || hour < quietEnd
    }
}

struct QuotaInsightEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case low, reset, expiry, authentication }
    var id: String
    var accountID: UUID
    var identity: String
    var windowID: String?
    var kind: Kind
    var createdAt: Date
    var remaining: Double?
    var threshold: Int?
    var deadline: Date?
}

struct QuotaInsightState: Codable, Equatable {
    struct Observation: Codable, Equatable {
        var identity: String
        var status: ReadingStatus
        var resetAt: Date?
        var cycleAt: Date?
    }
    var seen: [String: Date] = [:]
    var previous: [String: Observation] = [:]
    var identities: [UUID: String] = [:]
    var sourceIdentities: [UUID: String] = [:]
    var verifiedEmails: [UUID: String] = [:]
    var events: [QuotaInsightEvent] = []
    var notified: Set<String> = []
    var readAt: Date? = nil

    func validate() throws {
        func hash(_ value: String) -> Bool { value.range(of: "\\A[a-f0-9]{64}\\z", options: .regularExpression) != nil }
        guard seen.count <= 4096, previous.count <= 2048, events.count <= 100, notified.count <= 100,
              identities.count <= 1000, sourceIdentities.count <= 1000, verifiedEmails.count <= 1000,
              identities.values.allSatisfy(hash), sourceIdentities.values.allSatisfy(hash), verifiedEmails.values.allSatisfy(hash),
              seen.allSatisfy({ hash($0.key) && ResetCalendarInstant.isValid($0.value) }),
              previous.allSatisfy({ $0.key.count <= 2048 && hash($0.value.identity) }),
              Set(events.map(\.id)).count == events.count,
              events.allSatisfy({ hash($0.id) && hash($0.identity) && ResetCalendarInstant.isValid($0.createdAt) && ($0.windowID?.count ?? 0) <= 256 && $0.deadline.map(ResetCalendarInstant.isValid) ?? true }),
              notified.isSubset(of: Set(events.map(\.id))) else { throw ProviderError.invalidData }
    }

    static func identity(_ account: AccountConfig, reading: AccountReading, fallback: String?) -> String {
        if let epoch = reading.resetHistoryIdentity { return digest(account.id.uuidString + "|" + epoch) }
        if let key = reading.identityKey { return digest(account.id.uuidString + "|" + key) }
        return fallback ?? digest(account.id.uuidString + "|" + AccountEmail.sourceSignature(account))
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    mutating func update(accounts: [AccountConfig], readings: [UUID: AccountReading], preferences: QuotaInsightPreferences, now: Date) {
        let cutoff = now.addingTimeInterval(-45 * 86_400)
        seen = seen.filter { $0.value >= cutoff && $0.value <= now.addingTimeInterval(60) }
        let activeIDs = Set(accounts.filter(\.enabled).map(\.id))
        identities = identities.filter { activeIDs.contains($0.key) }
        sourceIdentities = sourceIdentities.filter { activeIDs.contains($0.key) }
        verifiedEmails = verifiedEmails.filter { activeIDs.contains($0.key) }
        var next: [String: Observation] = [:]
        for account in accounts.prefix(1000) where account.enabled {
            guard let reading = readings[account.id] else { continue }
            let base = Self.identity(account, reading: reading, fallback: sourceIdentities[account.id])
            if let old = sourceIdentities[account.id], old != base { verifiedEmails.removeValue(forKey: account.id) }
            sourceIdentities[account.id] = base
            if let email = AccountEmail.validated(reading.email) { verifiedEmails[account.id] = Self.digest(email.lowercased()) }
            let who = Self.digest(base + "|" + (verifiedEmails[account.id] ?? "unknown"))
            identities[account.id] = who
            let authKey = account.id.uuidString + "/auth", oldAuth = previous[authKey]
            if reading.status == .needsAuth && (oldAuth?.identity != who || oldAuth?.status != .needsAuth) {
                emit(account, who, window: nil, kind: .authentication,
                     key: "auth|" + who + "|" + String(now.timeIntervalSince1970), now: now)
            }
            let authStatus: ReadingStatus = reading.status == .needsAuth ? .needsAuth : reading.isFresh(at: now) ? .connected : oldAuth?.identity == who && oldAuth?.status == .needsAuth ? .needsAuth : reading.status
            next[authKey] = Observation(identity: who, status: authStatus)
            guard reading.isFresh(at: now), let observed = reading.lastSuccessAt, observed <= now else {
                for (key, value) in previous where key.hasPrefix(account.id.uuidString + "/") && key != authKey && value.identity == who && next.count < 2048 { next[key] = value }
                continue
            }
            for window in reading.visibleWindows.prefix(16) where !window.unlimited && window.unit == "percent" {
                guard let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining),
                      window.resetsAt.map({ $0 > now }) ?? true else { continue }
                let key = account.id.uuidString + "/" + (QuotaWindowSemantics(window)?.selectionKey ?? window.id)
                let old = previous[key].flatMap { $0.identity == who ? $0 : nil }
                let reset = window.resetsAt
                let confirmed = old?.resetAt.map { previous in reset.map { previous <= now && $0 > previous && observed >= previous } ?? false } ?? false
                let cycle = confirmed || old == nil ? reset : old?.cycleAt
                if confirmed {
                    emit(account, who, window: window.id, kind: .reset,
                         key: "reset|" + who + "|" + key + "|" + String(reset!.timeIntervalSince1970), now: now, deadline: reset)
                }
                let cycleKey = cycle.map { String($0.timeIntervalSince1970) } ?? "unknown"
                var crossed: [(Int, String)] = []
                for threshold in preferences.thresholds {
                    let id = Self.digest("low|" + who + "|" + key + "|" + cycleKey + "|" + String(threshold))
                    if remaining > Double(threshold + 2) { seen.removeValue(forKey: id) }
                    else if remaining <= Double(threshold) && seen[id] == nil { crossed.append((threshold, id)) }
                }
                if let severe = crossed.min(by: { $0.0 < $1.0 }) {
                    events.append(QuotaInsightEvent(id: Self.digest(severe.1 + "|" + String(now.timeIntervalSince1970)), accountID: account.id, identity: who, windowID: window.id,
                        kind: .low, createdAt: now, remaining: remaining, threshold: severe.0, deadline: reset))
                    for (_, id) in crossed { seen[id] = now }
                }
                if next.count < 2048 { next[key] = Observation(identity: who, status: .connected, resetAt: reset, cycleAt: cycle) }
            }
            for card in Self.remindableCards(reading, now: now) {
                guard let expiry = card.expiresAt, expiry > now,
                      expiry.timeIntervalSince(now) <= Double(preferences.expiryHours) * 3600 else { continue }
                emit(account, who, window: nil, kind: .expiry,
                     key: "expiry|" + who + "|" + String(expiry.timeIntervalSince1970), now: now, deadline: expiry)
            }
        }
        previous = next
        events = Array(events.filter { activeIDs.contains($0.accountID) && identities[$0.accountID] == $0.identity && $0.createdAt >= cutoff }.suffix(100))
        let eventIDs = Set(events.map(\.id)); notified.formIntersection(eventIDs)
        if seen.count > 4096 { seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(4096).map { ($0.key, $0.value) }) }
    }

    static func remindableCards(_ reading: AccountReading, now: Date) -> [ResetCard] {
        let cards: [ResetCard], count: Int?
        if reading.resetCardsAvailable != nil || !reading.resetCards.isEmpty {
            cards = reading.resetCards
            count = ResetCardAvailability(reading: reading, at: now).availableCount
        } else if let report = reading.reportedResetCards, report.observationState(at: now) == .officialFresh {
            cards = report.cards; count = report.availability(at: now).availableCount
        } else { return [] }
        let known = cards.filter { $0.status == "available" && $0.expiresAt.map { $0 > now } == true }
            .sorted { $0.expiresAt! < $1.expiresAt! }
        return Array(known.prefix(max(0, count ?? known.count)))
    }

    func isActionable(_ event: QuotaInsightEvent, account: AccountConfig, reading: AccountReading,
                      preferences: QuotaInsightPreferences, now: Date) -> Bool {
        guard account.enabled else { return false }
        let base = Self.identity(account, reading: reading, fallback: sourceIdentities[account.id])
        let email = AccountEmail.validated(reading.email).map { Self.digest($0.lowercased()) }
            ?? (sourceIdentities[account.id] == base ? verifiedEmails[account.id] : nil)
        guard event.identity == Self.digest(base + "|" + (email ?? "unknown")) else { return false }
        if event.kind == .authentication { return reading.status == .needsAuth }
        guard reading.isFresh(at: now) else { return false }
        switch event.kind {
        case .low:
            guard let window = reading.visibleWindows.first(where: { $0.id == event.windowID }),
                  window.resetsAt == event.deadline, let remaining = window.remainingPercent,
                  let threshold = event.threshold, preferences.thresholds.contains(threshold) else { return false }
            return remaining <= Double(threshold)
        case .reset:
            return reading.visibleWindows.contains { $0.id == event.windowID && $0.resetsAt == event.deadline }
        case .expiry:
            guard let deadline = event.deadline, deadline > now,
                  deadline.timeIntervalSince(now) <= Double(preferences.expiryHours) * 3600 else { return false }
            return Self.remindableCards(reading, now: now).contains { $0.expiresAt == deadline }
        case .authentication: return false
        }
    }

    private mutating func emit(_ account: AccountConfig, _ who: String, window: String?, kind: QuotaInsightEvent.Kind,
                               key: String, now: Date, deadline: Date? = nil) {
        let id = Self.digest(key)
        guard seen[id] == nil else { return }
        seen[id] = now
        events.append(QuotaInsightEvent(id: id, accountID: account.id, identity: who, windowID: window, kind: kind,
            createdAt: now, remaining: nil, threshold: nil, deadline: deadline))
    }

    static func attentionReason(_ reading: AccountReading?, now: Date, threshold: Int) -> String? {
        guard let reading else { return "等待首次读取" }
        guard reading.isFresh(at: now) else { return reading.displayStatus(at: now).title }
        if reading.visibleWindows.contains(where: { !$0.unlimited && $0.remainingPercent.map { $0 <= Double(threshold) } == true }) { return "余量低于 \(threshold)%" }
        return nil
    }
}
