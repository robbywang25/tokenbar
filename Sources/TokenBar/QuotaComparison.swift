import Foundation

/// Stable window semantics, independent of account name, balance and cycle dates.
/// A matching label alone cannot make two quota windows comparable.
struct QuotaWindowSemantics: Codable, Equatable, Hashable {
    let id: String
    let group: String
    let model: String?
    let unit: String
    let label: String

    init?(_ window: QuotaWindow) {
        guard window.isVisibleInUI, !window.unlimited, window.unit == "percent",
              !window.id.lowercased().contains("reserve"), !window.id.isEmpty else { return nil }
        id = window.id
        group = window.group
        model = window.model
        unit = window.unit
        label = window.label.filter { !$0.isWhitespace }.lowercased().precomposedStringWithCanonicalMapping
    }

    var selectionKey: String {
        // The JSON array preserves field boundaries even when labels contain separators.
        let values = [id, group, model ?? "", unit, label]
        return String(data: (try? JSONEncoder().encode(values)) ?? Data(), encoding: .utf8) ?? ""
    }
}

struct QuotaAnalysisRow: Identifiable {
    let account: AccountConfig
    let reading: AccountReading
    let window: QuotaWindow
    let accountLabel: String
    let product: String?
    let semantics: QuotaWindowSemantics

    init?(account: AccountConfig, reading: AccountReading, window: QuotaWindow, accountLabel: String, product: String?) {
        guard let semantics = QuotaWindowSemantics(window),
              reading.windows.filter({ $0.id == window.id }).count == 1 else { return nil }
        self.account = account
        self.reading = reading
        self.window = window
        self.accountLabel = accountLabel
        self.product = product
        self.semantics = semantics
    }

    var id: String { account.id.uuidString + "/" + semantics.selectionKey }
    var displayWindowTitle: String {
        guard let model = window.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return window.title }
        return window.title + " · " + model
    }

    func resetMarkers(in events: [ResetCalendarEvent], from: Date, to: Date, now: Date) -> [Date] {
        let matching = events.filter { event in
            event.id.accountID == account.id && event.id.windowID == window.id &&
                event.id.group == window.group && event.id.model == window.model &&
                event.status == .expired && event.resetsAt <= now &&
                event.resetsAt >= from && event.resetsAt <= to
        }.map(\.resetsAt)
        return Array(Set(matching)).sorted().suffix(32).map { $0 }
    }

    func isComparable(to other: Self) -> Bool {
        guard account.id != other.account.id,
              let product, !product.isEmpty, product == other.product,
              semantics == other.semantics else { return false }
        // Two configured rows that point to one verified identity are not two accounts.
        if let identity = reading.identityKey, identity == other.reading.identityKey { return false }
        return true
    }

    func trend(for range: QuotaHistoryRange) -> QuotaUsageTrend? {
        guard let trend = window.usageTrend, trend.range == range else { return nil }
        return trend
    }

    func summary(for range: QuotaHistoryRange, now: Date) -> QuotaRecapSummary {
        guard let trend = trend(for: range) else { return .missing }
        let analysis = trend.analysis(window: window, reading: reading, now: now)
        guard analysis.status != "unavailable" else { return .missing }
        return QuotaRecapSummary(used: analysis.used, coverageSeconds: trend.coverageSeconds,
            coveragePercent: analysis.coveragePercent, observedAt: analysis.points.last?.at,
            status: analysis.status)
    }
}

struct QuotaRecapSummary: Equatable {
    var used: Double?
    var coverageSeconds: Double?
    var coveragePercent: Double?
    var observedAt: Date?
    var status: String
    static let missing = Self(used: nil, coverageSeconds: nil, coveragePercent: nil, observedAt: nil, status: "unavailable")
}

enum QuotaRecapCSV {
    static func make(rows: [QuotaAnalysisRow], range: QuotaHistoryRange, now: Date) -> String {
        var cells: [[String]] = [["账号", "产品", "额度窗口", "时段", "已观测消耗", "单位", "有效记录秒数", "覆盖百分比", "最近采样", "状态"]]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for row in rows {
            let value = row.summary(for: range, now: now)
            cells.append([row.accountLabel, row.product ?? "", row.displayWindowTitle, range.title,
                decimal(value.used), "个百分点", decimal(value.coverageSeconds), decimal(value.coveragePercent),
                value.observedAt.map(formatter.string) ?? "", statusLabel(value.status)])
        }
        return "\u{FEFF}" + cells.map { $0.map(escaped).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func escaped(_ value: String) -> String {
        let first = value.drop { $0.isWhitespace || $0 == "\u{FEFF}" }.first
        let protected = first.map { "=+@-".contains($0) } == true ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "ready": return "已观测"
        case "stale": return "历史记录"
        case "collecting": return "积累中"
        default: return "未提供"
        }
    }

    private static func decimal(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        let text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        return text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}

/// Preferences are local to the active AppStore profile and contain only IDs.
struct QuotaAnalysisSelection: Codable, Equatable {
    var accountID: String = ""
    var windowKey: String = ""
    var comparisonID: String = ""
    static let defaultsKey = "quotaAnalysisSelection.v1"

    static func load(from preferences: UserDefaults) -> Self? {
        guard let data = preferences.data(forKey: defaultsKey), data.count <= 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.accountID.isEmpty || UUID(uuidString: value.accountID) != nil,
              value.comparisonID.isEmpty || UUID(uuidString: value.comparisonID) != nil,
              value.windowKey.count <= 2_048 else { return nil }
        return value
    }

    func save(to preferences: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self), data.count <= 16_384 else { return }
        preferences.set(data, forKey: Self.defaultsKey)
    }

    func selected(in rows: [QuotaAnalysisRow]) -> QuotaAnalysisRow? {
        rows.first { $0.account.id.uuidString == accountID && $0.semantics.selectionKey == windowKey }
    }
}
