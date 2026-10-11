import Foundation

/// A declared quota cycle, not an estimate of the user's actual future usage.
public struct QuotaUrgencyWindow: Codable, Equatable, Sendable {
    public var label: String
    public var remainingPercent: Double
    public var startsAt: Date
    public var resetsAt: Date

    public init(label: String, remainingPercent: Double, startsAt: Date, resetsAt: Date) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.startsAt = startsAt
        self.resetsAt = resetsAt
    }

    public var cycleSeconds: TimeInterval { resetsAt.timeIntervalSince(startsAt) }

    public var hasValidCycle: Bool {
        remainingPercent.isFinite && (0...100).contains(remainingPercent) &&
        startsAt.timeIntervalSince1970.isFinite && resetsAt.timeIntervalSince1970.isFinite &&
        cycleSeconds.isFinite && (1...(366 * 86_400)).contains(cycleSeconds)
    }
}

public enum QuotaUrgencyLevel: String, Codable, Equatable, Sendable {
    case normal, priority, urgent

    public var rank: Int {
        switch self { case .normal: return 0; case .priority: return 1; case .urgent: return 2 }
    }

    public var title: String {
        switch self { case .normal: return "正常"; case .priority: return "优先"; case .urgent: return "紧急" }
    }
}

public struct QuotaUrgencyAssessment: Equatable, Sendable {
    public let requiredDailyPercent: Double
    public let normalDailyPercent: Double
    public let paceRatio: Double
    public let resetsAt: Date
    public let level: QuotaUrgencyLevel

    public init(requiredDailyPercent: Double, normalDailyPercent: Double, paceRatio: Double,
                resetsAt: Date, level: QuotaUrgencyLevel) {
        self.requiredDailyPercent = requiredDailyPercent
        self.normalDailyPercent = normalDailyPercent
        self.paceRatio = paceRatio
        self.resetsAt = resetsAt
        self.level = level
    }
}

/// Foundation-only rules shared by macOS and iOS. Callers must exclude Reserve,
/// unlimited and non-primary groups before supplying declared default windows.
public enum QuotaUrgency {
    public static func evaluate(window: QuotaUrgencyWindow, at now: Date, isFresh: Bool) -> QuotaUrgencyAssessment? {
        guard isFresh, window.hasValidCycle, window.remainingPercent > 0,
              now.timeIntervalSince1970.isFinite, window.startsAt <= now, window.resetsAt > now else { return nil }
        let remainingSeconds = window.resetsAt.timeIntervalSince(now)
        guard remainingSeconds.isFinite, remainingSeconds > 0 else { return nil }
        let required = window.remainingPercent * 86_400 / remainingSeconds
        let normal = 100 * 86_400 / window.cycleSeconds
        let ratio = (window.remainingPercent / 100) * window.cycleSeconds / remainingSeconds
        guard required.isFinite, normal.isFinite, ratio.isFinite else { return nil }
        let level: QuotaUrgencyLevel = ratio >= 2 ? .urgent : ratio >= 1.5 ? .priority : .normal
        return QuotaUrgencyAssessment(requiredDailyPercent: required, normalDailyPercent: normal,
                                      paceRatio: ratio, resetsAt: window.resetsAt, level: level)
    }

    /// Pick the longest valid declared cycle first, including a zero remainder.
    /// An exhausted weekly pool must not silently fall back to a short pool.
    public static func primaryWindow(from windows: [QuotaUrgencyWindow], at now: Date, isFresh: Bool) -> QuotaUrgencyWindow? {
        guard isFresh, now.timeIntervalSince1970.isFinite else { return nil }
        return windows.enumerated().filter { _, window in
            window.hasValidCycle && window.startsAt <= now && window.resetsAt > now
        }.sorted { first, second in
            let lhs = first.element, rhs = second.element
            if lhs.cycleSeconds != rhs.cycleSeconds { return lhs.cycleSeconds > rhs.cycleSeconds }
            let left = evaluate(window: lhs, at: now, isFresh: true)
            let right = evaluate(window: rhs, at: now, isFresh: true)
            if (left?.level.rank ?? -1) != (right?.level.rank ?? -1) { return (left?.level.rank ?? -1) > (right?.level.rank ?? -1) }
            if (left?.requiredDailyPercent ?? 0) != (right?.requiredDailyPercent ?? 0) { return (left?.requiredDailyPercent ?? 0) > (right?.requiredDailyPercent ?? 0) }
            if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
            return first.offset < second.offset
        }.first?.element
    }

    public static func boundaryDates(window: QuotaUrgencyWindow, after: Date, before: Date) -> [Date] {
        guard before > after, evaluate(window: window, at: after, isFresh: true) != nil else { return [] }
        let remainingCycleSeconds = (window.remainingPercent / 100) * window.cycleSeconds
        let thresholds = [1.5, 2.0].map { ratio -> Date in
            let boundary = window.resetsAt.addingTimeInterval(-remainingCycleSeconds / ratio)
            // The first representable instant after the mathematical threshold
            // avoids showing the old level because Date rounded a fraction down.
            return Date(timeIntervalSinceReferenceDate: boundary.timeIntervalSinceReferenceDate.nextUp)
        }
        return Array(Set(thresholds + [window.resetsAt])).filter { $0 > after && $0 < before }.sorted()
    }
}
