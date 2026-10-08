import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case codex, claude, grok, snapshot
    var id: String { rawValue }
    var title: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .grok: return "Grok Build"; case .snapshot: return "通用 JSON 数据源" }
    }
    var symbol: String {
        switch self { case .codex: return "terminal"; case .claude: return "sparkle"; case .grok: return "bolt"; case .snapshot: return "externaldrive" }
    }
    var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self { case .codex: return home + "/.codex/auth.json"; case .claude: return home + "/.claude/.credentials.json"; case .grok: return home + "/.grok/bin/grok"; case .snapshot: return "" }
    }
}

enum ConnectionMethod: String, Codable, CaseIterable, Identifiable {
    case localFile, keychain, grokCLI, snapshotFile, snapshotURL, snapshotSSH
    var id: String { rawValue }
}

struct AccountConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var provider: ProviderKind
    var name: String
    var method: ConnectionMethod
    var location: String
    var sourceAccountID: String = ""
    var enabled: Bool = true
    var sshHost: String? = nil
    var sshUseSudo: Bool? = nil
    var serviceLabel: String? = nil
    var displayService: String { serviceLabel ?? provider.title }
}

enum MenuMetricKind: String, Codable {
    case credits
}

struct ExpiryNotice: Identifiable, Equatable {
    let id: String
    let accountName: String
    let serviceLabel: String
    let windowLabel: String
    let remainingPercent: Double
    let resetsAt: Date
}

/// Labels only: remembered choices survive a failed quota read without retaining
/// a percentage that could be mistaken for a current balance.
struct MenuQuotaMetric: Codable, Identifiable, Equatable {
    var accountID: UUID
    var windowID: String
    var accountName: String
    var windowLabel: String
    var group: String
    // Optional for compatibility with preferences saved before credits selection.
    var kind: MenuMetricKind? = nil
    var id: String {
        kind == .credits ? accountID.uuidString + "#credits" : Self.selectionID(accountID: accountID, windowID: windowID)
    }

    static func selectionID(accountID: UUID, windowID: String) -> String {
        accountID.uuidString + "/" + windowID
    }
}

enum ReadingStatus: String, Codable {
    case connected, stale, needsAuth, unavailable, notConfigured, unsupported
    var title: String {
        switch self { case .connected: return "已连接"; case .stale: return "待更新"; case .needsAuth: return "需要登录"; case .unavailable: return "暂时不可用"; case .notConfigured: return "未接入"; case .unsupported: return "暂无独立额度" }
    }
}

struct QuotaWindow: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var remainingPercent: Double?
    var remaining: Double? = nil
    var limit: Double? = nil
    var unit: String = "percent"
    var resetsAt: Date? = nil
    var startsAt: Date? = nil
    var group: String = "default"
    var model: String? = nil
    var unlimited: Bool = false
    var title: String {
        let prefix = group == "reserve" ? "Reserve" : group == "code-review" ? "代码审查" : group == "additional" ? "附加" : ""
        return prefix.isEmpty ? label : "\(prefix) · \(label)"
    }
    var displayValue: String {
        if unlimited { return "不限量" }
        if let remainingPercent { return remainingPercent.formatted(.number.precision(.fractionLength(0...1))) + "%" }
        if let remaining { return remaining.formatted(.number.precision(.fractionLength(0...2))) + " " + unit }
        return "未提供"
    }
    func alert(at now: Date) -> String? {
        guard let start = startsAt, let reset = resetsAt, reset > now, let percent = remainingPercent else { return nil }
        let duration = reset.timeIntervalSince(start), elapsed = now.timeIntervalSince(start)
        guard duration >= 86400, elapsed >= min(86400, duration / 4), elapsed >= 0,
              100 - percent < elapsed / duration * 100 - 10 else { return nil }
        return reset.timeIntervalSince(now) <= 86400 && percent >= 20 ? "即将重置" : "使用偏慢"
    }
}

struct ResetCard: Codable, Equatable {
    var status: String
    var expiresAt: Date?
}

struct AccountReading: Codable, Equatable {
    var status: ReadingStatus
    var checkedAt: Date
    var lastSuccessAt: Date?
    var windows: [QuotaWindow] = []
    var credits: Double? = nil
    var unlimitedCredits: Bool = false
    var resetCardsAvailable: Int? = nil
    var resetCards: [ResetCard] = []
    var name: String? = nil
    var email: String? = nil
    var detail: String = ""
    // Hash only; used to reject duplicate identities. Never persist a credential.
    var identityKey: String? = nil

    func isFresh(at now: Date, maxAge: TimeInterval = 120) -> Bool {
        guard status == .connected, let success = lastSuccessAt,
              success <= now.addingTimeInterval(60), now.timeIntervalSince(success) <= maxAge else { return false }
        return !windows.contains { ($0.resetsAt ?? .distantFuture) <= now }
    }
    func displayStatus(at now: Date) -> ReadingStatus {
        status == .connected && !isFresh(at: now) ? .stale : status
    }
}

enum ProviderError: Error, Equatable {
    case needsAuth, unavailable, invalidData, invalidConfiguration, duplicate, unsupported
    var message: String {
        switch self {
        case .needsAuth: return "登录已失效或凭据不可用。请在官方客户端重新登录，再点刷新。"
        case .unavailable: return "暂时无法连接数据来源，请检查网络后重试。"
        case .invalidData: return "来源未返回可验证的额度数据。"
        case .invalidConfiguration: return "请检查数据源路径、账号 ID 或 HTTPS 地址。"
        case .duplicate: return "此账号已接入，不能作为第二份额度重复添加。"
        case .unsupported: return "此来源暂未提供可验证的独立额度。"
        }
    }
}
