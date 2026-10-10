import Foundation

enum SubscriptionPlanLabel {
    /// Matches Tokens' current Codex display contract. The original plan name
    /// remains in AccountReading; numeric tier labels are never treated as prices.
    static func displayName(planName: String?, multiplier: Int?, isCodex: Bool) -> String? {
        guard let planName, !planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard isCodex else { return planName }

        let supported: [Int]
        let confirmedFallback: Int?
        switch planName {
        case "ChatGPT Pro 100": supported = [5, 10]; confirmedFallback = nil
        case "ChatGPT Pro 200": supported = [10, 20]; confirmedFallback = nil
        case "ChatGPT Pro 500": supported = [25]; confirmedFallback = 25
        default: supported = []; confirmedFallback = nil
        }
        let observed = multiplier.flatMap { supported.contains($0) ? $0 : nil }
        let display = (observed ?? confirmedFallback).map { "ChatGPT Pro \($0)x" } ?? planName
        let prefix = "ChatGPT "
        return display.hasPrefix(prefix) ? String(display.dropFirst(prefix.count)) : display
    }
}
