import Foundation

/// Display-only quota geometry. Points, unlimited and unobserved values do not
/// have a denominator and must never become an empty or full percentage meter.
public struct TokenBarWidgetQuotaProgress: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case healthy, warning, low, historical }

    public static let segmentCount = 10
    public let remainingPercent: Double
    public let tone: Tone

    public init?(metric: TokenBarWidgetMetric, account: TokenBarWidgetAccount, at date: Date) {
        guard account.observedAt != nil, metric.id != "credits", metric.id != "reset-cards",
              metric.value != "—", metric.value != "∞", metric.value != "不限量",
              let percent = metric.remainingPercent, percent.isFinite, (0...100).contains(percent) else { return nil }
        remainingPercent = percent
        tone = account.isFresh(at: date) ? (percent >= 50 ? .healthy : percent >= 20 ? .warning : .low) : .historical
    }

    /// Each cell represents ten percentage points, including a proportional
    /// last cell. Zero stays empty; 99% never looks completely full.
    public func fill(in segment: Int) -> Double {
        guard (0..<Self.segmentCount).contains(segment) else { return 0 }
        return min(1, max(0, remainingPercent / 10 - Double(segment)))
    }
}
