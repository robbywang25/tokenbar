import Foundation
import CoreFoundation

enum QuotaHistoryRange: String, Codable, CaseIterable, Identifiable {
    case hour = "1h", day = "24h", week = "7d"
    var id: String { rawValue }
    var title: String { self == .hour ? "1 小时" : self == .day ? "24 小时" : "7 天" }
    var duration: TimeInterval { self == .hour ? 3_600 : self == .day ? 86_400 : 604_800 }
    var godPath: String { self == .hour ? "/quotas" : "/quotas?range=" + rawValue }
}

struct QuotaBalancePoint: Codable, Equatable {
    var at: Date
    var remaining: Double
    var connect: Bool
}

/// Bounded, optional source history. Invalid history cannot reject a valid quota.
struct QuotaUsageTrend: Codable, Equatable {
    var status: String
    var from: Date
    var to: Date
    var bucketSeconds: Double
    var balancePoints: [QuotaBalancePoint]
    var totalUsed: Double?
    var coverageSeconds: Double
    var observedAt: Date?

    var range: QuotaHistoryRange? { QuotaHistoryRange.allCases.first { $0.duration == to.timeIntervalSince(from) } }

    var rangeLabel: String {
        to.timeIntervalSince(from) == 86_400 ? "近24小时" : to.timeIntervalSince(from) == 604_800 ? "近7天" : "近1小时"
    }

    static func parse(_ raw: Any?) -> Self? {
        guard let value = raw as? [String: Any], value["metric"] as? String == "quota",
              value["unit"] as? String == "percentage-points",
              let status = value["status"] as? String, ["ready", "stale", "collecting", "unavailable"].contains(status),
              let from = instant(value["from"]), let to = instant(value["to"]),
              let bucket = number(value["bucketSeconds"]),
              [(3_600.0, 300.0), (86_400, 3_600), (604_800, 21_600)].contains(where: { to.timeIntervalSince(from) == $0.0 && bucket == $0.1 }),
              let coverage = number(value["coverageSeconds"]), coverage >= 0, coverage <= to.timeIntervalSince(from),
              let rows = value["balancePoints"] as? [[String: Any]], rows.count <= 512 else { return nil }
        var points: [QuotaBalancePoint] = []
        for row in rows {
            guard let at = instant(row["at"]), at >= from, at <= to,
                  points.last.map({ at > $0.at }) ?? true,
                  let remaining = number(row["remaining"]), (0...100).contains(remaining),
                  let connectNumber = row["connect"] as? NSNumber,
                  CFGetTypeID(connectNumber) == CFBooleanGetTypeID() else { return nil }
            let connected = points.last.map { connectNumber.boolValue && remaining <= $0.remaining } ?? false
            points.append(QuotaBalancePoint(at: at, remaining: remaining, connect: connected))
        }
        var used: Double?
        if let rawUsed = value["totalUsed"], !(rawUsed is NSNull) {
            guard let amount = number(rawUsed), amount >= 0, amount <= 9_007_199_254_740_991 else { return nil }
            used = coverage > 0 ? amount : nil
        }
        var observed: Date?
        if let rawObserved = value["observedAt"], !(rawObserved is NSNull) {
            guard let at = instant(rawObserved), at <= to else { return nil }
            observed = at
        }
        return Self(status: status, from: from, to: to, bucketSeconds: bucket,
                    balancePoints: points, totalUsed: used, coverageSeconds: coverage, observedAt: observed)
    }

    static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    static func instant(_ raw: Any?) -> Date? {
        guard let text = raw as? String, text.count <= 40,
              text.range(of: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\\z", options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: text) ?? {
            formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: text)
        }()
        guard let date, date.timeIntervalSince1970 >= 1_577_836_800, date.timeIntervalSince1970 < 4_102_444_800 else { return nil }
        // Foundation normalizes invalid calendar days; round-trip the local components.
        let components = String(text.prefix(19))
        let strict = DateFormatter(); strict.locale = Locale(identifier: "en_US_POSIX")
        strict.calendar = Calendar(identifier: .gregorian); strict.timeZone = TimeZone(secondsFromGMT: 0)
        strict.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; strict.isLenient = false
        guard let local = strict.date(from: components), strict.string(from: local) == components else { return nil }
        if !text.hasSuffix("Z") {
            let suffix = text.suffix(6)
            guard let hours = Int(suffix.dropFirst().prefix(2)), let minutes = Int(suffix.suffix(2)),
                  hours <= 14, minutes < 60, hours != 14 || minutes == 0 else { return nil }
        }
        return date
    }

    func analysis(window: QuotaWindow, reading: AccountReading, now: Date) -> QuotaUsageAnalysis {
        let pace = QuotaUsageAnalysis.cyclePace(window: window, reading: reading, now: now)
        guard [.connected, .stale].contains(reading.status), status != "unavailable",
              window.isVisibleInUI, !window.unlimited, window.unit == "percent",
              to <= now.addingTimeInterval(60), balancePoints.allSatisfy({ $0.at <= now.addingTimeInterval(60) }) else {
            return QuotaUsageAnalysis(status: "unavailable", points: [], used: nil, coveragePercent: 0, forecast: nil, pace: pace)
        }
        let stale = status == "stale" || !reading.isFresh(at: now) ||
            observedAt.map { now.timeIntervalSince($0) > 120 || $0 > now.addingTimeInterval(60) } ?? true ||
            balancePoints.last.map { now.timeIntervalSince($0.at) > 120 } ?? true
        var result = QuotaUsageAnalysis(status: stale ? "stale" : status, points: balancePoints,
            used: coverageSeconds > 0 ? totalUsed : nil,
            coveragePercent: min(100, coverageSeconds / to.timeIntervalSince(from) * 100), forecast: nil, pace: pace)
        guard !stale, status == "ready", coverageSeconds >= 600,
              let observed = observedAt, observed <= now.addingTimeInterval(1),
              let success = reading.lastSuccessAt, abs(success.timeIntervalSince(observed)) <= 1,
              let last = balancePoints.last, abs(last.at.timeIntervalSince(observed)) <= 1,
              let remaining = window.remainingPercent, remaining > 0, abs(remaining - last.remaining) <= 0.01,
              window.startsAt.map({ $0 <= now }) ?? true,
              window.resetsAt.map({ $0 > now }) ?? true else { return result }
        var segment: [QuotaBalancePoint] = []
        for point in balancePoints where point.at >= now.addingTimeInterval(-1_800) {
            if let previous = segment.last, !point.connect || point.at.timeIntervalSince(previous.at) > 180 || point.remaining > previous.remaining { segment = [] }
            segment.append(point)
        }
        guard segment.count >= 5, let first = segment.first, let end = segment.last,
              end.at.timeIntervalSince(first.at) >= 600, first.remaining - end.remaining >= 0.5 else { return result }
        let rate = (first.remaining - end.remaining) / end.at.timeIntervalSince(first.at) * 3_600
        let runsOut = observed.addingTimeInterval(remaining / rate * 3_600)
        let minutes = runsOut.timeIntervalSince(now) / 60
        guard minutes.isFinite, minutes > 0, minutes <= 7 * 24 * 60 else { return result }
        result.forecast = QuotaForecast(minutesLeft: minutes, burnPerHour: rate, beforeReset: window.resetsAt.map { runsOut < $0 })
        return result
    }
}

struct QuotaForecast: Equatable {
    var minutesLeft: Double
    var burnPerHour: Double
    var beforeReset: Bool?
}

struct QuotaCyclePace: Equatable {
    var status: String
    var usedPercent: Double
    var elapsedPercent: Double
}

struct QuotaUsageAnalysis: Equatable {
    var status: String
    var points: [QuotaBalancePoint]
    var used: Double?
    var coveragePercent: Double
    var forecast: QuotaForecast?
    var pace: QuotaCyclePace?

    static func cyclePace(window: QuotaWindow, reading: AccountReading, now: Date) -> QuotaCyclePace? {
        guard reading.isFresh(at: now), window.isVisibleInUI, !window.unlimited, window.unit == "percent",
              let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining),
              let start = window.startsAt, let end = window.resetsAt, let observed = reading.lastSuccessAt,
              start < observed, observed < end, observed <= now, end > now else { return nil }
        let elapsed = observed.timeIntervalSince(start) / end.timeIntervalSince(start) * 100
        guard observed.timeIntervalSince(start) >= 600, elapsed >= 3 else { return nil }
        let used = 100 - remaining, difference = used - elapsed
        return QuotaCyclePace(status: difference > 5 ? "ahead" : difference < -5 ? "behind" : "on_pace", usedPercent: used, elapsedPercent: elapsed)
    }
}
