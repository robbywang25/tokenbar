import Foundation
import CoreFoundation
import TokenBarWidgetShared

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

struct ServerTokenCatalogEntry: Equatable, Sendable {
    var id: String
    var providerKey: String
    var provider: String
    var product: String
    var label: String
    var serviceLabel: String
    var accountNumber: Int?
    var category: String
    var subscriptionState: String?
    var unsubscribed: Bool
    var defaultVisible: Bool
    var widgetPriority: TokenWidgetPriority
    var widgetEligible: Bool
    var calendarEligible: Bool
    var renewalEligible: Bool?
}

struct ServerTokenCatalog: Equatable, Sendable {
    var schemaVersion: Int
    var catalogVersion: Int
    var generatedAt: String?
    var entries: [ServerTokenCatalogEntry]

    static func parse(_ raw: Any?) -> ServerTokenCatalog? {
        guard let dict = raw as? [String: Any],
              let schema = integer(dict["schemaVersion"]), schema == 1,
              let catalogVersion = integer(dict["catalogVersion"]), catalogVersion >= 1,
              let rawEntries = dict["entries"] as? [[String: Any]],
              rawEntries.count <= 1_000 else { return nil }
        var entries: [ServerTokenCatalogEntry] = []
        for item in rawEntries {
            guard let id = item["id"] as? String, !id.isEmpty, id.count <= 120,
                  let providerKey = item["providerKey"] as? String,
                  let provider = item["provider"] as? String,
                  let product = item["product"] as? String,
                  let label = item["label"] as? String,
                  let serviceLabel = item["serviceLabel"] as? String,
                  let category = item["category"] as? String, ["coding", "chat", "api"].contains(category),
                  let rawPriority = item["widgetPriority"] as? String,
                  let priority = TokenWidgetPriority(rawValue: rawPriority),
                  let unsubscribed = bool(item["unsubscribed"]),
                  let defaultVisible = bool(item["defaultVisible"]),
                  let widgetEligible = bool(item["widgetEligible"]),
                  let calendarEligible = bool(item["calendarEligible"]) else { continue }
            entries.append(ServerTokenCatalogEntry(
                id: id, providerKey: providerKey, provider: provider, product: product,
                label: label, serviceLabel: serviceLabel, accountNumber: integer(item["accountNumber"]),
                category: category, subscriptionState: item["subscriptionState"] as? String,
                unsubscribed: unsubscribed, defaultVisible: defaultVisible,
                widgetPriority: priority, widgetEligible: widgetEligible,
                calendarEligible: calendarEligible, renewalEligible: bool(item["renewalEligible"])))
        }
        return ServerTokenCatalog(schemaVersion: schema, catalogVersion: catalogVersion,
                                  generatedAt: dict["generatedAt"] as? String, entries: entries)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
}

struct SnapshotCatalog {
    struct Entry {
        var id: String
        var serviceLabel: String
        var reading: AccountReading
        var displayOrder: AccountDisplayOrder? = nil

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
    var serverCatalog: ServerTokenCatalog? = nil

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
        let parsedServerCatalog = ServerTokenCatalog.parse(root["catalog"])
        let catalogByID = Dictionary((parsedServerCatalog?.entries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set<String>()
        var entries: [Entry] = []
        for row in rows {
            guard let id = row["id"] as? String, id.count <= 120,
                  id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:@+/-]*\\z", options: .regularExpression) != nil,
                  ids.insert(id).inserted else { throw ProviderError.invalidData }
            var document: [String: Any] = ["schemaVersion": 1, "accounts": [row]]
            if let timestamp = root["collectedAt"] { document["collectedAt"] = timestamp }
            var reading: AccountReading
            do {
                reading = try ProviderClient.parseSnapshot(JSONSerialization.data(withJSONObject: document),
                    sourceAccountID: id, source: source, at: now)
            } catch {
                // A broken balance must not erase healthy sibling accounts.
                reading = AccountReading(status: .unavailable, checkedAt: now, lastSuccessAt: nil,
                    detail: ProviderError.invalidData.message, reason: "invalid_data")
            }
            if let meta = catalogByID[id] {
                if reading.category == nil { reading.category = meta.category }
                if reading.unsubscribed == nil { reading.unsubscribed = meta.unsubscribed }
                if reading.widgetPriority == nil { reading.widgetPriority = meta.widgetPriority }
                if reading.calendarEligible == nil { reading.calendarEligible = meta.calendarEligible }
            }
            let label = serviceLabel(row, id: id)
            let key = AccountDisplayOrder.providerKey(product: row["product"] as? String, provider: row["provider"] as? String ?? label, sourceID: id)
            let displayOrder = AccountDisplayOrder.parse(row["displayOrder"], providerKey: key, sourceID: id)
            entries.append(Entry(id: id, serviceLabel: label, reading: reading, displayOrder: displayOrder))
        }
        return SnapshotCatalog(entries: entries, serverCatalog: parsedServerCatalog)
    }

    private static func serviceLabel(_ row: [String: Any], id: String) -> String {
        for field in ["serviceLabel", "provider", "product"] {
            if let label = row[field] as? String, (1...64).contains(label.count),
               label.range(of: "\\A[\\p{L}\\p{N} .·()_+/-]+\\z", options: .regularExpression) != nil {
                return label
            }
        }
        // Display fallback for older producers. This is not an account allowlist.
        if id == "antigravity" { return "Antigravity" }
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
        }, serverCatalog: serverCatalog ?? other.serverCatalog)
    }
}
