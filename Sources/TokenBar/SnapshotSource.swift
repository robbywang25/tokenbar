import Foundation
import CoreFoundation

struct SnapshotSource: Codable, Identifiable, Equatable {
    var connection: AccountConfig
    var discoversAccounts = true
    var excludedAccountIDs: Set<String> = []
    var id: UUID { connection.id }

    func owns(_ account: AccountConfig) -> Bool {
        if let sourceID = account.snapshotSourceID { return sourceID == id }
        // Legacy file/SSH connections can be adopted without changing their
        // UUID, menu choices or history. URLs may use different credentials.
        guard account.provider == .snapshot, account.method == connection.method,
              account.method != .snapshotURL else { return false }
        return Self.locationKey(account) == Self.locationKey(connection)
    }

    static func locationKey(_ config: AccountConfig) -> String {
        switch config.method {
        case .snapshotFile:
            return URL(fileURLWithPath: NSString(string: config.location).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
        case .snapshotSSH:
            return (config.sshHost ?? "") + "\n" + config.location + "\n" + (config.sshUseSudo == true ? "sudo" : "user")
        default: return config.location
        }
    }
}

struct SnapshotCatalog {
    struct Entry {
        var id: String
        var serviceLabel: String
        var reading: AccountReading

        var shouldDiscover: Bool {
            // Empty slots and unsupported products aren't accounts. An existing
            // account is retained even if its source later becomes unavailable.
            if reading.status == .notConfigured || reading.status == .unsupported {
                return reading.email != nil || reading.lastSuccessAt != nil || !reading.windows.isEmpty ||
                    reading.credits != nil || reading.unlimitedCredits || reading.resetCardsAvailable != nil
            }
            return reading.reason != "invalid_data"
        }
    }
    var entries: [Entry]

    static func parse(_ data: Data, source: String, at now: Date) throws -> SnapshotCatalog {
        guard data.count <= ProviderClient.maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidData
        }
        if let version = root["schemaVersion"] {
            guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 1 else { throw ProviderError.invalidData }
        }
        guard let primary = root["accounts"] as? [[String: Any]] else { throw ProviderError.invalidData }
        let additional: [[String: Any]]
        if let value = root["additionalAccounts"] {
            guard let rows = value as? [[String: Any]] else { throw ProviderError.invalidData }
            additional = rows
        } else { additional = [] }
        let rows = primary + additional
        guard rows.count <= 1_000 else { throw ProviderError.invalidData }
        var ids = Set<String>()
        var entries: [Entry] = []
        for row in rows {
            guard let id = row["id"] as? String, id.count <= 120,
                  id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:@+/-]*\\z", options: .regularExpression) != nil,
                  ids.insert(id).inserted else { throw ProviderError.invalidData }
            var document: [String: Any] = ["schemaVersion": 1, "accounts": [row]]
            if let timestamp = root["collectedAt"] { document["collectedAt"] = timestamp }
            let reading: AccountReading
            do {
                reading = try ProviderClient.parseSnapshot(JSONSerialization.data(withJSONObject: document),
                    sourceAccountID: id, source: source, at: now)
            } catch {
                // A broken balance must not erase healthy sibling accounts.
                reading = AccountReading(status: .unavailable, checkedAt: now, lastSuccessAt: nil,
                    detail: ProviderError.invalidData.message, reason: "invalid_data")
            }
            entries.append(Entry(id: id, serviceLabel: serviceLabel(row, id: id), reading: reading))
        }
        return SnapshotCatalog(entries: entries)
    }

    private static func serviceLabel(_ row: [String: Any], id: String) -> String {
        for field in ["serviceLabel", "provider", "product"] {
            if let label = row[field] as? String, (1...64).contains(label.count),
               label.range(of: "\\A[\\p{L}\\p{N} .·()_+/-]+\\z", options: .regularExpression) != nil {
                return label
            }
        }
        // Display fallback for older producers. This is not an account allowlist.
        if id == "codex" || id.hasPrefix("codex-") { return "Codex" }
        if id == "claude" || id.hasPrefix("claude-") { return "Claude Code" }
        if id == "grok-bot" { return "Grok Bot" }
        if id == "grok" || id.hasPrefix("grok-build") { return "Grok Build" }
        if id == "cursor" || id.hasPrefix("cursor-") { return "Cursor" }
        return String(id.prefix(64))
    }
}

extension SnapshotCatalog {
    /// Optional ranged history must belong to the same verified account epoch
    /// and exact quota definition. It never changes balances or source freshness.
    func mergingHistory(_ other: SnapshotCatalog, range: QuotaHistoryRange) -> SnapshotCatalog {
        let byID = Dictionary(other.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SnapshotCatalog(entries: entries.map { entry in
            var result = entry
            guard let candidate = byID[entry.id], let epoch = entry.reading.resetHistoryIdentity,
                  epoch == candidate.reading.resetHistoryIdentity,
                  entry.reading.product == candidate.reading.product,
                  entry.reading.email == candidate.reading.email,
                  entry.reading.lastSuccessAt == candidate.reading.lastSuccessAt else { return result }
            result.reading.windows = result.reading.windows.map { window in
                guard let match = candidate.reading.windows.first(where: { $0.id == window.id }),
                      match.group == window.group, match.model == window.model, match.unit == window.unit,
                      match.label == window.label, match.startsAt == window.startsAt, match.resetsAt == window.resetsAt,
                      match.remainingPercent == window.remainingPercent, match.unlimited == window.unlimited,
                      match.usageTrend?.range == range else { return window }
                var window = window; window.usageTrend = match.usageTrend; return window
            }
            return result
        })
    }
}
