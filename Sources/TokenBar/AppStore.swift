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

    private let client: ProviderClient
    private let directory: URL
    private let defaults: UserDefaults
    private static let menuSelectionKey = "menuQuotaSelection.v1"
    private static let menuMetricsKey = "menuQuotaMetrics.v1"
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

    var menuTitle: String {
        let values = selectedMenuMetrics.map(menuValue)
        return values.isEmpty ? "—" : values.joined(separator: " · ")
    }

    var menuTooltip: String {
        let metrics = selectedMenuMetrics
        guard !metrics.isEmpty else { return "未选择菜单栏额度" }
        return metrics.map { metric in
            let value = menuValue(metric)
            return "\(metric.accountName) · \(metric.windowLabel)：\(value == "—" ? "当前未知" : value)"
        }.joined(separator: "\n")
    }

    var availableMenuMetrics: [MenuQuotaMetric] {
        accounts.flatMap { account -> [MenuQuotaMetric] in
            let current = (readings[account.id]?.windows ?? []).filter { $0.remainingPercent != nil }.map { window in
                MenuQuotaMetric(accountID: account.id, windowID: window.id, accountName: account.name,
                                windowLabel: window.title + (window.model.map { " · " + $0 } ?? ""), group: window.group)
            }
            let currentIDs = Set(current.map(\.id))
            let previous = rememberedMenuMetrics.filter { $0.accountID == account.id && !currentIDs.contains($0.id) }.map { metric in
                var metric = metric
                metric.accountName = account.name
                return metric
            }
            return current + previous
        }
    }

    func menuQuotaSelected(accountID: UUID, windowID: String) -> Bool {
        effectiveMenuSelection.contains(MenuQuotaMetric.selectionID(accountID: accountID, windowID: windowID))
    }

    func setMenuQuota(accountID: UUID, windowID: String, enabled: Bool) {
        let id = MenuQuotaMetric.selectionID(accountID: accountID, windowID: windowID)
        guard availableMenuMetrics.contains(where: { $0.id == id }) else { return }
        var selection = effectiveMenuSelection
        if enabled { selection.insert(id) } else { selection.remove(id) }
        menuQuotaSelection = selection
        rememberMenuChoices()
    }

    private var effectiveMenuSelection: Set<String> {
        if let menuQuotaSelection { return menuQuotaSelection }
        guard let metric = availableMenuMetrics.first(where: { metric in
            metric.group == "default" && accounts.contains(where: { $0.id == metric.accountID && $0.enabled })
        }) else { return [] }
        return [metric.id]
    }

    private var selectedMenuMetrics: [MenuQuotaMetric] {
        let selected = effectiveMenuSelection
        return availableMenuMetrics.filter { selected.contains($0.id) }
    }

    private func menuValue(_ metric: MenuQuotaMetric) -> String {
        guard accounts.contains(where: { $0.id == metric.accountID && $0.enabled }),
              let reading = readings[metric.accountID], reading.isFresh(at: now),
              let percent = reading.windows.first(where: { $0.id == metric.windowID })?.remainingPercent,
              percent.isFinite, (0...100).contains(percent) else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private func loadMenuPreferences() {
        menuQuotaSelection = defaults.stringArray(forKey: Self.menuSelectionKey).map(Set.init)
        if let data = defaults.data(forKey: Self.menuMetricsKey), data.count <= 1_048_576,
           let metrics = try? JSONDecoder().decode([MenuQuotaMetric].self, from: data), metrics.count <= 1_920 {
            rememberedMenuMetrics = metrics
        } else { rememberedMenuMetrics = [] }
    }

    private func rememberMenuChoices(persist: Bool = true) {
        rememberedMenuMetrics = availableMenuMetrics
        if let selection = menuQuotaSelection {
            let prefixes = accounts.map { $0.id.uuidString + "/" }
            menuQuotaSelection = selection.filter { id in prefixes.contains(where: id.hasPrefix) }
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
        if revision == currentRevision { lastRefresh = Date(); rememberMenuChoices(); persistReadings() }
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
            rememberMenuChoices()
            if !isDemo {
                if config.method == .snapshotURL { CredentialStore.delete(account: config.id.uuidString) }
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
                credits: 24150.50, resetCardsAvailable: 2, resetCards: [ResetCard(status: "available", expiresAt: base.addingTimeInterval(864000))], name: "Personal"),
            claude.id: AccountReading(status: .connected, checkedAt: base, lastSuccessAt: base,
                windows: [QuotaWindow(id: "five", label: "5 小时", remainingPercent: 76, resetsAt: base.addingTimeInterval(7200)), QuotaWindow(id: "week", label: "每周", remainingPercent: 58, resetsAt: base.addingTimeInterval(259200))]),
            grok.id: AccountReading(status: .connected, checkedAt: base, lastSuccessAt: base,
                windows: [QuotaWindow(id: "week", label: "每周", remainingPercent: 94, resetsAt: base.addingTimeInterval(36000), startsAt: base.addingTimeInterval(-568800))])
        ]
        rememberMenuChoices(persist: false)
    }

    func exitDemo() {
        revision += 1; isDemo = false; loadMenuPreferences(); load()
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
