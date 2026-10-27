import Foundation

enum SyncJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([SyncJSON]), object([String: SyncJSON])
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([SyncJSON].self) { self = .array(value) }
        else { self = .object(try box.decode([String: SyncJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        }
    }
    var object: [String: SyncJSON]? { if case .object(let value) = self { return value }; return nil }
    var array: [SyncJSON]? { if case .array(let value) = self { return value }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    subscript(_ key: String) -> SyncJSON? { object?[key] }
    static func encode<T: Encodable>(_ value: T) throws -> SyncJSON {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        return try JSONDecoder().decode(SyncJSON.self, from: encoder.encode(value))
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}

struct GodSyncDocument: Codable, Equatable {
    var schemaVersion = 1
    var revision = 0
    var updatedAt: String?
    var records: [String: SyncJSON] = [:]
    func validate() throws {
        guard schemaVersion == 1, revision >= 0, records.count <= 5000,
              records.allSatisfy({ key, value in
                  (key.hasPrefix("a:") || key.hasPrefix("h:") || key.hasPrefix("p:") || key.hasPrefix("s:")) && key.count <= 256 &&
                    (value == .null || value.object != nil)
              }) else { throw GodError.invalidResponse }
    }
}
struct GodSyncOperation: Codable, Equatable { var key: String; var value: SyncJSON }
struct GodSyncPatch: Codable { var baseRevision: Int; var operations: [GodSyncOperation] }

/// Persisted queue of only locally changed records. A 409 rebases this queue
/// onto the latest revision, never uploading an entire stale device snapshot.
struct GodSyncJournal: Codable {
    var remote = GodSyncDocument()
    var baseline: [String: SyncJSON] = [:]
    var pending: [String: SyncJSON] = [:]
    var initialized = false

    mutating func capture(_ values: [String: SyncJSON], switches: Bool) {
        guard initialized else { return }
        for (key, value) in values where switches || !key.hasPrefix("s:") {
            if baseline[key] != value { pending[key] = value }
        }
        // Removing a local connection is a data edit. God catalog visibility
        // lives in the optional switch records, not account/history deletion.
        for key in baseline.keys where values[key] == nil && key.hasPrefix("a:local:") { pending[key] = .null }
        baseline = values
        if !switches { pending = pending.filter { !$0.key.hasPrefix("s:") } }
    }
    mutating func rebase(_ document: GodSyncDocument, switches: Bool) {
        remote = document
        if !switches { pending = pending.filter { !$0.key.hasPrefix("s:") } }
        for (key, value) in pending where key.hasPrefix("a:") {
            guard var local = value.object, let latest = document.records[key],
                  let oldAt = local["reading"]?["lastSuccessAt"]?.number,
                  let newAt = latest["reading"]?["lastSuccessAt"]?.number, newAt > oldAt else { continue }
            local["reading"] = latest["reading"]; pending[key] = .object(local)
        }
        for (key, value) in pending where key.hasPrefix("h:") {
            let accountKey = "a:" + String(key.dropFirst(2))
            if let account = pending[accountKey] ?? document.records[accountKey], let raw = account["reading"],
               let reading = try? GodSyncProjection.decodeReading(raw), let currentEpoch = GodSyncProjection.epoch(reading),
               let oldEpoch = value["epoch"]?.string, currentEpoch != oldEpoch {
                pending.removeValue(forKey: key); continue
            }
            if let old = document.records[key] { pending[key] = Self.mergeHistory(local: value, remote: old) }
        }
    }
    func patch() -> GodSyncPatch {
        GodSyncPatch(baseRevision: remote.revision, operations: pending.keys.sorted().prefix(200).map { GodSyncOperation(key: $0, value: pending[$0]!) })
    }
    mutating func acknowledge(_ patch: GodSyncPatch, document: GodSyncDocument) {
        remote = document
        for operation in patch.operations where pending[operation.key] == operation.value { pending.removeValue(forKey: operation.key) }
    }
    static func mergeHistory(local: SyncJSON, remote: SyncJSON) -> SyncJSON {
        guard var own = local.object, let other = remote.object,
              own["kind"] == .string("history"), other["kind"] == .string("history"),
              own["epoch"] == other["epoch"], own["emailDigest"] == other["emailDigest"],
              let a = own["events"]?.array, let b = other["events"]?.array else { return local }
        var unique: [String: SyncJSON] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for item in b + a {
            let identity = SyncJSON.array([item["id"] ?? .null, item["group"] ?? .null, item["model"] ?? .null, item["resetsAt"] ?? .null])
            if let bytes = try? encoder.encode(identity) { unique[bytes.base64EncodedString()] = item }
        }
        own["events"] = .array(unique.values.sorted {
            let first = $0["resetsAt"]?.number ?? 0, second = $1["resetsAt"]?.number ?? 0
            if first != second { return first < second }
            let a = [$0["id"]?.string ?? "", $0["group"]?.string ?? "", $0["model"]?.string ?? ""].joined(separator: "\n")
            let b = [$1["id"]?.string ?? "", $1["group"]?.string ?? "", $1["model"]?.string ?? ""].joined(separator: "\n")
            return a < b
        })
        return .object(own)
    }
}

enum GodSyncProjection {
    static func reading(_ reading: AccountReading) throws -> SyncJSON {
        // Trends are fetched from the authoritative source on each device.
        // Do not expand the deployed strict sync schema or repeatedly upload history.
        var portable = reading
        portable.product = nil
        portable.usageMetrics = nil
        portable.reportedResetCards = nil
        portable.resetCards = portable.resetCards.map { ResetCard(status: $0.status, expiresAt: $0.expiresAt) }
        if ["no_usage_data", "unsupported_client"].contains(portable.reason) { portable.reason = nil }
        portable.windows = portable.windows.map { window in
            var window = window; window.usageTrend = nil; return window
        }
        var object = try SyncJSON.encode(portable).object!
        for field in ["name", "detail", "resetHistory"] { object.removeValue(forKey: field) }
        return .object(object)
    }
    static func decodeReading(_ value: SyncJSON) throws -> AccountReading {
        guard var object = value.object else { throw GodError.invalidResponse }
        object["detail"] = .string("")
        if object["windows"] == nil { object["windows"] = .array([]) }
        if object["unlimitedCredits"] == nil { object["unlimitedCredits"] = .bool(false) }
        if object["resetCards"] == nil { object["resetCards"] = .array([]) }
        return try SyncJSON.object(object).decode(AccountReading.self)
    }
    static func record(account: AccountConfig, key: String, reading: AccountReading?) throws -> SyncJSON {
        var value: [String: SyncJSON] = ["kind": .string("account"), "accountID": .string(key),
            "source": .string(key.hasPrefix("god:") ? "god" : "local"), "provider": .string(account.provider.rawValue), "serviceLabel": .string(account.displayService)]
        if !account.sourceAccountID.isEmpty { value["sourceAccountID"] = .string(account.sourceAccountID) }
        if let reading { value["reading"] = try Self.reading(reading) }
        return .object(value)
    }
    static func epoch(_ reading: AccountReading?) -> String? {
        if let epoch = reading?.resetHistoryIdentity { return epoch }
        guard let identity = reading?.identityKey, identity.count == 64 else { return nil }
        let hex = Array(identity.prefix(32)); let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return groups.map { String(hex[$0]) }.joined(separator: "-")
    }
    static func portableAccount(_ record: SyncJSON) throws -> SyncJSON {
        guard let key = record["accountID"]?.string, let raw = record["reading"], raw != .null else { throw GodError.invalidResponse }
        let reading = try decodeReading(raw)
        var result: [String: SyncJSON] = ["id": .string(key), "status": .string("stale"),
            "profile": .object(["email": reading.email.map(SyncJSON.string) ?? .null]),
            "subscription": .object(["planName": reading.planName.map(SyncJSON.string) ?? .null,
                                      "planMultiplier": reading.planMultiplier.map { .number(Double($0)) } ?? .null]),
            "identity": .object(["provider": .string("synced"), "accountID": .string(key)]),
            "windows": .array(try reading.windows.map { window in
                var value = try SyncJSON.encode(window).object!; value["quotaGroup"] = value.removeValue(forKey: "group"); return .object(value)
            })]
        if let service = record["serviceLabel"] { result["serviceLabel"] = service }
        result["checkedAt"] = .number(reading.checkedAt.timeIntervalSince1970)
        result["lastSuccessAt"] = reading.lastSuccessAt.map { .number($0.timeIntervalSince1970) } ?? .null
        result["sourceCollectedAt"] = result["lastSuccessAt"]
        if let epoch = reading.resetHistoryIdentity { result["resetHistoryIdentity"] = .string(epoch) }
        result["credits"] = .object(["remaining": reading.credits.map(SyncJSON.number) ?? .null, "unlimited": .bool(reading.unlimitedCredits)])
        if let count = reading.resetCardsAvailable {
            result["resetCredits"] = .object(["available": .number(Double(count)), "cards": try SyncJSON.encode(reading.resetCards)])
        }
        return .object(result)
    }
}
