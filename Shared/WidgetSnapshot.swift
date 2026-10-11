import Foundation

public enum TokenBarWidgetConstants {
    public static let kind = "TokenBarQuotaWidget"
    public static let deepLink = URL(string: "tokenbar://dashboard")!
    public static let snapshotFilename = "widget-snapshot.json"
    public static let maximumBytes = 128 * 1_024
    public static let maximumAccounts = 30
    public static let maximumMetrics = 3
    public static let maximumResetCards = 1_000_000
}

public enum TokenBarWidgetStatus: String, Codable, Equatable, Sendable {
    case connected, stale, needsAuth, unavailable, notConfigured, unsupported

    public var title: String {
        switch self {
        case .connected: return "已连接"
        case .stale: return "待更新"
        case .needsAuth: return "需要登录"
        case .unavailable: return "暂时不可用"
        case .notConfigured: return "未接入"
        case .unsupported: return "暂无独立额度"
        }
    }
}

public struct TokenBarWidgetSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var accounts: [TokenBarWidgetAccount]

    public init(schemaVersion: Int = 1, generatedAt: Date, accounts: [TokenBarWidgetAccount]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    public func rankedAccounts(at now: Date) -> [TokenBarWidgetAccount] {
        accounts.enumerated().sorted { first, second in
            let left = first.element.urgency(at: now), right = second.element.urgency(at: now)
            if (left?.level.rank ?? -1) != (right?.level.rank ?? -1) { return (left?.level.rank ?? -1) > (right?.level.rank ?? -1) }
            if (left?.requiredDailyPercent ?? 0) != (right?.requiredDailyPercent ?? 0) { return (left?.requiredDailyPercent ?? 0) > (right?.requiredDailyPercent ?? 0) }
            if let left, let right, left.resetsAt != right.resetsAt { return left.resetsAt < right.resetsAt }
            return first.offset < second.offset
        }.map(\.element)
    }

    public func urgencyBoundaryDates(after: Date, before: Date) -> [Date] {
        let dates = accounts.flatMap { account -> [Date] in
            guard account.isFresh(at: after), let window = account.urgencyWindow, let until = account.freshUntil else { return [] }
            return QuotaUrgency.boundaryDates(window: window, after: after, before: before).filter { $0 <= until }
        }
        return Array(Set(dates)).sorted()
    }
}

public struct TokenBarWidgetAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var email: String?
    public var provider: String
    public var plan: String?
    public var status: TokenBarWidgetStatus
    public var observedAt: Date?
    public var freshUntil: Date?
    public var metrics: [TokenBarWidgetMetric]
    public var resetCards: Int? = nil
    public var urgencyWindow: QuotaUrgencyWindow? = nil

    public init(id: UUID, email: String?, provider: String, plan: String?, status: TokenBarWidgetStatus,
                observedAt: Date?, freshUntil: Date?, metrics: [TokenBarWidgetMetric], resetCards: Int? = nil,
                urgencyWindow: QuotaUrgencyWindow? = nil) {
        self.id = id
        self.email = email
        self.provider = provider
        self.plan = plan
        self.status = status
        self.observedAt = observedAt
        self.freshUntil = freshUntil
        self.metrics = metrics
        self.resetCards = resetCards
        self.urgencyWindow = urgencyWindow
    }

    public func urgency(at now: Date) -> QuotaUrgencyAssessment? {
        guard let urgencyWindow else { return nil }
        return QuotaUrgency.evaluate(window: urgencyWindow, at: now, isFresh: isFresh(at: now))
    }

    /// Keep reset cards independent and reserve the second visual slot for points.
    /// Old snapshots may still contain a reset-cards metric; do not repeat it.
    public func displayMetrics(limit: Int = 2) -> [TokenBarWidgetMetric] {
        let visible = metrics.filter { $0.id != "reset-cards" }
        guard limit > 0 else { return [] }
        guard limit > 1, let credits = visible.first(where: { $0.id == "credits" }),
              let quota = visible.first(where: { $0.id != "credits" }) else { return Array(visible.prefix(limit)) }
        let remainder = visible.filter { $0.id != quota.id && $0.id != credits.id }
        return Array(([quota, credits] + remainder).prefix(limit))
    }

    public func resetCardsLabel(at now: Date) -> String? {
        guard observedAt != nil, let resetCards, (0...TokenBarWidgetConstants.maximumResetCards).contains(resetCards) else { return nil }
        return (isFresh(at: now) ? "重置卡 " : "上次重置卡 ") + String(resetCards)
    }

    /// A host write cannot extend a provider observation's lifetime. The widget
    /// rechecks this at each timeline date, even if the host has stopped running.
    public func isFresh(at now: Date) -> Bool {
        guard status == .connected, let observedAt, let freshUntil,
              observedAt <= now.addingTimeInterval(60), freshUntil > now,
              freshUntil <= observedAt.addingTimeInterval(120) else { return false }
        return true
    }

    public func displayStatus(at now: Date) -> TokenBarWidgetStatus {
        status == .connected && !isFresh(at: now) ? .stale : status
    }
}

public struct TokenBarWidgetMetric: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var value: String
    public var remainingPercent: Double?
    public var resetsAt: Date? = nil

    public init(id: String, label: String, value: String, remainingPercent: Double?, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

public enum TokenBarWidgetSnapshotError: Error, Equatable {
    case unavailableContainer, invalidSnapshot, oversizedSnapshot, unavailableFile
}

/// Validation is shared by writer and reader. Shared data is a display schema,
/// never a second copy of credentials, provider responses or account configuration.
public extension TokenBarWidgetSnapshot {
    func validate() throws {
        guard schemaVersion == 1, Self.validDate(generatedAt), accounts.count <= TokenBarWidgetConstants.maximumAccounts,
              Set(accounts.map(\.id)).count == accounts.count else { throw TokenBarWidgetSnapshotError.invalidSnapshot }
        for account in accounts {
            guard Self.safeText(account.provider, maximum: 16),
                  account.plan.map({ Self.safeText($0, maximum: 80) }) ?? true,
                  account.email.map(Self.validEmail) ?? true,
                  account.observedAt.map(Self.validDate) ?? true,
                  account.freshUntil.map(Self.validDate) ?? true,
                  account.metrics.count <= TokenBarWidgetConstants.maximumMetrics,
                  account.resetCards.map({ (0...TokenBarWidgetConstants.maximumResetCards).contains($0) }) ?? true,
                  Set(account.metrics.map(\.id)).count == account.metrics.count else { throw TokenBarWidgetSnapshotError.invalidSnapshot }
            if let until = account.freshUntil {
                guard let observed = account.observedAt, until <= observed.addingTimeInterval(120) else { throw TokenBarWidgetSnapshotError.invalidSnapshot }
            }
            if account.status == .connected {
                guard account.observedAt != nil, account.freshUntil != nil else { throw TokenBarWidgetSnapshotError.invalidSnapshot }
            }
            if let window = account.urgencyWindow {
                guard window.hasValidCycle, Self.safeText(window.label, maximum: 80),
                      Self.validDate(window.startsAt), Self.validDate(window.resetsAt) else {
                    throw TokenBarWidgetSnapshotError.invalidSnapshot
                }
            }
            if account.observedAt == nil && (!account.metrics.isEmpty || account.resetCards != nil || account.urgencyWindow != nil) {
                throw TokenBarWidgetSnapshotError.invalidSnapshot
            }
            for metric in account.metrics {
                guard metric.id.range(of: "\\A[a-z0-9-]{1,64}\\z", options: .regularExpression) != nil,
                      Self.safeText(metric.label, maximum: 80), metric.value.count <= 64,
                      metric.resetsAt.map(Self.validDate) ?? true,
                      metric.value.range(of: "\\A(?:∞|不限量|—|[0-9]+(?:\\.[0-9]+)?(?:%| (?:tokens|requests|messages|credits|USD|张|点))?)\\z", options: .regularExpression) != nil,
                      metric.remainingPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true else { throw TokenBarWidgetSnapshotError.invalidSnapshot }
            }
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (1_577_836_800...4_102_444_800).contains(date.timeIntervalSince1970)
    }

    private static func safeText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum &&
        value.range(of: "\\A[\\p{L}\\p{N} .·%()（）_+…-]+\\z", options: .regularExpression) != nil &&
        value.range(of: "bearer|secret|eyJ|sk-", options: [.caseInsensitive, .regularExpression]) == nil
    }

    private static func validEmail(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 254 &&
        value.range(of: "\\A[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,63}\\z", options: .regularExpression) != nil
    }
}
