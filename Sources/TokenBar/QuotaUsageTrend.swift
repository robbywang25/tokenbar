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
        // Every accepted spelling is ASCII and at most 35 bytes. Validate the
        // fixed grammar directly: constructing formatters for each of thousands
        // of history points blocks the native UI, and shared mutable formatters
        // would be unsafe when independent sources parse concurrently.
        guard let text = raw as? String, (20...35).contains(text.utf8.count) else { return nil }
        let bytes = Array(text.utf8)
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58 else { return nil }
        func digits(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = digits(0, 4), (2019...2100).contains(year),
              let month = digits(5, 2), (1...12).contains(month),
              let day = digits(8, 2), day >= 1,
              let hour = digits(11, 2), hour <= 23,
              let minute = digits(14, 2), minute <= 59,
              let second = digits(17, 2), second <= 59 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let maximumDay: Int
        switch month {
        case 2: maximumDay = leap ? 29 : 28
        case 4, 6, 9, 11: maximumDay = 30
        default: maximumDay = 31
        }
        guard day <= maximumDay else { return nil }

        var cursor = 19, fractionalDigits = 0, fractionalValue = 0, scale = 1
        if bytes[cursor] == 46 {
            cursor += 1
            while cursor < bytes.count, (48...57).contains(bytes[cursor]) {
                fractionalDigits += 1
                guard fractionalDigits <= 9 else { return nil }
                fractionalValue = fractionalValue * 10 + Int(bytes[cursor]) - 48
                scale *= 10; cursor += 1
            }
            guard fractionalDigits > 0 else { return nil }
        }
        guard cursor < bytes.count else { return nil }
        let offset: Int
        if bytes[cursor] == 90 {
            guard cursor + 1 == bytes.count else { return nil }
            offset = 0
        } else {
            guard bytes.count - cursor == 6, bytes[cursor] == 43 || bytes[cursor] == 45,
                  bytes[cursor + 3] == 58,
                  let zoneHours = digits(cursor + 1, 2), zoneHours <= 14,
                  let zoneMinutes = digits(cursor + 4, 2), zoneMinutes <= 59,
                  zoneHours != 14 || zoneMinutes == 0 else { return nil }
            offset = (bytes[cursor] == 45 ? -1 : 1) * (zoneHours * 3_600 + zoneMinutes * 60)
        }

        // Gregorian civil-date arithmetic, with March as month zero so leap
        // days are accounted for at the end of each year. The accepted UTC
        // range and ±14h offsets can only involve local years 2019...2100.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let marchMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * marchMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let daysSinceEpoch = era * 146_097 + dayOfEra - 719_468
        let wholeSeconds = daysSinceEpoch * 86_400 + hour * 3_600 + minute * 60 + second - offset
        guard wholeSeconds >= 1_577_836_800, wholeSeconds < 4_102_444_800 else { return nil }
        let instant = Double(wholeSeconds) + Double(fractionalValue) / Double(scale)
        // Date uses Double seconds. A valid sub-microsecond instant immediately
        // before 2100 must not round outside the exclusive upper bound.
        return Date(timeIntervalSince1970: min(instant, Double(4_102_444_800).nextDown))
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
