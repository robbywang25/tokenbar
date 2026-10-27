import Combine
import Foundation

@MainActor
final class GodWorkspace: ObservableObject {
    @Published private(set) var store: AppStore
    @Published private(set) var syncSwitches = true
    @Published private(set) var isSyncing = false
    @Published private(set) var syncMessage: String?
    @Published private(set) var lastSynced: Date?
    let authentication: GodAuthentication
    private let base: URL
    private let localDefaults: UserDefaults
    private let startTimers: Bool
    private var profile: URL?
    private var epoch = 0
    private var applying = false
    private var preparing = false
    private var journalReadFailed = false
    private var journal = GodSyncJournal()
    private var canonicalAccounts: [String: SyncJSON] = [:]
    private var sharedAccounts: [String: SyncJSON] = [:]
    private var syncTimer: Timer?
    private var editTask: Task<Void, Never>?
    private static let godID = UUID(uuidString: "3F7249E6-0318-4B72-B0F2-A13665A48747")!
    private static let sharedID = UUID(uuidString: "17E044E1-9BB1-4E35-B15B-324B149629DE")!

    init(directory: URL? = nil, defaults: UserDefaults = .standard, http: GodHTTP = GodHTTP(), storage: GodSessionStorage = .live, startTimers: Bool = true) {
        base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TokenBar")
        localDefaults = defaults; self.startTimers = startTimers
        store = AppStore(directory: base, startTimers: startTimers, defaults: defaults)
        authentication = GodAuthentication(directory: base, http: http, storage: storage)
        authentication.onSignIn = { [weak self] user, config in try await self?.activate(user, configuration: config) }
        authentication.onSignOut = { [weak self] in self?.returnToLocal() }
        if startTimers && !CommandLine.arguments.contains("--demo") { Task { await authentication.restore() } }
    }

    private func source(_ id: UUID, name: String, file: String, directory: URL) -> SnapshotSource {
        SnapshotSource(connection: AccountConfig(id: id, provider: .snapshot, name: name, method: .snapshotFile, location: directory.appendingPathComponent(file).path))
    }
    private func activate(_ user: GodUser, configuration: GodConfiguration) async throws {
        guard authentication.user == user, authentication.hasSession else { throw CancellationError() }
        epoch += 1; let run = epoch
        preparing = true
        defer { if run == epoch { preparing = false } }
        let previous = store
        let migration = user.quotaAccess ? try previous.exportCloudRecords() : [:]
        let identity = GodAuthentication.digest(configuration.apiURL + "\n" + user.id)
        let directory = base.appendingPathComponent("GodProfiles").appendingPathComponent(identity)
        let existed = FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot-sources.json").path)
        let defaults = UserDefaults(suiteName: "wang.robby.tokenbar.god." + GodAuthentication.digest(directory.path))!
        for name in ["god-quotas.json", "synced-quotas.json"] where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            try GodAuthentication.savePrivate(Data("{\"schemaVersion\":1,\"accounts\":[]}".utf8), to: directory.appendingPathComponent(name))
        }
        if !existed {
            let sources = [source(Self.godID, name: "God 工作台", file: "god-quotas.json", directory: directory),
                           source(Self.sharedID, name: "已同步账号", file: "synced-quotas.json", directory: directory)]
            try GodAuthentication.savePrivate(JSONEncoder().encode(sources), to: directory.appendingPathComponent("snapshot-sources.json"))
        }
        let stateFile = directory.appendingPathComponent("sync-journal.json")
        journalReadFailed = false
        do {
            if FileManager.default.fileExists(atPath: stateFile.path) {
                let properties = try stateFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw GodError.storage }
                journal = try JSONDecoder().decode(GodSyncJournal.self, from: Data(contentsOf: stateFile))
                try journal.remote.validate()
            } else { journal = GodSyncJournal() }
        } catch { journal = GodSyncJournal(); journalReadFailed = true }
        previous.stop(); syncTimer?.invalidate(); editTask?.cancel()
        profile = directory; canonicalAccounts = [:]; sharedAccounts = [:]; lastSynced = nil; syncMessage = nil
        if journalReadFailed { syncMessage = "本机同步记录未能读取，原文件已保留。" }
        syncSwitches = defaults.object(forKey: "syncSwitches.v1") == nil || defaults.bool(forKey: "syncSwitches.v1")
        let next = AppStore(directory: directory, startTimers: startTimers, defaults: defaults)
        next.godSourceID = Self.godID; next.syncedSourceID = Self.sharedID
        store = next
        next.beforeRefresh = { [weak self] in await self?.refreshQuotas(run: run) }
        next.onSavedStateChange = { [weak self] in self?.captureLocalEdits() }
        await next.refresh()
        guard epoch == run else { return }
        // Only the authenticated quota owner may migrate this Mac's pre-login
        // records. Other God subjects always start from their own cloud profile.
        let seeds = !existed && user.quotaAccess ? remapMigration(migration, previous: previous) : [:]
        preparing = false
        await synchronize(seeds: seeds)
        if startTimers, run == epoch {
            syncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.synchronize() }
            }
        }
    }

    private func remapMigration(_ records: [String: SyncJSON], previous: AppStore) -> [String: SyncJSON] {
        var mapping: [String: String] = [:]
        for account in previous.accounts {
            let key = "god:" + account.sourceAccountID
            guard let canonical = canonicalAccounts["a:" + key] else { continue }
            let sameEmail = previous.accountEmail(account).map { canonical["reading"]?["email"]?.string?.lowercased() == $0.lowercased() } ?? false
            let sameEpoch = previous.readings[account.id]?.resetHistoryIdentity.map { canonical["reading"]?["resetHistoryIdentity"]?.string == $0 } ?? false
            let registeredSource = account.snapshotSourceID.map { authentication.connection?.migrationSourceIDs?.contains($0) == true } ?? false
            guard sameEmail || sameEpoch || registeredSource else { continue }
            mapping[previous.cloudKey(account)] = key
        }
        func remap(_ value: SyncJSON) -> SyncJSON {
            switch value {
            case .string(let text): return .string(mapping[text] ?? text)
            case .array(let values): return .array(values.map(remap))
            case .object(let values): return .object(Dictionary(values.map { (mapping[$0.key] ?? $0.key, remap($0.value)) }, uniquingKeysWith: { _, last in last }))
            default: return value
            }
        }
        var result: [String: SyncJSON] = [:]
        for (key, value) in records {
            let prefix = String(key.prefix(2)), id = String(key.dropFirst(2))
            let nextKey = prefix + (mapping[id] ?? id)
            var mapped = remap(value)
            if prefix == "a:", let mappedID = mapping[id], var object = mapped.object {
                object["source"] = .string("god"); object["accountID"] = .string(mappedID); mapped = .object(object)
            }
            result[nextKey] = mapped
        }
        return result
    }

    private func refreshQuotas(run: Int) async {
        guard epoch == run, let profile, let user = authentication.user else { return }
        guard user.quotaAccess else { quarantineQuotas(profile: profile); return }
        let range = store.trendRange
        do {
            let response = try await authentication.request(path: range.godPath, limit: ProviderClient.maximumBytes)
            guard response.status == 200 else { throw response.status == 403 ? GodError.denied : .unavailable }
            let envelope = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            guard envelope?["historyRange"] as? String == range.rawValue ||
                    (range == .hour && envelope?["historyRange"] == nil) else { throw GodError.invalidResponse }
            let catalog = try SnapshotCatalog.parse(response.data, source: "god", at: Date())
            guard epoch == run, store.trendRange == range else { return }
            try GodAuthentication.savePrivate(response.data, to: profile.appendingPathComponent("god-quotas.json"))
            store.setQuotaSourceAuthorization(Self.godID, allowed: true)
            var records: [String: SyncJSON] = [:]
            for entry in catalog.entries where entry.shouldDiscover {
                let config = AccountConfig(provider: .snapshot, name: entry.serviceLabel, method: .snapshotFile,
                    location: "", sourceAccountID: entry.id, serviceLabel: entry.serviceLabel)
                records["a:god:" + entry.id] = try GodSyncProjection.record(account: config, key: "god:" + entry.id, reading: entry.reading)
            }
            canonicalAccounts = records
            if let source = store.snapshotSources.first(where: { $0.id == Self.godID }) {
                try store.promoteSyncedGodAccounts(Set(records.keys.map { String($0.dropFirst(2)) }), source: source.connection)
            }
        } catch is CancellationError { }
        catch {
            guard epoch == run else { return }
            if error as? GodError == .signedOut { authentication.signOut() }
            else if error as? GodError == .denied { quarantineQuotas(profile: profile) }
            else { syncMessage = GodError.unavailable.localizedDescription }
        }
    }

    private func quarantineQuotas(profile: URL) {
        canonicalAccounts = [:]
        store.setQuotaSourceAuthorization(Self.godID, allowed: false)
        // The persisted per-source barrier remains effective even if replacing
        // the old quota file fails. Independent local sources are untouched.
        try? GodAuthentication.savePrivate(Data("{\"schemaVersion\":1,\"accounts\":[]}".utf8),
                                           to: profile.appendingPathComponent("god-quotas.json"))
        syncMessage = "额度授权暂不可用，稍后刷新会重新验证。"
    }

    private func localRecords() throws -> [String: SyncJSON] {
        var records = try store.exportCloudRecords()
        // Read-only replicas retain the originating device's identity guards;
        // they must not echo their local cache path-derived identity upstream.
        for account in store.accounts where account.snapshotSourceID == Self.sharedID {
            let key = "a:" + store.cloudKey(account)
            if let original = sharedAccounts[key] { records[key] = original }
        }
        for (key, value) in canonicalAccounts { records[key] = value }
        if !syncSwitches { records = records.filter { !$0.key.hasPrefix("s:") } }
        return records
    }
    private func captureLocalEdits() {
        guard profile != nil, !journalReadFailed, !applying, !preparing, !store.isDemo else { return }
        do { journal.capture(try localRecords(), switches: syncSwitches); try persistJournal() }
        catch { syncMessage = GodError.storage.localizedDescription; return }
        guard journal.initialized, !journal.pending.isEmpty else { return }
        editTask?.cancel()
        editTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000); try Task.checkCancellation(); self?.editTask = nil; await self?.synchronize() }
            catch { }
        }
    }

    func setSyncSwitches(_ enabled: Bool) {
        guard profile != nil, !journalReadFailed else { return }
        syncSwitches = enabled; store.preferences.set(enabled, forKey: "syncSwitches.v1")
        journal.pending = journal.pending.filter { !$0.key.hasPrefix("s:") }
        do {
            // Enabling follows the shared layout first; disabling keeps the
            // current local layout and drops unsent switch-only mutations.
            if enabled {
                applying = true
                try store.applyCloudRecords(journal.remote.records.filter { $0.key.hasPrefix("s:") }, switches: true)
                applying = false
            }
            journal.baseline = try localRecords(); try persistJournal()
        } catch { applying = false; syncMessage = GodError.storage.localizedDescription }
        Task { await synchronize() }
    }

    func synchronize(seeds: [String: SyncJSON] = [:]) async {
        guard !isSyncing, !preparing, !journalReadFailed, profile != nil, authentication.hasSession else { return }
        let run = epoch
        isSyncing = true
        defer { if epoch == run { isSyncing = false } }
        do {
            if journal.initialized { journal.capture(try localRecords(), switches: syncSwitches) }
            for _ in 0..<4 {
                let response = try await authentication.request(path: "/sync")
                guard response.status == 200 else { throw GodError.unavailable }
                let remote = try JSONDecoder().decode(GodSyncDocument.self, from: response.data); try remote.validate()
                guard epoch == run else { return }
                journal.rebase(remote, switches: syncSwitches)
                if !journal.initialized {
                    if remote.revision == 0 {
                        journal.pending = seeds.filter { syncSwitches || !$0.key.hasPrefix("s:") }
                        try applyRemote(journal.pending, run: run)
                        for (key, value) in try localRecords() where journal.pending[key] == nil { journal.pending[key] = value }
                    } else {
                        try applyRemote(remote.records, run: run)
                        for (key, value) in try localRecords() where remote.records[key] == nil && !key.hasPrefix("s:") && !key.hasPrefix("p:") { journal.pending[key] = value }
                    }
                    journal.initialized = true
                } else {
                    try applyRemote(remote.records.filter { journal.pending[$0.key] == nil }, run: run)
                }
                guard epoch == run else { return }
                journal.baseline = try localRecords(); try persistJournal()
                if journal.pending.isEmpty { lastSynced = Date(); syncMessage = nil; return }
                let patch = journal.patch()
                let result = try await authentication.request(path: "/sync", method: "PATCH", body: JSONEncoder().encode(patch))
                guard epoch == run else { return }
                if result.status == 409 { continue }
                guard result.status == 200 else { throw GodError.unavailable }
                let accepted = try JSONDecoder().decode(GodSyncDocument.self, from: result.data); try accepted.validate()
                journal.acknowledge(patch, document: accepted)
                try applyRemote(accepted.records.filter { journal.pending[$0.key] == nil }, run: run)
                journal.baseline = try localRecords(); try persistJournal()
                lastSynced = Date(); syncMessage = nil
                if journal.pending.isEmpty { return }
            }
            syncMessage = "剩余内容将在下次同步继续。"
        } catch is CancellationError { }
        catch {
            guard epoch == run else { return }
            if error as? GodError == .signedOut { authentication.signOut() }
            else { syncMessage = (error as? GodError ?? .unavailable).localizedDescription }
        }
    }

    private func applyRemote(_ records: [String: SyncJSON], run: Int) throws {
        guard let profile, epoch == run else { return }
        applying = true
        defer { if epoch == run { applying = false } }
        var cache: [SyncJSON] = []
        let activeKeys = Set(canonicalAccounts.keys).union(store.accounts.filter { $0.snapshotSourceID != Self.sharedID }.map { "a:" + store.cloudKey($0) })
        for (key, value) in records where key.hasPrefix("a:") {
            if value == .null {
                sharedAccounts.removeValue(forKey: key)
                for account in store.accounts where account.snapshotSourceID == Self.sharedID && "a:" + store.cloudKey(account) == key { store.remove(account) }
            } else { sharedAccounts[key] = value }
        }
        for (key, value) in sharedAccounts where !activeKeys.contains(key) {
            if let portable = try? GodSyncProjection.portableAccount(value) { cache.append(portable) }
        }
        let snapshot = SyncJSON.object(["schemaVersion": .number(1), "accounts": .array(cache)])
        let data = try JSONEncoder().encode(snapshot)
        try GodAuthentication.savePrivate(data, to: profile.appendingPathComponent("synced-quotas.json"))
        try store.importCloudSnapshot(data, sourceID: Self.sharedID)
        try store.applyCloudRecords(records, switches: syncSwitches)
    }

    private func persistJournal() throws {
        guard let profile else { return }
        let bytes = try JSONEncoder().encode(journal)
        guard bytes.count <= 64 * 1024 * 1024 else { throw GodError.storage }
        try GodAuthentication.savePrivate(bytes, to: profile.appendingPathComponent("sync-journal.json"))
    }
    private func returnToLocal() {
        epoch += 1; store.stop(); syncTimer?.invalidate(); syncTimer = nil; editTask?.cancel(); editTask = nil
        profile = nil; journal = GodSyncJournal(); journalReadFailed = false; canonicalAccounts = [:]; sharedAccounts = [:]
        isSyncing = false; preparing = false; applying = false; lastSynced = nil; syncMessage = nil; syncSwitches = true
        store = AppStore(directory: base, startTimers: startTimers, defaults: localDefaults)
        if startTimers { Task { await store.refresh() } }
    }
    func stop() { epoch += 1; store.stop(); syncTimer?.invalidate(); editTask?.cancel() }
}
