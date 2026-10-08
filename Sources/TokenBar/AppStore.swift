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

    private let client: ProviderClient
    private let directory: URL
    private var clock: Timer?
    private var poll: Timer?
    private var revision = 0
    private var wakeObserver: NSObjectProtocol?
    private var connecting = false

    init(directory: URL? = nil, client: ProviderClient = ProviderClient(), startTimers: Bool = true) {
        self.client = client
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TokenBar")
        load()
        let saved = UserDefaults.standard.double(forKey: "refreshSeconds")
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
        guard let first = accounts.first, let reading = readings[first.id], reading.isFresh(at: now),
              let window = reading.windows.first(where: { $0.group == "default" }), let percent = window.remainingPercent else { return "TokenBar" }
        return "TokenBar \(Int(percent.rounded()))%"
    }

    func refresh() async {
        guard !isRefreshing, !isDemo else { return }
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
        if revision == currentRevision { lastRefresh = Date(); persistReadings() }
        now = Date()
        isRefreshing = false
    }

    func connect(_ config: AccountConfig, secret: String? = nil) async throws {
        guard !connecting, accounts.count < 30 else { throw ProviderError.invalidConfiguration }
        connecting = true
        defer { connecting = false }
        guard !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config.name.count <= 80, config.location.count <= 4096,
              !accounts.contains(where: { $0.id == config.id || ($0.provider == config.provider && $0.method == config.method && $0.location == config.location && $0.sourceAccountID == config.sourceAccountID) }) else { throw ProviderError.duplicate }
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
            persistReadings()
            errorMessage = nil
        } catch {
            if savedSecret { CredentialStore.delete(account: config.id.uuidString) }
            throw error
        }
    }

    func remove(_ config: AccountConfig) {
        var updated = accounts
        updated.removeAll { $0.id == config.id }
        do {
            if !isDemo { try save(updated, name: "accounts.json") }
            revision += 1
            accounts = updated; readings.removeValue(forKey: config.id)
            if !isDemo { CredentialStore.delete(account: config.id.uuidString); persistReadings() }
        } catch { errorMessage = "无法保存账号变更，请检查本机存储权限。" }
    }

    func updateRefreshInterval(_ seconds: Double) {
        guard [30.0, 60, 120].contains(seconds) else { return }
        refreshSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "refreshSeconds")
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
    }

    func exitDemo() {
        revision += 1; isDemo = false; load()
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
