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
        Array(entry.snapshot.accounts.prefix(family == .systemSmall ? 1 : family == .systemMedium ? 3 : 6))
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
        let fresh = account.isFresh(at: entry.date)
        let metrics = Array(account.metrics.prefix(2))
        return VStack(alignment: .leading, spacing: 5) {
            heading
            Text(identity(account)).font(.system(size: 12, weight: .semibold))
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Text(service(account)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let primary = metrics.first {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(primary.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    metricValue(primary, account: account, prominent: true)
                }
                quotaBar(primary, fresh: fresh)
                if metrics.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metrics[1].label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        metricValue(metrics[1], account: account, prominent: false)
                    }
                }
            } else {
                Text("—").font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(observation(account)).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(account))
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 5 : 6) {
            heading
            ForEach(accounts) { account in
                accountRow(account, compact: family == .systemMedium)
            }
            Spacer(minLength: 0)
        }
    }

    private func accountRow(_ account: TokenBarWidgetAccount, compact: Bool) -> some View {
        let fresh = account.isFresh(at: entry.date)
        let metrics = Array(account.metrics.prefix(2))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity(account)).font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if compact {
                        HStack(spacing: 5) {
                            Text(service(account)).lineLimit(1)
                            Text(observation(account)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                    } else {
                        Text(service(account)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        Text(observation(account)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .top, spacing: 8) {
                    if metrics.isEmpty {
                        Text("—").font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    } else {
                        ForEach(metrics) { metric in
                            VStack(alignment: .trailing, spacing: 2) {
                                metricValue(metric, account: account, prominent: false)
                                Text(metric.label).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 66, alignment: .trailing)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if let primary = metrics.first { quotaBar(primary, fresh: fresh) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(account))
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

    @ViewBuilder
    private func quotaBar(_ metric: TokenBarWidgetMetric, fresh: Bool) -> some View {
        if fresh, let percent = metric.remainingPercent {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.06))
                    Capsule().fill(valueColor(percent).opacity(0.65))
                        .frame(width: geometry.size.width * max(0, min(100, percent)) / 100)
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
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
        let metrics = account.metrics.prefix(2).map { metric in
            let value = fresh || account.observedAt != nil ? metric.value : "—"
            let historical = !fresh && account.observedAt != nil && value != "—"
            return metric.label + "，" + (historical ? "上次 " : "") + value
        }.joined(separator: "，")
        return identity(account) + "，" + service(account) + "，" + metrics + "，" + observation(account)
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
