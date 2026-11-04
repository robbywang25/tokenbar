import Foundation
import CoreFoundation

/// Versioned display metadata shared with the Tokens account API.
/// Weights affect presentation only; they never change identity or freshness.
public struct AccountDisplayOrder: Codable, Equatable, Sendable {
    public var version: Int
    public var providerKey: String
    public var providerWeight: Int
    public var accountWeight: Int

    public init(version: Int = 1, providerKey: String, providerWeight: Int, accountWeight: Int) {
        self.version = version
        self.providerKey = providerKey
        self.providerWeight = providerWeight
        self.accountWeight = accountWeight
    }

    public static let providerWeights = ["openai": 100, "anthropic": 200, "xai": 300,
        "cursor": 400, "today": 500, "google": 600, "other": 900]
    private static let accountWeights = ["codex-1": 100, "codex-2": 200,
        "chatgpt-dots": 300, "chatgpt-chat": 400, "claude-1": 100, "claude-2": 200,
        "grok": 100, "grok-bot": 200, "cursor": 100, "today-cn": 100, "today-global": 200,
        "gemini-web": 100, "gemini-web-2": 200, "gemini-cli": 300, "gemini-cli-2": 400,
        "gemini-api": 500, "gemini-api-2": 600]

    public var isValid: Bool {
        version == 1 && Self.providerWeights[providerKey] != nil &&
            (0...1_000_000).contains(providerWeight) && (0...1_000_000).contains(accountWeight)
    }

    public static func sourceID(_ value: String) -> String {
        value.hasPrefix("god:") ? String(value.dropFirst(4)) : value
    }

    public static func providerKey(product: String? = nil, provider: String? = nil, sourceID: String = "") -> String {
        let product = product?.lowercased() ?? "", provider = provider?.lowercased() ?? ""
        if ["gemini-cli", "gemini-web", "gemini-api"].contains(product) || ["google", "gemini", "gemini cli", "gemini web", "gemini api", "antigravity cli"].contains(provider) { return "google" }
        if ["today-cn", "today-global"].contains(product) || provider.hasPrefix("todayai") { return "today" }
        if product == "cursor" || provider == "cursor" { return "cursor" }
        if product == "claude" || ["anthropic", "claude", "claude code"].contains(provider) { return "anthropic" }
        if ["grok", "grok-bot"].contains(product) || ["xai", "x.ai", "grok", "grok build", "grok bot"].contains(provider) { return "xai" }
        if ["codex", "chatgpt-dots", "chatgpt-chat"].contains(product) || ["openai", "codex", "chatgpt", "openai codex"].contains(provider) { return "openai" }
        // Older local snapshot producers may supply only their stable slot ID.
        let id = Self.sourceID(sourceID)
        if id == "codex" || id.hasPrefix("codex-") || id.hasPrefix("chatgpt-") { return "openai" }
        if id == "claude" || id.hasPrefix("claude-") { return "anthropic" }
        if id == "grok" || id.hasPrefix("grok-") { return "xai" }
        if id == "cursor" || id.hasPrefix("cursor-") { return "cursor" }
        if id.hasPrefix("today-") { return "today" }
        if id.hasPrefix("gemini-") { return "google" }
        return "other"
    }

    public static func fallback(providerKey: String, sourceID: String) -> Self {
        let key = providerWeights[providerKey] == nil ? "other" : providerKey
        return Self(providerKey: key, providerWeight: providerWeights[key]!, accountWeight: accountWeights[Self.sourceID(sourceID)] ?? 10_000)
    }

    public func resolved(providerKey: String, sourceID: String) -> Self {
        isValid && self.providerKey == providerKey ? self : Self.fallback(providerKey: providerKey, sourceID: sourceID)
    }

    public static func parse(_ value: Any?, providerKey: String, sourceID: String) -> Self {
        func integer(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  (0...1_000_000).contains(n.doubleValue) else { return nil }
            return n.intValue
        }
        guard let raw = value as? [String: Any], let version = integer(raw["version"]),
              let key = raw["providerKey"] as? String,
              let providerWeight = integer(raw["providerWeight"]), let accountWeight = integer(raw["accountWeight"]) else {
            return fallback(providerKey: providerKey, sourceID: sourceID)
        }
        return Self(version: version, providerKey: key, providerWeight: providerWeight, accountWeight: accountWeight)
            .resolved(providerKey: providerKey, sourceID: sourceID)
    }

    /// Group first so inconsistent metadata can never split one supplier.
    public static func sorted<T>(_ values: [T], order: (T) -> Self, stableID: (T) -> String) -> [T] {
        let entries = values.enumerated().map { (index: $0.offset, value: $0.element, order: order($0.element), id: stableID($0.element)) }
        let groups = Dictionary(grouping: entries, by: { $0.order.providerKey })
        let weights = groups.mapValues { entries -> Int in
            let candidates = Set(entries.map { $0.order.providerWeight })
            return candidates.count == 1 ? candidates.first! : providerWeights[entries[0].order.providerKey] ?? 900
        }
        func less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
        let keys = groups.keys.sorted { weights[$0] != weights[$1] ? weights[$0]! < weights[$1]! : less($0, $1) }
        return keys.flatMap { key in
            groups[key]!.sorted {
                if $0.order.accountWeight != $1.order.accountWeight { return $0.order.accountWeight < $1.order.accountWeight }
                if $0.id != $1.id { return less($0.id, $1.id) }
                // Locally configured sources without a logical ID retain their
                // persisted relative order rather than depending on random UUIDs.
                return $0.index < $1.index
            }.map(\.value)
        }
    }
}
