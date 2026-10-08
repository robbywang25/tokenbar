import Foundation
import XCTest
@testable import TokenBar

final class AppStoreTests: XCTestCase {
    @MainActor
    func testConnectPersistsPrivateFilesAndReloadsOnlyConfiguredAccounts() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        let store = AppStore(directory: fixture.state, startTimers: false)
        try await store.connect(config)
        XCTAssertEqual(store.accounts, [config])
        XCTAssertEqual(store.readings[config.id]?.windows.first?.remainingPercent, 37)
        for file in ["accounts.json", "readings.json"] {
            let values = try FileManager.default.attributesOfItem(atPath: fixture.state.appendingPathComponent(file).path)
            XCTAssertEqual((values[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let directoryValues = try FileManager.default.attributesOfItem(atPath: fixture.state.path)
        XCTAssertEqual((directoryValues[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        var cache = store.readings
        let orphanID = UUID()
        cache[orphanID] = AccountReading(status: .connected, checkedAt: Date(), lastSuccessAt: Date())
        try JSONEncoder().encode(cache).write(to: fixture.state.appendingPathComponent("readings.json"))
        let restored = AppStore(directory: fixture.state, startTimers: false)
        XCTAssertEqual(restored.accounts, [config])
        XCTAssertEqual(restored.readings[config.id], store.readings[config.id])
        XCTAssertNil(restored.readings[orphanID])
    }

    @MainActor
    func testDifferentSnapshotAliasesCannotDuplicateOneProviderIdentity() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let first = try fixture.snapshot(name: "First", accountID: "same-account")
        let second = try fixture.snapshot(name: "Alias", accountID: "same-account")
        let store = AppStore(directory: fixture.state, startTimers: false)
        try await store.connect(first)
        do { try await store.connect(second); XCTFail("Expected duplicate identity rejection") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }
        XCTAssertEqual(store.accounts, [first])
        XCTAssertEqual(store.readings.count, 1)
        let restored = AppStore(directory: fixture.state, startTimers: false)
        XCTAssertEqual(restored.accounts, [first])
    }

    @MainActor
    func testFailedConfigurationSaveDoesNotPartiallyConnectAccount() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        // A regular file at the storage directory blocks creation without
        // changing filesystem permissions or any production configuration.
        try Data("fixture".utf8).write(to: fixture.state)
        let store = AppStore(directory: fixture.state, startTimers: false)
        do { try await store.connect(config); XCTFail("Expected save failure") }
        catch { /* The observable state must remain transactional on any storage error. */ }
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.state), "fixture")
    }

    @MainActor
    func testRefreshFailureDoesNotReplayPreviousPositiveBalance() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        let store = AppStore(directory: fixture.state, startTimers: false)
        try await store.connect(config)
        try Data("invalid JSON fixture".utf8).write(to: URL(fileURLWithPath: config.location))
        await store.refresh()
        XCTAssertEqual(store.readings[config.id]?.status, .unavailable)
        XCTAssertNil(store.readings[config.id]?.lastSuccessAt)
        XCTAssertTrue(store.readings[config.id]?.windows.isEmpty == true)
        XCTAssertNil(store.readings[config.id]?.identityKey)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.lastRefresh)
    }

    @MainActor
    func testInFlightRefreshCannotOverwriteNewDemoRevision() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove(); StoreURLProtocol.handler = nil }
        let requestStarted = expectation(description: "Fixture request started")
        var pending: StoreURLProtocol?
        StoreURLProtocol.handler = { proto in pending = proto; requestStarted.fulfill() }
        let config = try fixture.codex()
        let store = AppStore(directory: fixture.state, client: mockClient(), startTimers: false)
        store.accounts = [config]
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [requestStarted], timeout: 5)
        store.loadDemo()
        let demoIDs = store.accounts.map(\.id)
        pending?.complete()
        await refresh.value
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.accounts.map(\.id), demoIDs)
        XCTAssertEqual(Set(store.readings.keys), Set(demoIDs))
        XCTAssertNil(store.readings[config.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testOverlappingRefreshesShareOneProviderRequest() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove(); StoreURLProtocol.handler = nil }
        let requestStarted = expectation(description: "Fixture request started")
        var pending: StoreURLProtocol?
        var requests = 0
        StoreURLProtocol.handler = { proto in requests += 1; pending = proto; requestStarted.fulfill() }
        let config = try fixture.codex()
        let store = AppStore(directory: fixture.state, client: mockClient(), startTimers: false)
        store.accounts = [config]
        let first = Task { await store.refresh() }
        await fulfillment(of: [requestStarted], timeout: 5)
        await store.refresh()
        XCTAssertEqual(requests, 1)
        pending?.complete()
        await first.value
        XCTAssertEqual(store.readings[config.id]?.status, .connected)
        XCTAssertFalse(store.isRefreshing)
    }

    private func mockClient() -> ProviderClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreURLProtocol.self]
        return ProviderClient(sessionConfiguration: configuration)
    }
}

private struct StoreFixture {
    let directory: URL
    var state: URL { directory.appendingPathComponent("state") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-AppStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func snapshot(name: String, accountID: String) throws -> AccountConfig {
        let file = directory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        let object: [String: Any] = ["id": name, "status": "connected", "lastSuccessAt": Date().timeIntervalSince1970,
                                    "identity": ["provider": "codex", "accountID": accountID], "windows": [["id": "weekly", "remainingPercent": 37]]]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return AccountConfig(provider: .snapshot, name: name, method: .snapshotFile, location: file.path)
    }
    func codex() throws -> AccountConfig {
        let file = directory.appendingPathComponent("credential-fixture.json")
        try Data(#"{"tokens":{"access_token":"fake-fixture-credential","account_id":"test-account"}}"#.utf8).write(to: file)
        return AccountConfig(provider: .codex, name: "Fixture", method: .localFile, location: file.path)
    }
}

private final class StoreURLProtocol: URLProtocol {
    static var handler: ((StoreURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func complete() {
        guard let client, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(#"{"account_id":"test-account","rate_limit":{"primary_window":{"used_percent":30}}}"#.utf8))
        client.urlProtocolDidFinishLoading(self)
    }
}
