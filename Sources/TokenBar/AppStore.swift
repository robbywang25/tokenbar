import AppKit
import Combine
import Foundation
import ServiceManagement
import TokenBarWidgetShared

@MainActor
final class AppStore: ObservableObject {
    @Published var accounts: [AccountConfig] = []
    @Published private(set) var snapshotSources: [SnapshotSource] = []
    @Published var readings: [UUID: AccountReading] = [:]
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?
    @Published var refreshSeconds: Double = 10
    @Published var launchAtLogin = false
    @Published var now = Date()
    @Published var isDemo = false
    @Published private(set) var calendarTimeZoneID = "local"
    // nil preserves the initial one-metric default; [] is an explicit opt-out.
    @Published private(set) var menuQuotaSelection: Set<String>?
    @Published private(set) var rememberedMenuMetrics: [MenuQuotaMetric] = []
    @Published private(set) var expiryAlertsEnabled = true
    @Published private(set) var showsAgentPrefix = true
    // Installed by the application delegate, never by isolated data tests.
    var onWidgetSnapshotChange: ((TokenBarWidgetSnapshot) -> Void)?
    var beforeRefresh: (() async -> Void)?
    var onSavedStateChange: (() -> Void)?
    var godSourceID: UUID?
    var syncedSourceID: UUID?
    var storageDirectory: URL { directory }
    var preferences: UserDefaults { defaults }

    private var rememberedAccountEmails: [UUID: RememberedAccountEmail] = [:]
    private var menuReadingCache: [UUID: MenuReadingCache] = [:]
    private(set) var resetCalendarHistory = ResetCalendarHistory()
    private var persistedResetCalendarHistory = ResetCalendarHistory()
    private var resetCalendarHistoryReadFailed = false
    private let client: ProviderClient
    private let directory: URL
    private let defaults: UserDefaults
    private static let menuSelectionKey = "menuQuotaSelection.v1"
    private static let menuMetricsKey = "menuQuotaMetrics.v1"
    private static let agentPrefixKey = "showsAgentPrefix.v1"
    private static let expiryEnabledKey = "expiryAlertsEnabled.v1"
    private static let expiryReceiptsKey = "expiryNoticeReceipts.v1"
    private struct ExpiryReceipt: Codable {
        let id: String
        let resetsAt: Date
    }
    private var expiryReceipts: [ExpiryReceipt] = []
    private var clock: Timer?
    private var poll: Timer?
    private var revision = 0
    private var wakeObserver: NSObjectProtocol?
    private var connecting = false
    private var snapshotSourcesReadFailed = false

    init(directory: URL? = nil, client: ProviderClient = ProviderClient(), startTimers: Bool = true, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TokenBar")
        loadMenuPreferences()
        loadExpiryPreferences()
        load()
        let saved = defaults.double(forKey: "refreshSeconds")
        if [10.0, 15, 30, 60, 120].contains(saved) { refreshSeconds = saved }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if startTimers {
            // Freshness boundaries are coarse. Per-second countdowns live in
            // isolated TimelineViews so scrolling never invalidates the full list.
            clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.now = Date() }
            }
            schedulePoll()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
        }
    }

    func accountEmail(_ account: AccountConfig) -> String? {
        if let email = AccountEmail.validated(readings[account.id]?.email) { return email }
        guard let saved = rememberedAccountEmails[account.id],
              saved.sourceSignature == AccountEmail.sourceSignature(account),
              let email = AccountEmail.validated(saved.email) else { return nil }
        if let currentIdentity = readings[account.id]?.identityKey,
           let previousIdentity = saved.identityKey, currentIdentity != previousIdentity { return nil }
        return email
    }

    func accountIdentityLabel(_ account: AccountConfig) -> String {
        accountEmail(account) ?? "邮箱待确认"
    }

    func calendarModel(at date: Date? = nil) -> ResetCalendarModel {
        ResetCalendarModel(accounts: accounts, readings: readings, history: isDemo ? ResetCalendarHistory() : resetCalendarHistory,
                           now: date ?? now, identity: accountIdentityLabel)
    }

    func accountIdentityHelp(_ account: AccountConfig) -> String {
        guard let email = accountEmail(account) else { return "来源尚未提供邮箱。" }
        return AccountEmail.validated(readings[account.id]?.email) != nil
            ? email : email + "\n上次识别的邮箱；当前来源未返回邮箱。"
    }

    private func rememberAccountEmails(persist: Bool = true) {
        let previous = rememberedAccountEmails
        rememberedAccountEmails = rememberedAccountEmails.filter { id, saved in
            accounts.contains { $0.id == id && saved.sourceSignature == AccountEmail.sourceSignature($0) }
        }
        for account in accounts {
            guard let reading = readings[account.id] else { continue }
            if let email = AccountEmail.validated(reading.email) {
                rememberedAccountEmails[account.id] = RememberedAccountEmail(email: email,
                    sourceSignature: AccountEmail.sourceSignature(account), identityKey: reading.identityKey)
            } else if reading.status == .connected || reading.reason == "invalid_data" || reading.reason == "duplicate" ||
                        (reading.email != nil) ||
                        (reading.identityKey != nil && rememberedAccountEmails[account.id]?.identityKey != nil && reading.identityKey != rememberedAccountEmails[account.id]?.identityKey) {
                rememberedAccountEmails.removeValue(forKey: account.id)
            }
        }
        guard persist, !isDemo, rememberedAccountEmails != previous else { return }
        persistAccountEmails()
    }

    private func persistAccountEmails() {
        guard !isDemo else { return }
        do { try save(rememberedAccountEmails, name: "account-emails.json") }
        catch { errorMessage = "账号邮箱未能保存到本机。" }
    }

    var menuTitle: String {
        let metrics = selectedMenuMetrics
        guard !metrics.isEmpty else { return "—" }
        guard showsAgentPrefix else { return metrics.map(menuValue).joined(separator: " · ") }
        var previousAccount: UUID?
        var previousPrefix: String?
        return metrics.map { metric in
            let prefix = accounts.first(where: { $0.id == metric.accountID })?.menuAgentPrefix ?? "JSON"
            let value = menuValue(metric)
            let showPrefix = previousAccount != metric.accountID || previousPrefix != prefix
            previousAccount = metric.accountID
            previousPrefix = prefix
            return showPrefix ? prefix + " " + value : value
        }.joined(separator: " · ")
    }

    func setShowsAgentPrefix(_ enabled: Bool) {
        guard showsAgentPrefix != enabled else { return }
        showsAgentPrefix = enabled
        if !isDemo { defaults.set(enabled, forKey: Self.agentPrefixKey) }
        if !isDemo { onSavedStateChange?() }
    }

    func setExpiryAlertsEnabled(_ enabled: Bool) {
        guard expiryAlertsEnabled != enabled else { return }
        expiryAlertsEnabled = enabled
        if !isDemo { defaults.set(enabled, forKey: Self.expiryEnabledKey) }
        if !isDemo { onSavedStateChange?() }
    }

    /// The delegate calls this only when it can show a notice and the popover is
    /// closed. Consuming a notice records its account/window/reset cycle once.
    func takeNextExpiryNotice(at date: Date? = nil) -> ExpiryNotice? {
        guard expiryAlertsEnabled, !isDemo, !isRefreshing else { return nil }
        let date = date ?? Date()
        pruneExpiryReceipts(at: date)
        // Do not evict live receipts: exceeding the bound must never repeat a
        // notice already shown for a still-active reset cycle.
        guard expiryReceipts.count < 100 else { return nil }
        let seen = Set(expiryReceipts.map(\.id))
        var candidates: [ExpiryNotice] = []
        for account in accounts where account.enabled {
            guard let reading = readings[account.id], reading.isFresh(at: date) else { continue }
            for window in reading.visibleWindows {
                guard !window.unlimited, window.alert(at: date) == "即将重置",
                      let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining),
                      let reset = window.resetsAt else { continue }
                let id = account.id.uuidString + "/" + window.id + "@" + String(reset.timeIntervalSince1970)
                guard !seen.contains(id) else { continue }
                candidates.append(ExpiryNotice(id: id, accountName: accountIdentityLabel(account), serviceLabel: account.displayService,
                    windowLabel: window.title + (window.model.map { " · " + $0 } ?? ""), remainingPercent: remaining, resetsAt: reset))
            }
        }
        let notice = candidates.enumerated().min { first, second in
            first.element.resetsAt == second.element.resetsAt ? first.offset < second.offset : first.element.resetsAt < second.element.resetsAt
        }?.element
        guard let notice else { return nil }
        expiryReceipts.append(ExpiryReceipt(id: notice.id, resetsAt: notice.resetsAt))
        persistExpiryReceipts()
        return notice
    }

    private func loadExpiryPreferences() {
        expiryAlertsEnabled = defaults.object(forKey: Self.expiryEnabledKey) == nil ? true : defaults.bool(forKey: Self.expiryEnabledKey)
        if let data = defaults.data(forKey: Self.expiryReceiptsKey), data.count <= 65_536,
           let receipts = try? JSONDecoder().decode([ExpiryReceipt].self, from: data), receipts.count <= 100 {
            expiryReceipts = receipts
        } else { expiryReceipts = [] }
    }

    private func pruneExpiryReceipts(at date: Date) {
        let prefixes = accounts.map { $0.id.uuidString + "/" }
        let retained = expiryReceipts.filter { receipt in
            receipt.resetsAt > date && prefixes.contains(where: receipt.id.hasPrefix)
        }
        if retained.count != expiryReceipts.count {
            expiryReceipts = retained
            persistExpiryReceipts()
        }
    }

    private func persistExpiryReceipts() {
        guard !isDemo else { return }
        if let data = try? JSONEncoder().encode(expiryReceipts) { defaults.set(data, forKey: Self.expiryReceiptsKey) }
    }

    var menuTooltip: String {
        let metrics = selectedMenuMetrics
        guard !metrics.isEmpty else { return "未选择菜单栏额度" }
        return metrics.map { metric in
            let value = menuValue(metric)
            let detail: String
            if value == "—" { detail = "当前未知" }
            else if metric.kind == .credits, let reading = menuReading(for: metric.accountID)?.reading {
                if reading.unlimitedCredits { detail = "不限量" }
                else if let credits = reading.credits { detail = Self.exactCredits(credits) + " 点" }
                else { detail = "当前未知" }
            } else { detail = value }
            let history: String
            if let display = menuReading(for: metric.accountID), display.historical,
               let observed = display.reading.lastSuccessAt {
                history = "（上次成功读取：" + observed.formatted(.dateTime.month().day().hour().minute().second()) + "；当前" +
                    (readings[metric.accountID]?.displayStatus(at: now).title ?? "未更新") + "）"
            } else { history = "" }
            return "\(metric.accountName) · \(metric.windowLabel)：\(detail)\(history)"
        }.joined(separator: "\n")
    }

    var availableMenuMetrics: [MenuQuotaMetric] {
        menuMetricCatalog.filter(\.isVisibleInUI)
    }

    // Keep the complete label catalog and stored selection IDs, including
    // hidden metrics. Presentation filtering must not rewrite user choices.
    private var menuMetricCatalog: [MenuQuotaMetric] {
        orderedAccounts.flatMap { account -> [MenuQuotaMetric] in
            let windows = readings[account.id]?.windows ?? []
            var current = windows.filter { $0.remainingPercent != nil }.map { window in
                MenuQuotaMetric(accountID: account.id, windowID: window.id, accountName: accountIdentityLabel(account),
                                windowLabel: window.title + (window.model.map { " · " + $0 } ?? ""), group: window.group)
            }
            if let reading = readings[account.id], reading.credits != nil || reading.unlimitedCredits {
                current.append(MenuQuotaMetric(accountID: account.id, windowID: "", accountName: accountIdentityLabel(account),
                                               windowLabel: "剩余点数", group: "credits", kind: .credits))
            }
            let currentIDs = Set(current.map(\.id))
            let previous = rememberedMenuMetrics.filter { $0.accountID == account.id && !currentIDs.contains($0.id) }.map { metric in
                var metric = metric
                metric.accountName = accountIdentityLabel(account)
                // An existing window may change group or stop providing a
                // percentage. Its old default label must not revive Reserve.
                if metric.kind != .credits, let window = windows.first(where: { $0.id == metric.windowID }) {
                    metric.group = window.group
                    metric.windowLabel = window.title + (window.model.map { " · " + $0 } ?? "")
                }
                return metric
            }
            return current + previous
        }
    }

    func menuQuotaSelected(accountID: UUID, windowID: String) -> Bool {
        effectiveMenuSelection.contains(MenuQuotaMetric.selectionID(accountID: accountID, windowID: windowID))
    }

    func setMenuQuota(accountID: UUID, windowID: String, enabled: Bool) {
        guard let metric = availableMenuMetrics.first(where: { $0.kind != .credits && $0.accountID == accountID && $0.windowID == windowID }) else { return }
        setMenuMetric(metric, enabled: enabled)
    }

    func menuMetricSelected(_ metric: MenuQuotaMetric) -> Bool {
        effectiveMenuSelection.contains(metric.id)
    }

    func setMenuMetric(_ metric: MenuQuotaMetric, enabled: Bool) {
        let id = metric.id
        guard availableMenuMetrics.contains(where: { $0.id == id }) else { return }
        var selection = effectiveMenuSelection
        if enabled { selection.insert(id) } else { selection.remove(id) }
        menuQuotaSelection = selection
        rememberMenuChoices()
        publishWidgetSnapshot()
    }

    private var effectiveMenuSelection: Set<String> {
        if let menuQuotaSelection { return menuQuotaSelection }
        guard let metric = availableMenuMetrics.first(where: { metric in
            metric.kind != .credits && metric.group == "default" && accounts.contains(where: { $0.id == metric.accountID && $0.enabled })
        }) else { return [] }
        return [metric.id]
    }

    var selectedMenuMetricIDs: Set<String> { effectiveMenuSelection }

    private var selectedMenuMetrics: [MenuQuotaMetric] {
        let selected = effectiveMenuSelection
        return availableMenuMetrics.filter { selected.contains($0.id) }
    }

    /// Stable grouping: keep the first-seen service order and account order
    /// inside each service, without rewriting IDs, stored choices or history.
    var orderedAccounts: [AccountConfig] {
        var groups: [[AccountConfig]] = []
        var positions: [String: Int] = [:]
        for account in accounts {
            let key = account.menuAgentPrefix.lowercased()
            if let index = positions[key] { groups[index].append(account) }
            else { positions[key] = groups.count; groups.append([account]) }
        }
        return groups.flatMap { $0 }
    }

    private func menuReading(for id: UUID) -> (reading: AccountReading, historical: Bool)? {
        guard let account = accounts.first(where: { $0.id == id && $0.enabled }) else { return nil }
        let current = readings[id]
        if let current, MenuReadingCache.blocksFallback(current) { return nil }
        if let current, current.isFresh(at: now) { return (current, false) }
        let cached = menuReadingCache[id].flatMap {
            $0.matches(account, current: current) && MenuReadingCache.accepts($0.reading, at: now) ? $0.reading : nil
        }
        if let current, MenuReadingCache.accepts(current, at: now),
           cached == nil || current.lastSuccessAt! >= cached!.lastSuccessAt! { return (current, true) }
        if let cached, MenuReadingCache.accepts(cached, at: now) { return (cached, true) }
        return nil
    }

    private func rememberMenuReadings() {
        guard !isDemo else { return }
        let previous = menuReadingCache
        menuReadingCache = menuReadingCache.filter { id, cached in
            accounts.contains { $0.id == id && cached.matches($0, current: readings[id]) }
        }
        for account in accounts {
            guard let reading = readings[account.id], MenuReadingCache.accepts(reading, at: now) else { continue }
            if let old = menuReadingCache[account.id]?.reading.lastSuccessAt, let observed = reading.lastSuccessAt, observed < old { continue }
            menuReadingCache[account.id] = MenuReadingCache(account: account, reading: reading)
        }
        if previous != menuReadingCache {
            do { try save(menuReadingCache, name: "menu-readings.json") }
            catch { errorMessage = "菜单栏上次读数未能保存。" }
        }
    }

    private func menuValue(_ metric: MenuQuotaMetric) -> String {
        guard let display = menuReading(for: metric.accountID) else { return "—" }
        let reading = display.reading
        let prefix = display.historical ? "~" : ""
        if metric.kind == .credits {
            if reading.unlimitedCredits { return prefix + "∞" }
            guard let credits = reading.credits, credits.isFinite, credits >= 0 else { return "—" }
            return prefix + Self.compactCredits(credits)
        }
        guard let percent = reading.visibleWindows.first(where: { $0.id == metric.windowID })?.remainingPercent,
              percent.isFinite, (0...100).contains(percent) else { return "—" }
        return prefix + "\(Int(percent.rounded()))%"
    }

    private static func exactCredits(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func compactCredits(_ value: Double) -> String {
        let divisor: Double
        let suffix: String
        if value >= 999_950 { divisor = 1_000_000; suffix = "m" }
        else if value >= 1_000 { divisor = 1_000; suffix = "k" }
        else { return exactCredits(value) }
        let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value / divisor)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }

    private func loadMenuPreferences() {
        showsAgentPrefix = defaults.object(forKey: Self.agentPrefixKey) == nil ? true : defaults.bool(forKey: Self.agentPrefixKey)
        menuQuotaSelection = defaults.stringArray(forKey: Self.menuSelectionKey).map(Set.init)
        if let data = defaults.data(forKey: Self.menuMetricsKey), data.count <= 1_048_576,
           let metrics = try? JSONDecoder().decode([MenuQuotaMetric].self, from: data), metrics.count <= 1_950 {
            rememberedMenuMetrics = metrics
        } else { rememberedMenuMetrics = [] }
    }

    private func rememberMenuChoices(persist: Bool = true) {
        rememberedMenuMetrics = menuMetricCatalog
        if let selection = menuQuotaSelection {
            let accountIDs = accounts.map { $0.id.uuidString }
            menuQuotaSelection = selection.filter { id in accountIDs.contains(where: { id.hasPrefix($0 + "/") || id == $0 + "#credits" }) }
        }
        guard persist, !isDemo else { return }
        if let menuQuotaSelection { defaults.set(menuQuotaSelection.sorted(), forKey: Self.menuSelectionKey) }
        else { defaults.removeObject(forKey: Self.menuSelectionKey) }
        if let data = try? JSONEncoder().encode(rememberedMenuMetrics) { defaults.set(data, forKey: Self.menuMetricsKey) }
    }

    func refresh() async {
        // Opening the popover or waking the Mac must reclassify cached values
        // immediately, even while an earlier network refresh is still running.
        now = Date()
        guard !isRefreshing, !isDemo else { return }
        rememberMenuReadings()
        rememberAccountEmails()
        rememberMenuChoices()
        isRefreshing = true
        let currentRevision = revision
        await beforeRefresh?()
        guard revision == currentRevision else { isRefreshing = false; return }
        let provider = client
        var catalogs: [UUID: SnapshotCatalog] = [:]
        var sourceErrors: [UUID: ProviderError] = [:]
        await withTaskGroup(of: (UUID, Result<SnapshotCatalog, ProviderError>).self) { group in
            for source in snapshotSources {
                group.addTask {
                    do { return (source.id, .success(try await provider.fetchCatalog(source.connection))) }
                    catch { return (source.id, .failure(error as? ProviderError ?? .unavailable)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let catalog): catalogs[id] = catalog
                case .failure(let error): sourceErrors[id] = error
                }
            }
        }
        guard revision == currentRevision else { isRefreshing = false; return }
        reconcileSnapshotAccounts(catalogs)
        let configs = accounts.filter(\.enabled)
        await withTaskGroup(of: (UUID, AccountReading).self) { group in
            for config in configs where config.snapshotSourceID == nil {
                group.addTask {
                    do { return (config.id, try await provider.fetch(config)) }
                    catch {
                        let error = error as? ProviderError ?? .unavailable
                        return (config.id, AccountReading(status: error == .needsAuth ? .needsAuth : .unavailable,
                            checkedAt: Date(), lastSuccessAt: nil, detail: error.message))
                    }
                }
            }
            var results: [UUID: AccountReading] = [:]
            for await (id, reading) in group { results[id] = reading }
            for config in configs {
                guard let sourceID = config.snapshotSourceID else { continue }
                if let entry = catalogs[sourceID]?.entries.first(where: { $0.id == config.sourceAccountID }) {
                    results[config.id] = entry.reading
                } else {
                    let error = sourceErrors[sourceID] ?? .unavailable
                    results[config.id] = AccountReading(status: error == .needsAuth ? .needsAuth : .unavailable,
                        checkedAt: Date(), lastSuccessAt: nil,
                        detail: catalogs[sourceID] == nil ? error.message : "来源暂未返回此账号，等待下次同步。")
                }
            }
            let baseline = readings
            now = Date()
            var identities = Set<String>()
            for config in configs {
                let id = config.id
                guard revision == currentRevision, var reading = results[id], accounts.contains(where: { $0.id == id }) else { continue }
                if let identity = reading.identityKey, !identities.insert(identity).inserted {
                    reading = AccountReading(status: .notConfigured, checkedAt: Date(), lastSuccessAt: nil, detail: ProviderError.duplicate.message, reason: "duplicate")
                }
                recordResetHistory(account: config, previous: baseline[id], next: reading)
                readings[id] = reading
            }
        }
        if revision == currentRevision { lastRefresh = Date(); rememberMenuReadings(); rememberAccountEmails(); rememberMenuChoices(); persistReadings(); persistResetCalendarHistoryIfNeeded() }
        now = Date()
        isRefreshing = false
        if revision == currentRevision { publishWidgetSnapshot() }
    }

    /// Source subscriptions are explicit; upgrading never scans unrelated files
    /// or silently expands a manually selected single-account connection.
    func connectSnapshotSource(_ config: AccountConfig, secret: String? = nil) async throws {
        guard !connecting, !snapshotSourcesReadFailed, snapshotSources.count < 30,
              config.provider == .snapshot,
              !accounts.contains(where: { $0.id == config.id }),
              [.snapshotFile, .snapshotURL, .snapshotSSH].contains(config.method),
              !config.name.isEmpty, config.name.count <= 80, config.location.count <= 4096,
              !snapshotSources.contains(where: { $0.id == config.id ||
                  ($0.connection.method == config.method && config.method != .snapshotURL &&
                   SnapshotSource.locationKey($0.connection) == SnapshotSource.locationKey(config)) }) else {
            throw ProviderError.invalidConfiguration
        }
        connecting = true
        defer { connecting = false }
        var savedSecret = false
        if let secret, !secret.isEmpty {
            guard config.method == .snapshotURL, secret.count <= 16384,
                  !secret.contains("\n"), !secret.contains("\r") else { throw ProviderError.invalidConfiguration }
            try CredentialStore.save(Data(secret.utf8), account: config.id.uuidString)
            savedSecret = true
        }
        do {
            _ = try await client.fetchCatalog(config)
            if isDemo { exitDemo() }
            let updated = snapshotSources + [SnapshotSource(connection: config)]
            try save(updated, name: "snapshot-sources.json")
            snapshotSources = updated
            revision += 1
            onSavedStateChange?()
            await refresh()
        } catch {
            if savedSecret { CredentialStore.delete(account: config.id.uuidString) }
            throw error
        }
    }

    func setAccountDiscovery(_ id: UUID, enabled: Bool) {
        guard !isDemo, !snapshotSourcesReadFailed,
              let index = snapshotSources.firstIndex(where: { $0.id == id }) else { return }
        guard snapshotSources[index].discoversAccounts != enabled else { return }
        var updated = snapshotSources
        updated[index].discoversAccounts = enabled
        do {
            try save(updated, name: "snapshot-sources.json")
            snapshotSources = updated
            revision += 1
            onSavedStateChange?()
        } catch { errorMessage = "账号同步设置未能保存。" }
    }

    func restoreExcludedAccounts(_ id: UUID) {
        guard !isDemo, !snapshotSourcesReadFailed,
              let index = snapshotSources.firstIndex(where: { $0.id == id }) else { return }
        var updated = snapshotSources
        updated[index].excludedAccountIDs = []
        do {
            try save(updated, name: "snapshot-sources.json")
            snapshotSources = updated
            revision += 1
            Task { await refresh() }
        } catch { errorMessage = "账号同步设置未能保存。" }
    }

    func disconnectSnapshotSource(_ id: UUID) {
        guard !isDemo, !snapshotSourcesReadFailed,
              let source = snapshotSources.first(where: { $0.id == id }) else { return }
        let updated = snapshotSources.filter { $0.id != id }
        do {
            // Stop requests first. A failed account-cache cleanup must never
            // resume a connection the user explicitly disconnected.
            try save(updated, name: "snapshot-sources.json")
            snapshotSources = updated
            revision += 1
            for account in accounts.filter({ $0.snapshotSourceID == id }) { remove(account) }
            if source.connection.method == .snapshotURL { CredentialStore.delete(account: id.uuidString) }
        } catch { errorMessage = "无法保存来源变更，请检查本机存储权限。" }
    }

    private func reconcileSnapshotAccounts(_ catalogs: [UUID: SnapshotCatalog]) {
        var updated = accounts
        for source in snapshotSources {
            // Honor an exclusion even if a previous account-list write failed.
            updated.removeAll { $0.snapshotSourceID == source.id && source.excludedAccountIDs.contains($0.sourceAccountID) }
            guard let catalog = catalogs[source.id] else { continue }
            for entry in catalog.entries where !source.excludedAccountIDs.contains(entry.id) {
                if let index = updated.firstIndex(where: { source.owns($0) && $0.sourceAccountID == entry.id }) {
                    updated[index].snapshotSourceID = source.id
                    // Service metadata belongs to the subscribed source. Keep
                    // the local account identity and user name while following
                    // channel refinements such as Gemini CLI / Web / API.
                    updated[index].serviceLabel = entry.serviceLabel
                } else if source.discoversAccounts && entry.shouldDiscover {
                    guard updated.count < 1_000 else { errorMessage = "账号数量超过上限，新增账号未能同步。"; return }
                    var account = source.connection
                    account.id = UUID()
                    account.sourceAccountID = entry.id
                    account.name = entry.serviceLabel
                    account.serviceLabel = entry.serviceLabel
                    account.snapshotSourceID = source.id
                    updated.append(account)
                }
            }
        }
        guard updated != accounts else { return }
        do {
            try save(updated, name: "accounts.json")
            let removed = Set(accounts.map(\.id)).subtracting(updated.map(\.id))
            for id in removed { readings.removeValue(forKey: id); resetCalendarHistory.removeAccount(id) }
            accounts = updated
        } catch { errorMessage = "新增账号未能保存，稍后会再次同步。" }
    }

    func connect(_ config: AccountConfig, secret: String? = nil) async throws {
        guard !connecting, accounts.count < 1_000 else { throw ProviderError.invalidConfiguration }
        connecting = true
        defer { connecting = false }
        guard !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config.name.count <= 80, config.location.count <= 4096,
              !accounts.contains(where: { $0.id == config.id || Self.sameConfiguredSource($0, config) }) else { throw ProviderError.duplicate }
        var savedSecret = false
        if let secret, !secret.isEmpty {
            guard config.method == .snapshotURL, secret.count <= 16384,
                  !secret.contains("\n"), !secret.contains("\r") else { throw ProviderError.invalidConfiguration }
            try CredentialStore.save(Data(secret.utf8), account: config.id.uuidString)
            savedSecret = true
        }
        do {
            let reading = try await client.fetch(config)
            guard config.provider == .snapshot || reading.status == .connected || reading.status == .stale else {
                throw reading.status == .needsAuth ? ProviderError.needsAuth : ProviderError.unavailable
            }
            if let identity = reading.identityKey, readings.values.contains(where: { $0.identityKey == identity }) { throw ProviderError.duplicate }
            if isDemo { exitDemo() }
            var updated = accounts; updated.append(config)
            try save(updated, name: "accounts.json")
            revision += 1
            accounts = updated
            now = Date()
            recordResetHistory(account: config, previous: nil, next: reading)
            readings[config.id] = reading
            rememberMenuReadings()
            rememberAccountEmails()
            rememberMenuChoices()
            errorMessage = nil
            persistReadings()
            persistResetCalendarHistoryIfNeeded()
            publishWidgetSnapshot()
        } catch {
            if savedSecret { CredentialStore.delete(account: config.id.uuidString) }
            throw error
        }
    }

    private static func sameConfiguredSource(_ first: AccountConfig, _ second: AccountConfig) -> Bool {
        guard first.provider == second.provider, first.method == second.method,
              first.location == second.location, first.sourceAccountID == second.sourceAccountID else { return false }
        // An HTTPS endpoint can select different accounts through each Bearer.
        // Its returned identity is checked after reading; the URL cannot prove duplication.
        if first.method == .snapshotURL { return false }
        if first.method == .snapshotSSH {
            return (first.sshHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ==
                (second.sshHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return true
    }

    func remove(_ config: AccountConfig) {
        var updated = accounts
        updated.removeAll { $0.id == config.id }
        do {
            if !isDemo, let sourceID = config.snapshotSourceID,
               let index = snapshotSources.firstIndex(where: { $0.id == sourceID }) {
                guard !snapshotSourcesReadFailed else { throw ProviderError.invalidConfiguration }
                var sources = snapshotSources
                sources[index].excludedAccountIDs.insert(config.sourceAccountID)
                try save(sources, name: "snapshot-sources.json")
                snapshotSources = sources
            }
            if !isDemo { try save(updated, name: "accounts.json") }
            revision += 1
            accounts = updated; readings.removeValue(forKey: config.id)
            rememberMenuReadings()
            rememberAccountEmails()
            rememberMenuChoices()
            if !isDemo {
                if config.method == .snapshotURL && config.snapshotSourceID == nil { CredentialStore.delete(account: config.id.uuidString) }
                pruneExpiryReceipts(at: Date())
                resetCalendarHistory.removeAccount(config.id)
                persistReadings()
                persistResetCalendarHistoryIfNeeded()
                publishWidgetSnapshot()
            }
        } catch { errorMessage = "无法保存账号变更，请检查本机存储权限。" }
    }

    func updateRefreshInterval(_ seconds: Double) {
        guard [10.0, 15, 30, 60, 120].contains(seconds), refreshSeconds != seconds else { return }
        refreshSeconds = seconds
        defaults.set(seconds, forKey: "refreshSeconds")
        schedulePoll()
        if !isDemo { onSavedStateChange?() }
    }

    func setCalendarTimeZone(_ identifier: String) {
        guard identifier != calendarTimeZoneID, identifier == "local" || TimeZone(identifier: identifier) != nil else { return }
        calendarTimeZoneID = identifier
        if !isDemo { defaults.set(identifier, forKey: "resetCalendarTimeZone.v1"); onSavedStateChange?() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                launchAtLogin = SMAppService.mainApp.status == .enabled
                if enabled && !launchAtLogin { errorMessage = "请在系统设置 → 登录项中允许 TokenBar。" }
            } catch { errorMessage = "登录启动设置未成功，请将应用移入 Applications 后重试。" }
        }
    }

    private func schedulePoll() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func load() {
        defer { publishWidgetSnapshot() }
        calendarTimeZoneID = defaults.string(forKey: "resetCalendarTimeZone.v1") ?? "local"
        snapshotSourcesReadFailed = false
        do {
            snapshotSources = try read([SnapshotSource].self, name: "snapshot-sources.json")
            guard snapshotSources.count <= 30, Set(snapshotSources.map(\.id)).count == snapshotSources.count else {
                throw ProviderError.invalidData
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            snapshotSources = []
        } catch {
            snapshotSources = []
            snapshotSourcesReadFailed = true
            errorMessage = "账号同步设置未能读取，原文件已保留。"
        }
        accounts = (try? read([AccountConfig].self, name: "accounts.json")) ?? []
        readings = (try? read([UUID: AccountReading].self, name: "readings.json")) ?? [:]
        readings = readings.filter { id, _ in accounts.contains { $0.id == id } }
        menuReadingCache = (try? read([UUID: MenuReadingCache].self, name: "menu-readings.json")) ?? [:]
        rememberedAccountEmails = (try? read([UUID: RememberedAccountEmail].self, name: "account-emails.json")) ?? [:]
        var invalidatedReading = false
        for account in accounts {
            if let saved = rememberedAccountEmails[account.id], saved.sourceSignature != AccountEmail.sourceSignature(account) {
                if readings.removeValue(forKey: account.id) != nil { invalidatedReading = true }
            }
        }
        // Clear mismatched persisted readings before removing their binding guard;
        // otherwise a second restart could revive the old source's email/balance.
        loadResetCalendarHistory()
        if invalidatedReading {
            do { try save(readings, name: "readings.json") }
            catch { errorMessage = "旧来源缓存未能清理，当前读数已隐藏。"; return }
        }
        rememberAccountEmails()
        rememberMenuReadings()
        rememberMenuChoices(persist: false)
    }

    private func loadResetCalendarHistory() {
        let decoded: ResetCalendarHistory
        resetCalendarHistoryReadFailed = false
        do { decoded = try readResetCalendarHistory() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { decoded = ResetCalendarHistory() }
        catch {
            resetCalendarHistoryReadFailed = true
            resetCalendarHistory = ResetCalendarHistory()
            persistedResetCalendarHistory = resetCalendarHistory
            errorMessage = "重置历史未能读取，原文件已保留。"
            return
        }
        let cleaned = decoded.sanitized(accounts: accounts, readings: readings)
        resetCalendarHistory = cleaned
        if accounts.isEmpty && !decoded.accounts.isEmpty {
            // An unreadable account list must not be treated as deletion of the history file.
            persistedResetCalendarHistory = cleaned
            return
        }
        persistedResetCalendarHistory = decoded
        // Seed from the existing cache before the first network refresh can
        // replace it with a new cycle. This also persists imported source history.
        for account in accounts {
            if let reading = readings[account.id] {
                resetCalendarHistory.incorporate(account: account, previous: nil, next: reading, at: now)
            }
        }
        persistResetCalendarHistoryIfNeeded()
    }

    private func readResetCalendarHistory() throws -> ResetCalendarHistory {
        let url = directory.appendingPathComponent(ResetCalendarHistory.fileName)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= ResetCalendarHistory.maximumStoredBytes else { throw ProviderError.invalidData }
        let data = try Data(contentsOf: url)
        guard data.count <= ResetCalendarHistory.maximumStoredBytes else { throw ProviderError.invalidData }
        return try JSONDecoder().decode(ResetCalendarHistory.self, from: data)
    }

    private func recordResetHistory(account: AccountConfig, previous: AccountReading?, next: AccountReading) {
        guard !isDemo else { return }
        resetCalendarHistory.incorporate(account: account, previous: previous, next: next, at: now)
    }

    private func persistResetCalendarHistoryIfNeeded() {
        guard !isDemo, resetCalendarHistory != persistedResetCalendarHistory else { return }
        guard !resetCalendarHistoryReadFailed else { errorMessage = "重置历史未能读取，原文件已保留。"; return }
        let url = directory.appendingPathComponent(ResetCalendarHistory.fileName)
        do {
            if resetCalendarHistory.accounts.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                let encoded = try JSONEncoder().encode(resetCalendarHistory)
                guard encoded.count <= ResetCalendarHistory.maximumStoredBytes else { throw ProviderError.unavailable }
                try save(resetCalendarHistory, name: ResetCalendarHistory.fileName)
            }
            persistedResetCalendarHistory = resetCalendarHistory
        } catch { errorMessage = ResetCalendarHistory.persistenceError }
    }

    private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_097_152 else { throw ProviderError.invalidData }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(value)
        let destination = directory.appendingPathComponent(name)
        // Create the replacement with private permissions before writing any bytes.
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ProviderError.unavailable }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw ProviderError.unavailable }
    }

    private func persistReadings() {
        guard !isDemo else { return }
        var cache = readings
        for id in cache.keys { cache[id]?.resetHistory = nil }
        do { try save(cache, name: "readings.json") }
        catch { errorMessage = "最新读数未能缓存到本机。" }
    }

    func publishWidgetSnapshot() {
        if !isDemo { onSavedStateChange?() }
        guard let publish = onWidgetSnapshotChange, let snapshot = widgetSnapshot() else { return }
        publish(snapshot)
    }

    func stop() {
        revision += 1
        poll?.invalidate(); poll = nil; clock?.invalidate(); clock = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil; onSavedStateChange = nil; onWidgetSnapshotChange = nil; beforeRefresh = nil
    }

    func cloudKey(_ account: AccountConfig) -> String {
        if let key = account.cloudAccountID { return key }
        if account.snapshotSourceID == godSourceID, godSourceID != nil { return "god:" + account.sourceAccountID }
        if account.snapshotSourceID == syncedSourceID, syncedSourceID != nil { return account.sourceAccountID }
        return "local:" + account.id.uuidString.lowercased()
    }

    func exportCloudRecords() throws -> [String: SyncJSON] {
        var records: [String: SyncJSON] = [:]
        for account in accounts {
            let key = cloudKey(account)
            var reading = readings[account.id]
            if reading?.hasVisibleQuota != true, let saved = menuReadingCache[account.id], saved.matches(account, current: reading) {
                reading = saved.reading; reading?.status = .stale
            }
            records["a:" + key] = try GodSyncProjection.record(account: account, key: key, reading: reading)
            // Future schedules already travel in the latest reading. Unioning
            // them as history could revive a subsequently corrected deadline.
            let history = resetCalendarHistory.records(for: account, reading: readings[account.id]).filter { $0.resetsAt <= now }
            if !history.isEmpty {
                var value: [String: SyncJSON] = ["kind": .string("history"), "accountID": .string(key), "events": try SyncJSON.encode(history)]
                if let epoch = GodSyncProjection.epoch(reading) { value["epoch"] = .string(epoch) }
                if let email = accountEmail(account) { value["emailDigest"] = .string(GodAuthentication.digest(email.lowercased())) }
                records["h:" + key] = .object(value)
            }
        }
        func preference(_ name: String, _ value: SyncJSON) { records["p:" + name] = .object(["kind": .string("preference"), "name": .string(name), "value": value]) }
        func setting(_ name: String, _ value: SyncJSON) { records["s:" + name] = .object(["kind": .string("switch"), "name": .string(name), "value": value]) }
        preference("refreshSeconds", .number(refreshSeconds)); preference("calendarTimeZone", .string(calendarTimeZoneID))
        setting("showsAgentPrefix", .bool(showsAgentPrefix)); setting("expiryAlertsEnabled", .bool(expiryAlertsEnabled))
        setting("menuQuotaSelection", .array(menuMetricCatalog.filter { effectiveMenuSelection.contains($0.id) }.compactMap { metric in
            guard let account = accounts.first(where: { $0.id == metric.accountID }) else { return nil }
            var value: [String: SyncJSON] = ["accountID": .string(cloudKey(account)), "windowID": .string(metric.windowID)]
            if metric.kind == .credits { value["kind"] = .string("credits") }
            return .object(value)
        }))
        setting("enabledAccounts", .object(Dictionary(accounts.map { (cloudKey($0), SyncJSON.bool($0.enabled)) }, uniquingKeysWith: { _, last in last })))
        let excluded = snapshotSources.flatMap { source -> [String] in
            if source.id == godSourceID { return source.excludedAccountIDs.map { "god:" + $0 } }
            if source.id == syncedSourceID { return Array(source.excludedAccountIDs) }
            return []
        }
        setting("excludedAccountIDs", .array(excluded.sorted().map(SyncJSON.string)))
        if let source = snapshotSources.first(where: { $0.id == godSourceID }) { setting("autoDiscoverGodAccounts", .bool(source.discoversAccounts)) }
        return records
    }

    func applyCloudRecords(_ records: [String: SyncJSON], switches: Bool) throws {
        if let value = records["p:refreshSeconds"]?["value"]?.number { updateRefreshInterval(value) }
        if let value = records["p:calendarTimeZone"]?["value"]?.string { setCalendarTimeZone(value) }
        for account in accounts {
            let key = cloudKey(account)
            guard let value = records["h:" + key], value["kind"] == .string("history"),
                  let events = value["events"], let incoming = try? events.decode([QuotaResetRecord].self) else { continue }
            let current = readings[account.id]
            let metadataReading = records["a:" + key]?["reading"].flatMap { try? GodSyncProjection.decodeReading($0) }
            let reference = account.snapshotSourceID == syncedSourceID ? metadataReading : current
            if let old = value["epoch"]?.string, let active = GodSyncProjection.epoch(reference), old != active { continue }
            if let old = value["emailDigest"]?.string, let email = AccountEmail.validated(reference?.email), old != GodAuthentication.digest(email.lowercased()) { continue }
            resetCalendarHistory.mergeSynced(incoming, account: account, reading: current, at: now)
        }
        persistResetCalendarHistoryIfNeeded()
        guard switches else { publishWidgetSnapshot(); return }
        if let value = records["s:showsAgentPrefix"]?["value"]?.bool { setShowsAgentPrefix(value) }
        if let value = records["s:expiryAlertsEnabled"]?["value"]?.bool { setExpiryAlertsEnabled(value) }
        if let values = records["s:enabledAccounts"]?["value"]?.object {
            for index in accounts.indices { if let enabled = values[cloudKey(accounts[index])]?.bool { accounts[index].enabled = enabled } }
            try save(accounts, name: "accounts.json")
        }
        if let values = records["s:excludedAccountIDs"]?["value"]?.array {
            let ids = Set(values.compactMap(\.string))
            for index in snapshotSources.indices {
                if snapshotSources[index].id == godSourceID { snapshotSources[index].excludedAccountIDs = Set(ids.filter { $0.hasPrefix("god:") }.map { String($0.dropFirst(4)) }) }
                if snapshotSources[index].id == syncedSourceID { snapshotSources[index].excludedAccountIDs = ids }
            }
            try save(snapshotSources, name: "snapshot-sources.json")
            for account in accounts where ids.contains(cloudKey(account)) { remove(account) }
        }
        if let value = records["s:autoDiscoverGodAccounts"]?["value"]?.bool, let godSourceID { setAccountDiscovery(godSourceID, enabled: value) }
        if let choices = records["s:menuQuotaSelection"]?["value"]?.array {
            let byKey = Dictionary(accounts.map { (cloudKey($0), $0.id) }, uniquingKeysWith: { first, _ in first })
            menuQuotaSelection = Set(choices.compactMap { choice -> String? in
                guard let key = choice["accountID"]?.string, let id = byKey[key], let window = choice["windowID"]?.string else { return nil }
                return choice["kind"] == .string("credits") ? id.uuidString + "#credits" : MenuQuotaMetric.selectionID(accountID: id, windowID: window)
            })
            rememberMenuChoices()
        }
        publishWidgetSnapshot()
    }

    func promoteSyncedGodAccounts(_ known: Set<String>, source: AccountConfig) throws {
        var changed = false
        for index in accounts.indices {
            let account = accounts[index], key = cloudKey(account)
            guard account.snapshotSourceID == syncedSourceID, key.hasPrefix("god:"), known.contains(key) else { continue }
            accounts[index].location = source.location
            accounts[index].sourceAccountID = String(key.dropFirst(4))
            accounts[index].snapshotSourceID = godSourceID
            accounts[index].cloudAccountID = key
            changed = true
        }
        if changed { try save(accounts, name: "accounts.json") }
    }

    func importCloudSnapshot(_ data: Data, sourceID: UUID) throws {
        guard let source = snapshotSources.first(where: { $0.id == sourceID }) else { throw GodError.invalidResponse }
        let catalog = try SnapshotCatalog.parse(data, source: SnapshotSource.locationKey(source.connection), at: Date())
        let owned = accounts.filter { $0.snapshotSourceID == sourceID }
        let existing = Set(owned.map(\.sourceAccountID))
        let added = catalog.entries.filter { source.discoversAccounts && $0.shouldDiscover && !source.excludedAccountIDs.contains($0.id) }.map(\.id)
        let removed = owned.contains { source.excludedAccountIDs.contains($0.sourceAccountID) }
        if !removed, Set(added).isSubset(of: existing), owned.allSatisfy({ account in
            catalog.entries.first(where: { $0.id == account.sourceAccountID }).map { readings[account.id] == $0.reading } ?? true
        }) { return }
        revision += 1
        reconcileSnapshotAccounts([sourceID: catalog])
        let entries = Dictionary(catalog.entries.map { ($0.id, $0.reading) }, uniquingKeysWith: { _, last in last })
        for account in accounts where account.snapshotSourceID == sourceID {
            if let reading = entries[account.sourceAccountID] {
                recordResetHistory(account: account, previous: readings[account.id], next: reading)
                readings[account.id] = reading
            }
        }
        rememberAccountEmails(); rememberMenuReadings(); rememberMenuChoices()
        persistReadings(); persistResetCalendarHistoryIfNeeded(); publishWidgetSnapshot()
    }

    func loadDemo() {
        revision += 1; isDemo = true
        snapshotSources = []
        menuQuotaSelection = nil
        rememberedMenuMetrics = []
        let codex = AccountConfig(provider: .codex, name: "Personal", method: .localFile, location: "")
        let claude = AccountConfig(provider: .claude, name: "Work", method: .localFile, location: "")
        let grok = AccountConfig(provider: .grok, name: "Builder", method: .grokCLI, location: "")
        let base = Date()
        accounts = [codex, claude, grok]
        readings = [
            codex.id: AccountReading(status: .connected, checkedAt: base, lastSuccessAt: base,
                windows: [QuotaWindow(id: "week", label: "每周", remainingPercent: 32, resetsAt: base.addingTimeInterval(172800), startsAt: base.addingTimeInterval(-432000)),
                          QuotaWindow(id: "reserve", label: "每周", remainingPercent: 100, resetsAt: base.addingTimeInterval(345600), group: "reserve", model: "Luna")],
                credits: 24150.50, resetCardsAvailable: 2, resetCards: [ResetCard(status: "available", expiresAt: base.addingTimeInterval(864000))], name: "Personal", email: "personal@example.com"),
            claude.id: AccountReading(status: .connected, checkedAt: base, lastSuccessAt: base,
                windows: [QuotaWindow(id: "five", label: "5 小时", remainingPercent: 76, resetsAt: base.addingTimeInterval(7200)), QuotaWindow(id: "week", label: "每周", remainingPercent: 58, resetsAt: base.addingTimeInterval(259200))], email: "work@example.com"),
            grok.id: AccountReading(status: .connected, checkedAt: base, lastSuccessAt: base,
                windows: [QuotaWindow(id: "week", label: "每周", remainingPercent: 94, resetsAt: base.addingTimeInterval(36000), startsAt: base.addingTimeInterval(-568800))], email: "builder@example.com")
        ]
        rememberMenuChoices(persist: false)
    }

    func exitDemo() {
        revision += 1; isDemo = false; loadMenuPreferences(); loadExpiryPreferences(); load()
    }

    // Explicit command-line onboarding for this local installation; never runs in shipped first launch.
    func connectLocalAccounts() async {
        for kind in [ProviderKind.codex, .grok] {
            guard FileManager.default.fileExists(atPath: kind.defaultPath), !accounts.contains(where: { $0.provider == kind && $0.location == kind.defaultPath }) else { continue }
            let config = AccountConfig(provider: kind, name: kind.title, method: kind == .grok ? .grokCLI : .localFile, location: kind.defaultPath)
            do { try await connect(config) }
            catch { errorMessage = "\(kind.title)：\((error as? ProviderError ?? .unavailable).message)" }
        }
        await refresh()
    }
}
