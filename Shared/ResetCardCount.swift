import Foundation

/// Card expiry is a display-time deduction from an observed aggregate, never a
/// replacement for it. Missing individual records do not imply a zero balance.
public enum TokenBarResetCardCount {
    public static func available(reportedCount: Int?, knownAvailableExpirations: [Date], at now: Date) -> Int? {
        guard let reportedCount, (0...TokenBarWidgetConstants.maximumResetCards).contains(reportedCount) else { return nil }
        let expired = knownAvailableExpirations.filter { validExpiration($0) && $0 <= now }.count
        return max(0, reportedCount - expired)
    }

    public static func validExpiration(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (1_577_836_800...4_102_444_800).contains(date.timeIntervalSince1970)
    }
}
