import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @State private var showingConnection = false
    @State private var showingSettings = false
    @State private var expandedAccounts: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.isDemo { demoBanner }
                    if let message = store.errorMessage, !message.isEmpty {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if showingSettings { settings }
                    if store.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.accounts) { account in
                            accountCard(account)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingConnection) {
            ConnectView(store: store)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenBar").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(store.accounts.isEmpty ? "每个账号，一眼看清" : "\(store.accounts.count) 个额度来源")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.refresh() } } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain).frame(width: 32, height: 36)
            .disabled(store.isRefreshing || store.accounts.isEmpty)
            .help("刷新全部账号").accessibilityLabel("刷新全部账号")
            Button { showingConnection = true } label: {
                Image(systemName: "plus").fontWeight(.medium).frame(width: 32, height: 36)
            }
            .buttonStyle(.plain).help("添加账号").accessibilityLabel("添加账号")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                .padding(.top, 68)
            VStack(spacing: 7) {
                Text("把你的 Agent 额度放进菜单栏").font(.headline)
                Text("Codex、Claude Code、Grok Build\n以及支持 JSON 的其他服务")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            Button("添加第一个账号") { showingConnection = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.top, 3)
            Button("先看看演示") { store.loadDemo() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Text("账号由你选择接入，凭据保留在本机。")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle")
            Text("演示数据").fontWeight(.medium)
            Spacer()
            Button("退出演示") { store.exitDemo() }.buttonStyle(.plain)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func accountCard(_ account: AccountConfig) -> some View {
        let reading = store.readings[account.id]
        let fresh = reading?.isFresh(at: store.now) == true
        let expanded = expandedAccounts.contains(account.id)
        let presentation = accountPresentation(account)
        let identity = store.accountIdentityLabel(account)
        let identityHelp = store.accountIdentityHelp(account)
        let service = serviceSummary(account, reading: reading)
        return VStack(alignment: .leading, spacing: expanded ? 12 : 8) {
            Button {
                if expanded { expandedAccounts.remove(account.id) }
                else { expandedAccounts.insert(account.id) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: presentation.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(presentation.color)
                        .frame(width: 32, height: 32)
                        .background(presentation.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(identity)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2).truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(identityHelp)
                            .accessibilityLabel(identity)
                        HStack(spacing: 5) {
                            Text(service).lineLimit(1).help(service)
                            Text("·")
                            Circle().fill(fresh ? Color.green : Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
                            Text(reading?.displayStatus(at: store.now).title ?? "等待首次读取")
                                .fixedSize(horizontal: true, vertical: false)
                                .help(reading?.displayStatus(at: store.now).title ?? "等待首次读取")
                            if fresh, let reading, let alert = accountAlert(reading) {
                                Text(alert).font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(alert == "即将重置" ? Color.red : Color.orange)
                                    .padding(.horizontal, 5).padding(.vertical, 3)
                                    .background((alert == "即将重置" ? Color.red : Color.orange).opacity(0.10), in: Capsule())
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(identity)，\(service)，\(expanded ? "收起" : "展开")账号详情")
            .accessibilityHint(identityHelp)

            if let reading {
                if expanded {
                    if reading.visibleWindows.isEmpty && !reading.hasVisibleSupplementalQuota {
                        Text(fresh ? "暂无可显示额度" : "当前未知")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if !reading.visibleWindows.isEmpty {
                        VStack(spacing: 12) {
                            ForEach(reading.visibleWindows) { window in quotaRow(window, fresh: fresh) }
                        }
                    }
                    if reading.credits != nil || reading.unlimitedCredits || reading.resetCardsAvailable != nil {
                        HStack(spacing: 14) {
                            if reading.credits != nil || reading.unlimitedCredits {
                                smallMetric("点数", value: reading.unlimitedCredits ? "不限量" : formatted(reading.credits), fresh: fresh)
                            }
                            if let count = reading.resetCardsAvailable {
                                smallMetric("重置卡", value: "\(count) 张", fresh: fresh)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    compactSummary(reading, fresh: fresh)
                }
                if !fresh, !reading.detail.isEmpty, expanded || reading.hasVisibleQuota {
                    Text(reading.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1).help(reading.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !fresh, let lastSuccess = reading.lastSuccessAt {
                    Text("上次成功读取 \(lastSuccess.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if expanded { accountDetails(account, reading: reading, fresh: fresh) }
            } else if expanded {
                sourceDetails(account)
                removeButton(account)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
    }

    private func compactSummary(_ reading: AccountReading, fresh: Bool) -> some View {
        let metrics = compactMetrics(reading)
        return VStack(alignment: .leading, spacing: 7) {
            if metrics.isEmpty {
                let notice = fresh ? "暂无可显示额度" : (reading.detail.isEmpty ? reading.displayStatus(at: store.now).title : reading.detail)
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).help(notice).fixedSize(horizontal: false, vertical: true)
            } else {
                MetricFlowLayout(horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(metrics) { metric in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text((fresh ? "" : "上次 ") + metric.label).foregroundStyle(.secondary)
                            Text(metric.value).fontWeight(.semibold)
                                .foregroundStyle(fresh ? metric.color : .secondary)
                        }
                        .font(.system(size: 11)).monospacedDigit()
                        .fixedSize(horizontal: true, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if fresh, let primary = reading.visibleWindows.first(where: { $0.group == "default" && $0.remainingPercent != nil }),
               let percent = primary.remainingPercent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.06))
                        Capsule().fill(quotaColor(percent))
                            .frame(width: geometry.size.width * max(0, min(100, percent)) / 100)
                    }
                }
                .frame(height: 4)
                .accessibilityLabel("\(primary.label) 剩余 \(primary.displayValue)")
            }
        }
    }

    private func compactMetrics(_ reading: AccountReading) -> [CompactMetric] {
        var result = reading.visibleWindows.enumerated().map { index, window in
            CompactMetric(id: "window-\(index)", label: shortWindowTitle(window), value: window.displayValue, color: quotaColor(window.remainingPercent))
        }
        if reading.credits != nil || reading.unlimitedCredits {
            result.append(CompactMetric(id: "credits", label: "点数", value: reading.unlimitedCredits ? "不限量" : formatted(reading.credits)))
        }
        if let count = reading.resetCardsAvailable {
            result.append(CompactMetric(id: "reset-cards", label: "重置卡", value: "\(count)张"))
        }
        return result
    }

    private func shortWindowTitle(_ window: QuotaWindow) -> String {
        let label = window.label.replacingOccurrences(of: " ", with: "")
        switch window.group {
        case "reserve": return "Reserve" + (window.model.map { " " + $0 } ?? "") + " " + label
        case "code-review": return "审查 " + label
        case "additional": return "附加 " + label
        default: return label
        }
    }

    private func accountAlert(_ reading: AccountReading) -> String? {
        let alerts = reading.visibleWindows.compactMap { $0.alert(at: store.now) }
        return alerts.contains("即将重置") ? "即将重置" : alerts.first
    }

    private func quotaRow(_ window: QuotaWindow, fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.title).font(.system(size: 12, weight: .medium))
                    if let model = window.model, !model.isEmpty {
                        Text(model).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if fresh, let alert = window.alert(at: store.now) {
                    Text(alert).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(alert == "即将重置" ? Color.red : Color.orange).padding(.horizontal, 5).padding(.vertical, 3)
                        .background((alert == "即将重置" ? Color.red : Color.orange).opacity(0.10), in: Capsule())
                }
                Text(fresh ? window.displayValue : "当前未知")
                    .font(.system(size: fresh ? 19 : 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fresh ? quotaColor(window.remainingPercent) : .secondary)
            }
            if fresh, let percent = window.remainingPercent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.06))
                        Capsule().fill(quotaColor(percent))
                            .frame(width: geometry.size.width * max(0, min(100, percent)) / 100)
                    }
                }.frame(height: 5)
            }
            HStack {
                if !fresh {
                    Text("上次 \(window.displayValue)")
                } else if let remaining = window.remaining, let limit = window.limit, window.unit != "percent" {
                    Text("\(formatted(remaining)) / \(formatted(limit)) \(window.unit)")
                }
                Spacer(minLength: 4)
                if let reset = window.resetsAt {
                    let resetHint = reset.formatted(date: .complete, time: .complete)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdown(to: reset, now: context.date)).monospacedDigit()
                    }
                    .help(resetHint)
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func smallMetric(_ label: String, value: String, fresh: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(fresh ? value : "当前未知").fontWeight(.medium).monospacedDigit()
            if !fresh { Text("上次 \(value)").foregroundStyle(.tertiary) }
        }.font(.system(size: 11))
    }

    private func accountDetails(_ account: AccountConfig, reading: AccountReading, fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let email = store.accountEmail(account) {
                Label(email, systemImage: "envelope")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .help(store.accountIdentityHelp(account))
                    .accessibilityLabel("邮箱，" + email)
            }
            sourceDetails(account)
            if fresh, !reading.detail.isEmpty {
                Text(reading.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !reading.resetCards.isEmpty {
                ForEach(Array(reading.resetCards.enumerated()), id: \.offset) { index, card in
                    HStack(alignment: .top) {
                        Label("重置卡 \(index + 1)", systemImage: "ticket")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(resetCardStatus(card.status))
                            if let expiry = card.expiresAt {
                                Text("\(expiry.formatted(date: .abbreviated, time: .shortened)) 到期")
                            }
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("检查于 \(reading.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                removeButton(account)
            }
        }
    }

    private func sourceDetails(_ account: AccountConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("数据源 · " + sourceMethod(account.method))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(sourceLocation(account))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if account.method == .snapshotSSH, account.sshUseSudo == true {
                Text("使用已有 sudo 只读权限")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !account.sourceAccountID.isEmpty {
                Text("账号 ID · " + account.sourceAccountID)
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func sourceMethod(_ method: ConnectionMethod) -> String {
        switch method {
        case .localFile: return "凭据文件"
        case .keychain: return "钥匙串"
        case .grokCLI: return "本机 CLI"
        case .snapshotFile: return "本地 JSON"
        case .snapshotURL: return "HTTPS JSON"
        case .snapshotSSH: return "SSH JSON"
        }
    }

    private func sourceLocation(_ account: AccountConfig) -> String {
        guard !account.location.isEmpty else { return "演示来源" }
        if account.method == .snapshotSSH {
            return (account.sshHost ?? "未设置主机") + ":" + account.location
        }
        guard account.method == .snapshotURL, var components = URLComponents(string: account.location) else { return account.location }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "HTTPS 数据源"
    }

    private func removeButton(_ account: AccountConfig) -> some View {
        Button("移除此账号", role: .destructive) { store.remove(account) }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button { showingSettings = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("关闭设置")
            }
            Toggle("登录时启动", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                .toggleStyle(.switch).controlSize(.small)
            HStack {
                Text("自动刷新")
                Spacer()
                Picker("自动刷新间隔", selection: Binding(get: { store.refreshSeconds }, set: { store.updateRefreshInterval($0) })) {
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                    Text("120 秒").tag(120.0)
                }
                .labelsHidden().frame(width: 100)
            }
            VStack(alignment: .leading, spacing: 5) {
                Toggle("临期提醒", isOn: Binding(
                    get: { store.expiryAlertsEnabled },
                    set: { store.setExpiryAlertsEnabled($0) }
                ))
                .toggleStyle(.switch).controlSize(.small)
                Text("余量较多且临近重置时，在菜单栏下方提醒一次。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            menuQuotaSettings
        }
        .font(.subheadline).padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var menuQuotaSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("菜单栏显示").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("已选 \(selectedMenuQuotaCount) 项")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if store.availableMenuMetrics.isEmpty {
                Text("暂无可显示的额度")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { account in
                    let metrics = store.availableMenuMetrics.filter { $0.accountID == account.id }
                    if !metrics.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.accountIdentityLabel(account))
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(2).truncationMode(.middle)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(store.accountIdentityHelp(account))
                                Text(account.displayService).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            ForEach(metrics) { metric in
                                Toggle(metric.windowLabel, isOn: Binding(
                                    get: { store.menuMetricSelected(metric) },
                                    set: { store.setMenuMetric(metric, enabled: $0) }
                                ))
                                .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                                .accessibilityLabel("\(store.accountIdentityLabel(account)) · \(account.displayService) · \(metric.windowLabel)，在菜单栏显示")
                            }
                        }
                    }
                }
            }
        }
    }

    private var selectedMenuQuotaCount: Int {
        store.availableMenuMetrics.filter {
            store.menuMetricSelected($0)
        }.count
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(store.isRefreshing ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(store.isRefreshing ? "正在读取额度…" : lastRefreshText)
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button { showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).frame(width: 28, height: 28)
                .help("设置").accessibilityLabel("设置")
            Menu {
                Button("关于 TokenBar") { NSApp.orderFrontStandardAboutPanel(nil) }
                Divider()
                Button("退出 TokenBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("更多").accessibilityLabel("更多")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var lastRefreshText: String {
        guard let date = store.lastRefresh else { return "只在菜单栏，随时可见" }
        return "更新于 " + date.formatted(date: .omitted, time: .standard)
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "未提供" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func countdown(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return "等待重置后更新" }
        let days = seconds / 86400, hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60, remainder = seconds % 60
        if days > 0 { return String(format: "%d天 %02d:%02d:%02d 后重置", days, hours, minutes, remainder) }
        if hours > 0 { return String(format: "%d:%02d:%02d 后重置", hours, minutes, remainder) }
        return String(format: "%d:%02d 后重置", minutes, remainder)
    }

    private func resetCardStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "available", "active", "unused": return "可用"
        case "used", "redeemed": return "已使用"
        case "expired": return "已过期"
        default: return status
        }
    }

    private func quotaColor(_ percent: Double?) -> Color {
        guard let percent else { return .primary }
        return percent <= 10 ? .red : percent <= 25 ? .orange : .accentColor
    }

    private func serviceSummary(_ account: AccountConfig, reading: AccountReading?) -> String {
        guard let plan = reading?.planName?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else {
            return account.displayService
        }
        return account.displayService + " · " + plan
    }

    private func accountPresentation(_ account: AccountConfig) -> (symbol: String, color: Color) {
        switch account.displayService {
        case "Codex": return ("terminal", .primary)
        case "Claude Code": return ("sparkle", Color(red: 0.73, green: 0.43, blue: 0.30))
        case "Grok Build": return ("bolt", .purple)
        case "Grok Bot", "GrokBot": return ("bubble.left.and.bubble.right", .indigo)
        case "Cursor": return ("cursorarrow", .primary)
        default:
            switch account.provider {
            case .codex: return (account.provider.symbol, .primary)
            case .claude: return (account.provider.symbol, Color(red: 0.73, green: 0.43, blue: 0.30))
            case .grok: return (account.provider.symbol, .purple)
            case .snapshot: return (account.provider.symbol, .blue)
            }
        }
    }

}

private struct CompactMetric: Identifiable {
    let id: String
    let label: String
    let value: String
    var color: Color = .primary
}

private struct MetricFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrangement(cache.sizes, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrangement(cache.sizes, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(cache.sizes[index]))
        }
    }

    private func arrangement(_ sizes: [CGSize], width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var origins: [CGPoint] = []
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}
