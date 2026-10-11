import SwiftUI
import WidgetKit
#if canImport(TokenBarWidgetShared)
import TokenBarWidgetShared
#endif

struct TokenBarWidgetView: View {
    let entry: TokenBarWidgetEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    var body: some View {
        Group {
            if accounts.isEmpty {
                emptyState
            } else if family == .systemSmall, let account = accounts.first {
                smallAccount(account)
            } else {
                accountList
            }
        }
        .privacySensitive()
    }

    private var accounts: [TokenBarWidgetAccount] {
        Array(entry.snapshot.rankedAccounts(at: entry.date).prefix(family == .systemSmall ? 1 : family == .systemMedium ? 3 : 6))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TokenBar").font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            Text("—").font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            Text("打开 TokenBar\n接入账号")
                .font(.system(size: 12, weight: .medium)).lineSpacing(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var heading: some View {
        HStack {
            Text("TokenBar").font(.system(size: 10, weight: .semibold, design: .rounded))
            Spacer(minLength: 4)
            if entry.snapshot.accounts.count > accounts.count {
                Text("另 \(entry.snapshot.accounts.count - accounts.count) 个")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func smallAccount(_ account: TokenBarWidgetAccount) -> some View {
        let metrics = account.displayMetrics()
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("TokenBar").font(.system(size: 10, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                Text(service(account)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(identity(account)).font(.system(size: 12, weight: .semibold))
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            urgencyLine(account, fontSize: 9)
            Spacer(minLength: 0)
            if let primary = metrics.first {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(primary.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    metricValue(primary, account: account, prominent: true)
                }
                resetTime(primary, account: account, fontSize: 8, compact: false)
                if metrics.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metrics[1].label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        metricValue(metrics[1], account: account, prominent: false)
                    }
                    resetTime(metrics[1], account: account, fontSize: 8, compact: false)
                }
            } else {
                Text("—").font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(observation(account)).font(.system(size: 8)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                resetCardBadge(account)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(account))
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 6 : 4) {
            heading
            ForEach(accounts) { account in
                accountRow(account, compact: family == .systemMedium)
            }
            Spacer(minLength: 0)
        }
    }

    private func accountRow(_ account: TokenBarWidgetAccount, compact: Bool) -> some View {
        let metrics = account.displayMetrics()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity(account)).font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(service(account)).font(.system(size: compact ? 8 : 9))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .top, spacing: 6) {
                    if metrics.isEmpty {
                        Text("—").font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    } else {
                        ForEach(metrics) { metric in
                            VStack(alignment: .trailing, spacing: 2) {
                                if metric.id == "credits" {
                                    metricValue(metric, account: account, prominent: false)
                                    Text(metric.label).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Text(metric.label).font(.system(size: 8)).foregroundStyle(.secondary)
                                            .lineLimit(1).minimumScaleFactor(0.8)
                                        metricValue(metric, account: account, prominent: false)
                                    }
                                    resetTime(metric, account: account, fontSize: 8, compact: true)
                                }
                            }
                            .frame(width: 78, alignment: .trailing)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: 5) {
                urgencyLine(account, fontSize: compact ? 8 : 9)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(observation(account)).font(.system(size: 8)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                resetCardBadge(account)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(account))
    }

    @ViewBuilder
    private func resetTime(_ metric: TokenBarWidgetMetric, account: TokenBarWidgetAccount,
                           fontSize: CGFloat, compact: Bool) -> some View {
        // Points have no declared reset cycle. Never borrow the account's
        // urgency window or another displayed metric's reset timestamp.
        if metric.id != "credits" {
            HStack(spacing: 2) {
                if compact {
                    Image(systemName: "arrow.clockwise").font(.system(size: fontSize - 1))
                } else {
                    Text("重置")
                }
                Text(resetDate(metric.resetsAt))
            }
            .font(.system(size: fontSize)).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(compact ? 0.85 : 1)
            .accessibilityLabel(resetAccessibility(metric, account: account))
        }
    }

    private func resetDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: entry.date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = sameYear ? "M/d HH:mm" : "yyyy/M/d HH:mm"
        return formatter.string(from: date)
    }

    private func resetAccessibility(_ metric: TokenBarWidgetMetric, account: TokenBarWidgetAccount) -> String {
        guard let date = metric.resetsAt else { return metric.label + "，重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy年M月d日 HH:mm zzzz"
        let prefix = account.isFresh(at: entry.date) ? "重置时间 " : "上次记录的重置时间 "
        return metric.label + "，" + prefix + formatter.string(from: date)
    }

    @ViewBuilder
    private func urgencyLine(_ account: TokenBarWidgetAccount, fontSize: CGFloat) -> some View {
        if let urgency = account.urgency(at: entry.date), let window = account.urgencyWindow {
            let color = urgencyColor(urgency.level)
            HStack(spacing: 4) {
                Text(urgency.level.title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize(horizontal: true, vertical: false)
                Text(window.label.replacingOccurrences(of: " ", with: "") + " · 需用 " + dailyValue(urgency.requiredDailyPercent) + "%/天")
                    .font(.system(size: fontSize)).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private func urgencyColor(_ level: QuotaUrgencyLevel) -> Color {
        switch level {
        case .normal: return .secondary
        case .priority: return .orange
        case .urgent: return .red
        }
    }

    private func dailyValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    @ViewBuilder
    private func resetCardBadge(_ account: TokenBarWidgetAccount) -> some View {
        if let label = account.resetCardsLabel(at: entry.date) {
            Text(label).font(.system(size: 8, weight: .medium))
                .foregroundStyle(account.isFresh(at: entry.date) ? Color.primary : Color.secondary)
                .monospacedDigit().fixedSize(horizontal: true, vertical: false)
        }
    }

    private func metricValue(_ metric: TokenBarWidgetMetric, account: TokenBarWidgetAccount, prominent: Bool) -> some View {
        let fresh = account.isFresh(at: entry.date)
        let historical = !fresh && account.observedAt != nil && metric.value != "—"
        let available = fresh || account.observedAt != nil
        return (
            Text(historical ? "上次 " : "").font(.system(size: 8))
            + Text(available ? metric.value : "—")
                .font(.system(size: prominent ? 23 : 13, weight: .semibold, design: .rounded))
        )
        .foregroundColor(fresh ? valueColor(metric.remainingPercent) : .secondary)
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
    }

    private func identity(_ account: TokenBarWidgetAccount) -> String { account.email ?? "邮箱待确认" }

    private func service(_ account: TokenBarWidgetAccount) -> String {
        guard let plan = account.plan, !plan.isEmpty else { return account.provider }
        return account.provider + " · " + plan
    }

    private func observation(_ account: TokenBarWidgetAccount) -> String {
        let status = account.displayStatus(at: entry.date)
        guard let observed = account.observedAt else { return status.title + " · 尚无读数" }
        let date = Calendar.current.isDate(observed, inSameDayAs: entry.date)
            ? observed.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
            : observed.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        if account.isFresh(at: entry.date) { return "采集 " + date }
        return (status == .stale ? "旧数据" : status.title) + " · " + date
    }

    private func valueColor(_ percent: Double?) -> Color {
        guard let percent else { return .primary }
        return percent <= 10 ? .red : percent <= 25 ? .orange : .accentColor
    }

    private func accessibilitySummary(_ account: TokenBarWidgetAccount) -> String {
        let fresh = account.isFresh(at: entry.date)
        let metrics = account.displayMetrics().map { metric in
            let value = fresh || account.observedAt != nil ? metric.value : "—"
            let historical = !fresh && account.observedAt != nil && value != "—"
            let reset = metric.id == "credits" ? "" : "，" + resetAccessibility(metric, account: account)
            return metric.label + "，" + (historical ? "上次 " : "") + value + reset
        }.joined(separator: "，")
        let cards = account.resetCardsLabel(at: entry.date).map { "，" + $0 } ?? ""
        let urgency: String
        if let assessment = account.urgency(at: entry.date), let window = account.urgencyWindow {
            urgency = "，" + assessment.level.title + "，" + window.label + "每天需使用 " + dailyValue(assessment.requiredDailyPercent) + "%"
        } else {
            urgency = ""
        }
        return identity(account) + "，" + service(account) + "，" + metrics + cards + urgency + "，" + observation(account)
    }
}

struct TokenBarWidgetPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            TokenBarWidgetView(entry: TokenBarWidgetPreview.entry())
                .previewContext(WidgetPreviewContext(family: .systemSmall))
            TokenBarWidgetView(entry: TokenBarWidgetPreview.entry())
                .previewContext(WidgetPreviewContext(family: .systemMedium))
            TokenBarWidgetView(entry: TokenBarWidgetPreview.entry())
                .previewContext(WidgetPreviewContext(family: .systemLarge))
        }
    }
}
