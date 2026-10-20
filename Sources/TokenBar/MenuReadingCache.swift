import Foundation

/// Only a menu-bar fallback. Never feeds quota freshness, widgets or alerts.
struct MenuReadingCache: Codable, Equatable {
    var sourceSignature: String
    var reading: AccountReading

    static func accepts(_ reading: AccountReading, at now: Date) -> Bool {
        guard [.connected, .stale].contains(reading.status), !blocksFallback(reading),
              let observed = reading.lastSuccessAt, observed.timeIntervalSince1970.isFinite,
              observed.timeIntervalSince1970 >= 1_577_836_800, observed <= now.addingTimeInterval(60) else { return false }
        return reading.visibleWindows.contains { window in
            guard let value = window.remainingPercent else { return false }
            return value.isFinite && (0...100).contains(value)
        } || reading.unlimitedCredits || (reading.credits.map { $0.isFinite && $0 >= 0 } ?? false)
    }

    static func blocksFallback(_ reading: AccountReading) -> Bool {
        reading.reason == "invalid_data" || reading.reason == "duplicate" ||
            reading.status == .notConfigured || reading.status == .unsupported
    }

    func matches(_ account: AccountConfig, current: AccountReading?) -> Bool {
        guard sourceSignature == AccountEmail.sourceSignature(account) else { return false }
        guard let current else { return true }
        guard !Self.blocksFallback(current) else { return false }
        if let old = reading.identityKey, let new = current.identityKey, old != new { return false }
        if let old = AccountEmail.validated(reading.email), let new = AccountEmail.validated(current.email), old != new { return false }
        if let old = reading.resetHistoryIdentity, let new = current.resetHistoryIdentity, old != new { return false }
        return true
    }

    init(account: AccountConfig, reading: AccountReading) {
        sourceSignature = AccountEmail.sourceSignature(account)
        self.reading = reading
        self.reading.windows = reading.visibleWindows.filter { $0.remainingPercent != nil }
        self.reading.resetHistory = nil
        self.reading.resetCards = []
        self.reading.resetCardsAvailable = nil
        self.reading.name = nil
        self.reading.detail = ""
    }
}
