import Foundation
import TokenBarWidgetShared

extension AppStore {
    /// An explicit display projection. Never pass account configuration or raw
    /// provider responses to the widget's shared container.
    func widgetSnapshot(at date: Date = Date()) -> TokenBarWidgetSnapshot? {
        guard !isDemo else { return nil }
        // Resolve the initial default once. Rebuilding the full metric catalog
        // for each window makes a 30-account projection unnecessarily quadratic.
        let selection = selectedMenuMetricIDs
        let selected = Set(availableMenuMetrics.filter { selection.contains($0.id) }.map(\.accountID))
        let enabled = accounts.filter(\.enabled)
        let ordered = enabled.filter { selected.contains($0.id) } + enabled.filter { !selected.contains($0.id) }
        let rows = ordered.prefix(TokenBarWidgetConstants.maximumAccounts).map { account in
            widgetAccount(account, at: date, selection: selection)
        }
        return TokenBarWidgetSnapshot(generatedAt: date, accounts: rows)
    }

    private func widgetAccount(_ account: AccountConfig, at date: Date, selection: Set<String>) -> TokenBarWidgetAccount {
        let reading = readings[account.id]
        let observed = reading?.lastSuccessAt.flatMap { value in
            Self.widgetDate(value) && value <= date.addingTimeInterval(60) ? value : nil
        }
        let rankingObserved: Date? = {
            guard let reading, let observed else { return nil }
            if reading.sourceCollectedAtPresent == true || reading.sourceCollectedAt != nil {
                guard let source = reading.sourceCollectedAt, Self.widgetDate(source), source <= date.addingTimeInterval(60) else { return nil }
                return min(observed, source)
            }
            return observed
        }()
        let provider = Self.widgetText(account.menuAgentPrefix, maximum: 16) ?? "JSON"
        let rawPlan = SubscriptionPlanLabel.displayName(planName: reading?.planName, multiplier: reading?.planMultiplier,
                                                      isCodex: account.provider == .codex || account.menuAgentPrefix == "Codex")
        let plan = rawPlan.flatMap { Self.widgetText($0, maximum: 80) }
        let status = reading.map { TokenBarWidgetStatus(rawValue: $0.displayStatus(at: date).rawValue) ?? .unavailable } ?? .notConfigured
        var freshUntil: Date?
        if let reading, let observed, reading.isFresh(at: date) {
            var bounds = [observed.addingTimeInterval(120)]
            if let source = reading.sourceCollectedAt { bounds.append(source.addingTimeInterval(120)) }
            bounds.append(contentsOf: reading.visibleWindows.compactMap(\.resetsAt))
            freshUntil = bounds.filter(Self.widgetDate).min()
        }

        var projected: [(metric: TokenBarWidgetMetric, selected: Bool)] = []
        var resetCards: Int?
        var resetCardExpirations: [Date]?
        var urgencyWindow: QuotaUrgencyWindow?
        if let reading, observed != nil {
            let isCursor = account.menuAgentPrefix == "Cursor"
            let windows = reading.windows.filter {
                $0.group == "default" && !$0.unlimited && (!isCursor || $0.id.caseInsensitiveCompare("api") == .orderedSame)
            }.compactMap { window -> QuotaUrgencyWindow? in
                guard let percent = window.remainingPercent, let start = window.startsAt, let reset = window.resetsAt,
                      Self.widgetDate(start), Self.widgetDate(reset) else { return nil }
                let label = Self.widgetText(window.title + (window.model.map { " · " + $0 } ?? ""), maximum: 80) ?? "额度"
                return QuotaUrgencyWindow(label: label, remainingPercent: percent, startsAt: start, resetsAt: reset)
            }
            if let planningDate = reading.isFresh(at: date) ? date : rankingObserved {
                urgencyWindow = QuotaUrgency.primaryWindow(from: windows, at: planningDate, isFresh: true)
            }
            for (index, window) in reading.visibleWindows.enumerated() {
                let value: String
                let percent: Double?
                if window.unlimited { value = "∞"; percent = nil }
                else if let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining) {
                    value = Self.widgetNumber(remaining, digits: 1) + "%"
                    percent = remaining
                } else if let remaining = window.remaining, Self.widgetAmount(remaining),
                          ["tokens", "requests", "messages", "credits", "USD"].contains(window.unit) {
                    value = Self.widgetNumber(remaining, digits: 2) + " " + window.unit
                    percent = nil
                } else { continue }
                let title = window.title + (window.model.map { " · " + $0 } ?? "")
                let label = Self.widgetText(title, maximum: 80) ?? "额度"
                let reset = window.resetsAt.flatMap { Self.widgetDate($0) ? $0 : nil }
                projected.append((TokenBarWidgetMetric(id: "window-\(index)", label: label, value: value, remainingPercent: percent, resetsAt: reset),
                                  selection.contains(MenuQuotaMetric.selectionID(accountID: account.id, windowID: window.id))))
            }
            if reading.unlimitedCredits || reading.credits.map(Self.widgetAmount) == true {
                let selected = selection.contains(account.id.uuidString + "#credits")
                let value = reading.unlimitedCredits ? "∞" : Self.widgetNumber(reading.credits!, digits: 2) + " 点"
                projected.append((TokenBarWidgetMetric(id: "credits", label: "剩余点数", value: value, remainingPercent: nil), selected))
            }
            let cardAvailability = ResetCardAvailability(reading: reading, at: date)
            if let count = cardAvailability.availableCount {
                resetCards = count
                resetCardExpirations = cardAvailability.pendingExpirations.isEmpty ? nil : Array(cardAvailability.pendingExpirations.prefix(100))
            }
        }
        let ordered = projected.filter(\.selected) + projected.filter { !$0.selected }
        var metrics = Array(ordered.prefix(TokenBarWidgetConstants.maximumMetrics).map(\.metric))
        // Keep the selected quota order, but never lose known points behind three windows.
        if let credits = projected.first(where: { $0.metric.id == "credits" })?.metric,
           !metrics.contains(where: { $0.id == "credits" }) {
            metrics = Array(metrics.prefix(TokenBarWidgetConstants.maximumMetrics - 1)) + [credits]
        }
        return TokenBarWidgetAccount(id: account.id, email: AccountEmail.validated(accountEmail(account)), provider: provider, plan: plan,
                                     status: status, observedAt: observed, freshUntil: freshUntil,
                                     metrics: metrics, resetCards: resetCards, urgencyWindow: urgencyWindow,
                                     rankingObservedAt: rankingObserved, rankingObservedAtPresent: true,
                                     resetCardExpirations: resetCardExpirations)
    }

    private static func widgetDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (1_577_836_800...4_102_444_800).contains(date.timeIntervalSince1970)
    }

    private static func widgetAmount(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 9_007_199_254_740_991
    }

    private static func widgetText(_ value: String, maximum: Int) -> String? {
        guard !value.isEmpty,
              value.range(of: "\\A[\\p{L}\\p{N} .·%()（）_+…-]+\\z", options: .regularExpression) != nil,
              value.range(of: "bearer|secret|eyJ|sk-", options: [.caseInsensitive, .regularExpression]) == nil else { return nil }
        return String(value.prefix(maximum))
    }

    private static func widgetNumber(_ number: Double, digits: Int) -> String {
        var text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, number == 0 ? 0 : number)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
