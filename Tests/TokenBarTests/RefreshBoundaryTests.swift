import Foundation
import XCTest
@testable import TokenBar

final class RefreshBoundaryTests: XCTestCase {
    @MainActor
    func testRevocationDuringCatalogReadCannotRestoreBalancesOrDiscoverAccounts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ReadGate(data: fixture.document)
        let client = ProviderClient(credentialReader: { _, _ in XCTFail("No credential reads expected"); throw ProviderError.needsAuth },
                                    sshReader: { _ in await gate.read() })
        let store = fixture.store(client: client)
        defer { store.stop() }
        let independent = try fixture.independentFileAccount()
        store.accounts.append(independent)
        let refresh = Task { await store.refresh() }
        await gate.waitUntilStarted()
        store.setQuotaSourceAuthorization(fixture.source.id, allowed: false)
        XCTAssertEqual(store.readings[fixture.account.id]?.status, .needsAuth)
        await gate.release()
        await refresh.value
        XCTAssertEqual(store.readings[fixture.account.id]?.status, .needsAuth)
        XCTAssertTrue(store.readings[fixture.account.id]?.windows.isEmpty == true)
        XCTAssertEqual(store.accounts.map(\.id), [fixture.account.id, independent.id])
        XCTAssertEqual(store.readings[independent.id]?.windows.first?.remainingPercent, 42)
        XCTAssertFalse(store.menuTitle.contains("73"))
        let persisted = fixture.store(client: client)
        defer { persisted.stop() }
        XCTAssertEqual(persisted.readings[fixture.account.id]?.status, .needsAuth)
    }

    @MainActor
    func testRegrantCannotAuthorizeAResponseStartedBeforeRevocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ReadGate(data: fixture.document)
        let store = fixture.store(client: ProviderClient(sshReader: { _ in await gate.read() }))
        defer { store.stop() }
        let refresh = Task { await store.refresh() }
        await gate.waitUntilStarted()
        store.setQuotaSourceAuthorization(fixture.source.id, allowed: false)
        store.setQuotaSourceAuthorization(fixture.source.id, allowed: true)
        await gate.release()
        await refresh.value
        XCTAssertEqual(store.readings[fixture.account.id]?.status, .needsAuth)
        XCTAssertTrue(store.readings[fixture.account.id]?.windows.isEmpty == true)
        XCTAssertEqual(store.accounts.map(\.id), [fixture.account.id])
    }

    @MainActor
    func testRevocationWhileIndependentAccountLoadsPreservesQuarantineAndIndependentResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ReadGate(data: fixture.document)
        // The subscription is read from a file before the standalone SSH read
        // starts. Revoking it now exercises the second suspension boundary.
        var source = fixture.source
        let file = fixture.root.appendingPathComponent("catalog.json")
        try fixture.document.write(to: file)
        source.connection.method = .snapshotFile; source.connection.location = file.path
        try JSONEncoder().encode([source]).write(to: fixture.root.appendingPathComponent("snapshot-sources.json"))
        let secondStore = fixture.store(client: ProviderClient(sshReader: { _ in await gate.read() }))
        defer { secondStore.stop() }
        var independent = fixture.account
        independent.id = UUID(); independent.snapshotSourceID = nil
        secondStore.accounts.append(independent)
        let refresh = Task { await secondStore.refresh() }
        await gate.waitUntilStarted()
        secondStore.setQuotaSourceAuthorization(fixture.source.id, allowed: false)
        await gate.release()
        await refresh.value
        for account in secondStore.accounts where account.snapshotSourceID == fixture.source.id {
            XCTAssertEqual(secondStore.readings[account.id]?.status, .needsAuth)
            XCTAssertTrue(secondStore.readings[account.id]?.windows.isEmpty == true)
        }
        XCTAssertEqual(secondStore.readings[independent.id]?.status, .connected)
        XCTAssertEqual(secondStore.readings[independent.id]?.windows.first?.remainingPercent, 73)
    }

    @MainActor
    func testStopCancelsPendingRangeRefreshAndRejectsLaterRefreshCalls() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ReadGate(data: fixture.document)
        let store = fixture.store(client: ProviderClient(sshReader: { _ in await gate.read() }))
        let refresh = Task { await store.refresh() }
        await gate.waitUntilStarted()
        store.setTrendRange(.day)
        store.stop()
        await gate.release()
        await refresh.value
        // Allow a queued range task to run, then exercise a callback that had
        // already captured the retired profile before its timers were stopped.
        for _ in 0..<20 { await Task.yield() }
        await store.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.lastRefresh)
        XCTAssertNil(store.readings[fixture.account.id])
        XCTAssertEqual(store.accounts.map(\.id), [fixture.account.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("readings.json").path))
    }

    @MainActor
    func testStopRejectsSlowConnectionsBeforeTheyModifyTheRetiredProfile() async throws {
        for subscribes in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let gate = ReadGate(data: fixture.document)
            let store = fixture.store(client: ProviderClient(sshReader: { _ in await gate.read() }))
            var connection = fixture.source.connection
            connection.id = UUID(); connection.location += ".new"
            connection.sourceAccountID = "known"
            let pending = Task { () -> Bool in
                do {
                    if subscribes { try await store.connectSnapshotSource(connection) }
                    else { try await store.connect(connection) }
                    return false
                } catch is CancellationError { return true }
                catch { XCTFail("Unexpected connection error: \(error)"); return false }
            }
            await gate.waitUntilStarted()
            store.stop()
            await gate.release()
            let cancelled = await pending.value
            XCTAssertTrue(cancelled)
            XCTAssertEqual(store.accounts.map(\.id), [fixture.account.id])
            XCTAssertEqual(store.snapshotSources.map(\.id), [fixture.source.id])
            XCTAssertNil(store.readings[connection.id])
            let persisted = fixture.store(client: ProviderClient(sshReader: { _ in await gate.read() }))
            defer { persisted.stop() }
            XCTAssertEqual(persisted.accounts.map(\.id), [fixture.account.id])
            XCTAssertEqual(persisted.snapshotSources.map(\.id), [fixture.source.id])
        }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TokenBar.RefreshBoundary." + UUID().uuidString
        let source: SnapshotSource
        let account: AccountConfig
        let document: Data
        init() throws {
            let connection = AccountConfig(provider: .snapshot, name: "Synthetic source", method: .snapshotSSH,
                location: "/synthetic-" + UUID().uuidString + ".json", sshHost: "fixture-host")
            source = SnapshotSource(connection: connection)
            var child = connection
            child.id = UUID(); child.sourceAccountID = "known"; child.snapshotSourceID = source.id
            account = child
            let now = Date().timeIntervalSince1970
            document = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "collectedAt": now,
                "accounts": ["known", "newly-discovered"].map { id in
                    ["id": id, "product": "codex", "status": "connected", "lastSuccessAt": now,
                     "windows": [["id": "weekly", "label": "每周", "remainingPercent": 73]]] as [String: Any]
                }])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode([source]).write(to: root.appendingPathComponent("snapshot-sources.json"))
            try JSONEncoder().encode([account]).write(to: root.appendingPathComponent("accounts.json"))
        }
        func store(client: ProviderClient) -> AppStore {
            AppStore(directory: root, client: client, startTimers: false, defaults: UserDefaults(suiteName: suite)!)
        }
        func independentFileAccount() throws -> AccountConfig {
            let file = root.appendingPathComponent("independent.json")
            let data = try JSONSerialization.data(withJSONObject: ["id": "independent", "status": "connected",
                "lastSuccessAt": Date().timeIntervalSince1970,
                "windows": [["id": "weekly", "label": "每周", "remainingPercent": 42]]])
            try data.write(to: file)
            return AccountConfig(provider: .snapshot, name: "Independent fixture", method: .snapshotFile, location: file.path)
        }
        func remove() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private actor ReadGate {
    let data: Data
    private var started = false
    private var released = false
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var reads: [CheckedContinuation<Data, Never>] = []
    init(data: Data) { self.data = data }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { starts.append($0) }
    }
    func read() async -> Data {
        started = true
        starts.forEach { $0.resume() }; starts = []
        if released { return data }
        return await withCheckedContinuation { reads.append($0) }
    }
    func release() {
        released = true
        reads.forEach { $0.resume(returning: data) }; reads = []
    }
}
