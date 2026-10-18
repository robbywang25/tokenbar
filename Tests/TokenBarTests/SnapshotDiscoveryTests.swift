import Foundation
import XCTest
@testable import TokenBar

final class SnapshotDiscoveryTests: XCTestCase {
    func testCatalogAcceptsFutureProvidersAndAdditionalAccountsPreservingUnitsAndAge() throws {
        let old = Date().addingTimeInterval(-600)
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "collectedAt": old.timeIntervalSince1970,
            "accounts": [row("claude-42", at: old)], "additionalAccounts": [row("future-agent", service: "Future Agent", at: old)]])
        let catalog = try SnapshotCatalog.parse(data, source: "fixture", at: Date())
        XCTAssertEqual(catalog.entries.map(\.id), ["claude-42", "future-agent"])
        XCTAssertEqual(catalog.entries.map(\.serviceLabel), ["Claude Code", "Future Agent"])
        XCTAssertTrue(catalog.entries.allSatisfy { $0.reading.status == .stale })
        XCTAssertEqual(catalog.entries[1].reading.windows.first?.unit, "requests")
        XCTAssertEqual(catalog.entries[1].reading.lastSuccessAt!.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCatalogRejectsInvalidEnvelopesAndAmbiguousIDs() throws {
        let good = row("one")
        let bad: [[String: Any]] = [
            ["accounts": [good, good]], ["accounts": [good], "additionalAccounts": [good]],
            ["accounts": [row("bad\nid")]], ["accounts": [row("")]],
            ["accounts": [good], "additionalAccounts": "wrong"], ["accounts": [1]],
            ["accounts": [good], "schemaVersion": true], ["accounts": [good], "schemaVersion": 2],
            ["accounts": (0...1000).map { row("account-\($0)") }]
        ]
        for value in bad {
            XCTAssertThrowsError(try SnapshotCatalog.parse(JSONSerialization.data(withJSONObject: value), source: "fixture", at: Date()))
        }
    }

    @MainActor
    func testLegacyMigrationDiscoversAdditionWithoutRestartAndPreservesMenuHistoryAndUUIDs() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write([row("claude-1")])
        var legacy = f.connection
        legacy.sourceAccountID = "claude-1"; legacy.serviceLabel = "Claude Code"
        try JSONEncoder().encode([legacy]).write(to: f.state.appendingPathComponent("accounts.json"))
        let store = f.store()
        await store.refresh()
        store.setMenuQuota(accountID: legacy.id, windowID: "weekly", enabled: true)
        let selection = store.menuQuotaSelection
        var source = f.connection; source.id = UUID()
        try await store.connectSnapshotSource(source)
        XCTAssertEqual(store.accounts.first?.id, legacy.id)
        XCTAssertEqual(store.accounts.first?.snapshotSourceID, source.id)
        let oldHistory = store.calendarModel().events.count
        try f.write([row("claude-2", email: "new@example.test"), row("claude-1")])
        await store.refresh()
        XCTAssertEqual(store.accounts.map(\.sourceAccountID), ["claude-1", "claude-2"])
        XCTAssertEqual(store.menuQuotaSelection, selection)
        XCTAssertGreaterThan(store.calendarModel().events.count, oldHistory)
        let newAccount = try XCTUnwrap(store.accounts.last)
        XCTAssertEqual(store.accountEmail(newAccount), "new@example.test")
        XCTAssertEqual(store.readings[newAccount.id]?.status, .connected)
        XCTAssertEqual(store.widgetSnapshot()?.accounts.count, 2)
        let restored = f.store()
        await restored.refresh()
        XCTAssertEqual(restored.accounts.map(\.id), store.accounts.map(\.id))
        XCTAssertEqual(restored.menuQuotaSelection, selection)
    }

    @MainActor
    func testMalformedSiblingMissingAccountAndFailedDocumentNeverEraseAccountsOrInventZero() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write([row("one"), row("two")])
        let store = f.store(); try await store.connectSnapshotSource(f.connection)
        let ids = store.accounts.map(\.id)
        let historyCount = store.calendarModel().events.count
        var broken = row("two"); broken["windows"] = [["id": "weekly", "remainingPercent": 900]]
        try f.write([row("one"), broken, row("three")])
        await store.refresh()
        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertEqual(store.readings[ids[0]]?.status, .connected)
        XCTAssertEqual(store.readings[ids[1]]?.reason, "invalid_data")
        XCTAssertTrue(store.readings[ids[1]]!.windows.isEmpty)
        try f.write([row("one")]); await store.refresh()
        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertEqual(store.readings[ids[1]]?.status, .unavailable)
        XCTAssertGreaterThanOrEqual(store.calendarModel().events.count, historyCount)
        try Data("bad-json".utf8).write(to: f.snapshot); await store.refresh()
        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertEqual(store.readings[ids[0]]?.status, .unavailable)
        try f.write([row("one"), row("two")]); await store.refresh()
        XCTAssertEqual(store.readings[ids[1]]?.status, .connected)
        XCTAssertEqual(store.accounts[1].id, ids[1])
    }

    @MainActor
    func testRemovalSurvivesRefreshRestartAndDisablingDiscoveryKeepsExistingReadings() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write([row("one"), row("two")])
        let store = f.store(); try await store.connectSnapshotSource(f.connection)
        store.remove(store.accounts[1]); await store.refresh()
        XCTAssertEqual(store.accounts.map(\.sourceAccountID), ["one"])
        let restored = f.store()
        try f.write([row("one"), row("two"), row("three")])
        restored.setAccountDiscovery(f.connection.id, enabled: false)
        await restored.refresh()
        XCTAssertEqual(restored.accounts.map(\.sourceAccountID), ["one"])
        XCTAssertEqual(restored.readings[restored.accounts[0].id]?.status, .connected)
        restored.setAccountDiscovery(f.connection.id, enabled: true)
        await restored.refresh()
        XCTAssertEqual(restored.accounts.map(\.sourceAccountID), ["one", "three"])
    }

    @MainActor
    func testEmptySlotsAppearWhenConfiguredAndEmptySubscriptionKeepsDiscovering() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write([["id": "pending", "status": "not_configured"], ["id": "chat", "status": "unsupported"]])
        let store = f.store(); try await store.connectSnapshotSource(f.connection)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(store.snapshotSources.count, 1)
        try f.write([row("pending")]); await store.refresh()
        XCTAssertEqual(store.accounts.map(\.sourceAccountID), ["pending"])
    }

    @MainActor
    func testMoreThanThirtyAccountsAndIndependentSourcesWithSameSlotIDs() async throws {
        let f = try Fixture(), other = try Fixture(); defer { f.remove(); other.remove() }
        try f.write((0..<40).map { row("new-\($0)") })
        try other.write([row("new-0", email: "other@example.test")])
        let store = f.store(); try await store.connectSnapshotSource(f.connection)
        try await store.connectSnapshotSource(other.connection)
        XCTAssertEqual(store.accounts.count, 41)
        XCTAssertEqual(Set(store.accounts.map(\.id)).count, 41)
        XCTAssertEqual(store.readings[store.accounts.last!.id]?.email, "other@example.test")
    }

    @MainActor
    func testLegacySingleAccountConnectionDoesNotSilentlySubscribe() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write([row("one"), row("two")])
        var config = f.connection; config.sourceAccountID = "one"
        let store = f.store(); try await store.connect(config); await store.refresh()
        XCTAssertEqual(store.accounts.map(\.sourceAccountID), ["one"])
        XCTAssertTrue(store.snapshotSources.isEmpty)
    }

    @MainActor
    func testDisconnectStopsSourceAndRemovesOnlyItsAccountsAcrossRestart() async throws {
        let f = try Fixture(), other = try Fixture(); defer { f.remove(); other.remove() }
        try f.write([row("one")]); try other.write([row("two")])
        let store = f.store(); try await store.connectSnapshotSource(f.connection)
        try await store.connectSnapshotSource(other.connection)
        store.disconnectSnapshotSource(f.connection.id)
        let restored = f.store(); await restored.refresh()
        XCTAssertEqual(restored.snapshotSources.map(\.id), [other.connection.id])
        XCTAssertEqual(restored.accounts.map(\.sourceAccountID), ["two"])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testOneHTTPSReadPerSourceUsesSourceCredentialForEveryChildAndSurvivesRestart() async throws {
        let f = try Fixture(); defer { f.remove(); DiscoveryURLProtocol.handler = nil }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "collectedAt": Date().timeIntervalSince1970,
            "accounts": [row("one"), row("two")]])
        var source = f.connection; source.method = .snapshotURL; source.location = "https://fixture.example.test/quotas"
        let sourceID = source.id.uuidString
        let counter = RequestCounter()
        DiscoveryURLProtocol.handler = { request in
            counter.increment()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
            return data
        }
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [DiscoveryURLProtocol.self]
        let client = ProviderClient(sessionConfiguration: session, credentialReader: { _, id in
            XCTAssertEqual(id, sourceID)
            return Data("fixture-secret".utf8)
        })
        let store = f.store(client)
        try await store.connectSnapshotSource(source)
        let before = counter.count
        await store.refresh()
        XCTAssertEqual(counter.count, before + 1)
        XCTAssertEqual(store.accounts.count, 2)
        let restored = f.store(client); await restored.refresh()
        XCTAssertEqual(restored.accounts.map(\.id), store.accounts.map(\.id))
        let saved = try String(contentsOf: f.state.appendingPathComponent("snapshot-sources.json"))
        XCTAssertFalse(saved.contains("fixture-secret"))
    }

    @MainActor
    func testDemoNeverPersistsDiscoveredChangesAndCorruptSourceSettingsArePreserved() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write([row("one")]); let store = f.store()
        try await store.connectSnapshotSource(f.connection)
        store.loadDemo(); await store.refresh(); store.exitDemo()
        XCTAssertEqual(store.accounts.map(\.sourceAccountID), ["one"])
        let file = f.state.appendingPathComponent("snapshot-sources.json")
        try Data("corrupted-settings".utf8).write(to: file)
        let restored = f.store(); await restored.refresh()
        XCTAssertEqual(restored.accounts.count, 1)
        XCTAssertEqual(restored.readings[restored.accounts[0].id]?.status, .unavailable)
        XCTAssertEqual(try String(contentsOf: file), "corrupted-settings")
        XCTAssertNotNil(restored.errorMessage)
    }

    private func row(_ id: String, service: String? = nil, email: String = "fixture@example.test", at now: Date = Date()) -> [String: Any] {
        var value: [String: Any] = ["id": id, "status": "connected", "profile": ["email": email],
            "lastSuccessAt": now.timeIntervalSince1970,
            "windows": [["id": "weekly", "label": "每周", "remainingPercent": 70, "remaining": 70, "limit": 100,
                         "unit": "requests", "startsAt": now.addingTimeInterval(-86400).timeIntervalSince1970,
                         "resetsAt": now.addingTimeInterval(518400).timeIntervalSince1970]]]
        if let service { value["serviceLabel"] = service }
        return value
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "TokenBarDiscoveryTests." + UUID().uuidString
    var state: URL { root.appendingPathComponent("state") }
    var snapshot: URL { root.appendingPathComponent("snapshot.json") }
    let connectionID = UUID()
    var connection: AccountConfig {
        AccountConfig(id: connectionID, provider: .snapshot, name: "Fixture source", method: .snapshotFile, location: snapshot.path)
    }
    init() throws { try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true) }
    func write(_ rows: [[String: Any]]) throws {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "collectedAt": Date().timeIntervalSince1970, "accounts": rows]).write(to: snapshot, options: .atomic)
    }
    @MainActor func store(_ client: ProviderClient = ProviderClient()) -> AppStore {
        AppStore(directory: state, client: client, startTimers: false, defaults: UserDefaults(suiteName: suite)!)
    }
    func remove() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}

private final class DiscoveryURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
