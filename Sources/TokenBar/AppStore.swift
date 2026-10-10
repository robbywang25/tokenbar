import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppStore: ObservableObject {
    @Published var accounts: [AccountConfig] = []
    @Published var readings: [UUID: AccountReading] = [:]
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?
    @Published var refreshSeconds: Double = 30
    @Published var launchAtLogin = false
    @Published var now = Date()
    @Published var isDemo = false
    // nil preserves the initial one-metric default; [] is an explicit opt-out.
    @Published private(set) var menuQuotaSelection: Set<String>?
    @Published private(set) var rememberedMenuMetrics: [MenuQuotaMetric] = []
    @Published private(set) var expiryAlertsEnabled = true
    @Published private(set) var showsAgentPrefix = true

    private var rememberedAccountEmails: [UUID: RememberedAccountEmail] = [:]
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

    init(directory: URL? = nil, client: ProviderClient = ProviderClient(), startTimers: Bool = true, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TokenBar")
        loadMenuPreferences()
        loadExpiryPreferences()
        load()
        let saved = defaults.double(forKey: "refreshSeconds")
        if [30.0, 60, 120].contains(saved) { refreshSeconds = saved }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if startTimers {
            // Freshness boundaries are coarse. Per-second countdowns live in
            // isolated TimelineViews so scrolling never invalidates the full list.
            clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            }
            schedulePoll()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
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
        showsAgentPrefix = enabled
        if !isDemo { defaults.set(enabled, forKey: Self.agentPrefixKey) }
    }

    func setExpiryAlertsEnabled(_ enabled: Bool) {
        expiryAlertsEnabled = enabled
        if !isDemo { defaults.set(enabled, forKey: Self.expiryEnabledKey) }
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
            else if metric.kind == .credits, let reading = readings[metric.accountID] {
                if reading.unlimitedCredits { detail = "不限量" }
                else if let credits = reading.credits { detail = Self.exactCredits(credits) + " 点" }
                else { detail = "当前未知" }
            } else { detail = value }
            return "\(metric.accountName) · \(metric.windowLabel)：\(detail)"
        }.joined(separator: "\n")
    }

    var availableMenuMetrics: [MenuQuotaMetric] {
        menuMetricCatalog.filter(\.isVisibleInUI)
    }

    // Keep the complete label catalog and stored selection IDs, including
    // hidden metrics. Presentation filtering must not rewrite user choices.
    private var menuMetricCatalog: [MenuQuotaMetric] {
        accounts.flatMap { account -> [MenuQuotaMetric] in
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
    }

    private var effectiveMenuSelection: Set<String> {
        if let menuQuotaSelection { return menuQuotaSelection }
        guard let metric = availableMenuMetrics.first(where: { metric in
            metric.kind != .credits && metric.group == "default" && accounts.contains(where: { $0.id == metric.accountID && $0.enabled })
        }) else { return [] }
        return [metric.id]
    }

    private var selectedMenuMetrics: [MenuQuotaMetric] {
        let selected = effectiveMenuSelection
        return availableMenuMetrics.filter { selected.contains($0.id) }
    }

    private func menuValue(_ metric: MenuQuotaMetric) -> String {
        guard accounts.contains(where: { $0.id == metric.accountID && $0.enabled }),
              let reading = readings[metric.accountID], reading.isFresh(at: now) else { return "—" }
        if metric.kind == .credits {
            if reading.unlimitedCredits { return "∞" }
            guard let credits = reading.credits, credits.isFinite, credits >= 0 else { return "—" }
            return Self.compactCredits(credits)
        }
        guard let percent = reading.visibleWindows.first(where: { $0.id == metric.windowID })?.remainingPercent,
              percent.isFinite, (0...100).contains(percent) else { return "—" }
        return "\(Int(percent.rounded()))%"
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
        rememberAccountEmails()
        rememberMenuChoices()
        isRefreshing = true
        let currentRevision = revision
        let configs = accounts.filter(\.enabled)
        let provider = client
        await withTaskGroup(of: (UUID, AccountReading).self) { group in
            for config in configs {
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
            var identities = Set<String>()
            for config in configs {
                let id = config.id
                guard revision == currentRevision, var reading = results[id], accounts.contains(where: { $0.id == id }) else { continue }
                if let identity = reading.identityKey, !identities.insert(identity).inserted {
                    reading = AccountReading(status: .notConfigured, checkedAt: Date(), lastSuccessAt: nil, detail: ProviderError.duplicate.message)
                }
                readings[id] = reading
            }
        }
        if revision == currentRevision { lastRefresh = Date(); rememberAccountEmails(); rememberMenuChoices(); persistReadings() }
        now = Date()
        isRefreshing = false
    }

    func connect(_ config: AccountConfig, secret: String? = nil) async throws {
        guard !connecting, accounts.count < 30 else { throw ProviderError.invalidConfiguration }
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
            readings[config.id] = reading
            rememberAccountEmails()
            rememberMenuChoices()
            persistReadings()
            errorMessage = nil
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
            if !isDemo { try save(updated, name: "accounts.json") }
            revision += 1
            accounts = updated; readings.removeValue(forKey: config.id)
            rememberAccountEmails()
            rememberMenuChoices()
            if !isDemo {
                if config.method == .snapshotURL { CredentialStore.delete(account: config.id.uuidString) }
                pruneExpiryReceipts(at: Date())
                persistReadings()
            }
        } catch { errorMessage = "无法保存账号变更，请检查本机存储权限。" }
    }

    func updateRefreshInterval(_ seconds: Double) {
        guard [30.0, 60, 120].contains(seconds) else { return }
        refreshSeconds = seconds
        defaults.set(seconds, forKey: "refreshSeconds")
        schedulePoll()
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
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func load() {
        accounts = (try? read([AccountConfig].self, name: "accounts.json")) ?? []
        readings = (try? read([UUID: AccountReading].self, name: "readings.json")) ?? [:]
        readings = readings.filter { id, _ in accounts.contains { $0.id == id } }
        rememberedAccountEmails = (try? read([UUID: RememberedAccountEmail].self, name: "account-emails.json")) ?? [:]
        var invalidatedReading = false
        for account in accounts {
            if let saved = rememberedAccountEmails[account.id], saved.sourceSignature != AccountEmail.sourceSignature(account) {
                if readings.removeValue(forKey: account.id) != nil { invalidatedReading = true }
            }
        }
        // Clear mismatched persisted readings before removing their binding guard;
        // otherwise a second restart could revive the old source's email/balance.
        if invalidatedReading {
            do { try save(readings, name: "readings.json") }
            catch { errorMessage = "旧来源缓存未能清理，当前读数已隐藏。"; return }
        }
        rememberAccountEmails()
        rememberMenuChoices(persist: false)
    }

    private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_097_152 else { throw ProviderError.invalidData }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, name: String) throws {
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
        do { try save(readings, name: "readings.json") }
        catch { errorMessage = "最新读数未能缓存到本机。" }
    }

    func loadDemo() {
        revision += 1; isDemo = true
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
