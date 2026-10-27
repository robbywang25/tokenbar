import Foundation

struct UsageMetric: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var value: Double
    var unit: String
    var startsAt: Date
    var endsAt: Date
    var observedAt: Date

    var displayValue: String { value.formatted(.number.precision(.fractionLength(0))) + " " + unit }

    static func parse(_ raw: Any?, checkedAt: Date, lastSuccessAt: Date?) -> [Self]? {
        guard let rows = raw as? [[String: Any]], rows.count <= 20, let success = lastSuccessAt else { return nil }
        var ids = Set<String>(), result: [Self] = []
        for row in rows {
            guard let id = row["id"] as? String, id.range(of: "\\A[A-Za-z0-9_-]{1,64}\\z", options: .regularExpression) != nil,
                  ids.insert(id).inserted, let label = row["label"] as? String, (1...64).contains(label.count),
                  label.rangeOfCharacter(from: .controlCharacters) == nil,
                  let value = QuotaUsageTrend.number(row["value"]), value >= 0, value <= 9_007_199_254_740_991, value.rounded() == value,
                  let unit = row["unit"] as? String, ["requests", "tokens"].contains(unit),
                  let start = QuotaUsageTrend.instant(row["startsAt"]), let end = QuotaUsageTrend.instant(row["endsAt"]),
                  let observed = QuotaUsageTrend.instant(row["observedAt"]), start < end,
                  end <= observed.addingTimeInterval(60), observed <= min(checkedAt, success).addingTimeInterval(60) else { return nil }
            result.append(Self(id: id, label: label, value: value, unit: unit, startsAt: start, endsAt: end, observedAt: observed))
        }
        return result
    }
}
