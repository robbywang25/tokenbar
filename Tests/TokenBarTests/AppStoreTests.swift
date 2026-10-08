import Foundation
import XCTest
@testable import TokenBar

final class AppStoreTests: XCTestCase {
    @MainActor
    func testMenuPercentSelectionsPreserveOrderPersistenceAndExplicitEmptyChoice() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let first = try fixture.snapshot(name: "Personal", accountID: "account-one", windows: [
            ["id": "weekly", "label": "每周", "remainingPercent": 0],
            ["id": "reserve", "label": "每周", "remainingPercent": 100, "quotaGroup": "reserve", "model": "example-model"]
        ])
        let second = try fixture.snapshot(name: "Work", accountID: "account-two", windows: [["id": "weekly", "remainingPercent": 94]])
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(first)
        try await store.connect(second)
        XCTAssertNil(store.menuQuotaSelection)
        XCTAssertEqual(store.menuTitle, "0%")
        XCTAssertEqual(store.availableMenuMetrics.count, 3)
        XCTAssertTrue(store.menuQuotaSelected(accountID: first.id, windowID: "weekly"))
        store.setMenuQuota(accountID: second.id, windowID: "weekly", enabled: true)
        store.setMenuQuota(accountID: first.id, windowID: "reserve", enabled: true)
        XCTAssertEqual(store.menuTitle, "0% · 100% · 94%")
        XCTAssertTrue(store.menuTooltip.contains("Personal · Reserve · 每周 · example-model：100%"))
        XCTAssertTrue(store.menuTooltip.contains("Work"))
        XCTAssertFalse(store.menuTitle.contains("TokenBar"))
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.menuTitle, store.menuTitle)
        XCTAssertEqual(restored.menuQuotaSelection, store.menuQuotaSelection)

        for metric in restored.availableMenuMetrics {
            restored.setMenuQuota(accountID: metric.accountID, windowID: metric.windowID, enabled: false)
        }
        XCTAssertEqual(restored.menuTitle, "—")
        XCTAssertEqual(restored.menuQuotaSelection, [])
        let emptyRestored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(emptyRestored.menuQuotaSelection, [])
        XCTAssertEqual(emptyRestored.menuTitle, "—")
    }

    @MainActor
    func testMenuChoicesSurviveStaleFailedReadsAndRemovalCleansPreferences() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let account = try fixture.snapshot(name: "Personal", accountID: "account-one")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(account)
        store.setMenuQuota(accountID: account.id, windowID: "weekly", enabled: true)
        let choices = store.availableMenuMetrics
        XCTAssertEqual(store.menuTitle, "37%")
        store.now = Date().addingTimeInterval(121)
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertTrue(store.menuTooltip.contains("当前未知"))
        try Data("invalid JSON fixture".utf8).write(to: URL(fileURLWithPath: account.location))
        await store.refresh()
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertEqual(store.availableMenuMetrics, choices)
        XCTAssertTrue(store.menuQuotaSelected(accountID: account.id, windowID: "weekly"))
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.availableMenuMetrics, choices)
        XCTAssertEqual(restored.menuTitle, "—")
        restored.remove(account)
        XCTAssertTrue(restored.availableMenuMetrics.isEmpty)
        XCTAssertEqual(restored.menuQuotaSelection, [])
        XCTAssertEqual(restored.menuTitle, "—")
        let removedRestored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertTrue(removedRestored.availableMenuMetrics.isEmpty)
        XCTAssertEqual(removedRestored.menuQuotaSelection, [])
    }

    @MainActor
    func testConnectPersistsPrivateFilesAndReloadsOnlyConfiguredAccounts() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
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
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
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
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(first)
        do { try await store.connect(second); XCTFail("Expected duplicate identity rejection") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }
        XCTAssertEqual(store.accounts, [first])
        XCTAssertEqual(store.readings.count, 1)
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.accounts, [first])
    }

    @MainActor
    func testDifferentSSHHostsCanConnectSamePathAndSourceAccountID() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let document = try JSONSerialization.data(withJSONObject: ["id": "quota", "status": "connected", "lastSuccessAt": Date().timeIntervalSince1970, "windows": [["remainingPercent": 37]]])
        let client = ProviderClient(sshReader: { _ in document })
        let store = AppStore(directory: fixture.state, client: client, startTimers: false, defaults: fixture.defaults)
        let suffix = UUID().uuidString
        let first = AccountConfig(provider: .snapshot, name: "Host A", method: .snapshotSSH, location: "/srv/quota.json", sourceAccountID: "quota", sshHost: "fixture-a-" + suffix)
        let second = AccountConfig(provider: .snapshot, name: "Host B", method: .snapshotSSH, location: "/srv/quota.json", sourceAccountID: "quota", sshHost: "fixture-b-" + suffix)
        try await store.connect(first)
        try await store.connect(second)
        XCTAssertEqual(store.accounts, [first, second])
        XCTAssertNotEqual(store.readings[first.id]?.identityKey, store.readings[second.id]?.identityKey)
        var duplicate = first
        duplicate.id = UUID()
        do { try await store.connect(duplicate); XCTFail("Same SSH source must remain deduplicated") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }
    }

    @MainActor
    func testOneHTTPSEndpointCanDistinguishAccountsByBearerAndStableIdentity() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove(); StoreURLProtocol.handler = nil }
        let first = AccountConfig(provider: .snapshot, name: "Personal", method: .snapshotURL, location: "https://quota.example.test/usage")
        let second = AccountConfig(provider: .snapshot, name: "Work", method: .snapshotURL, location: first.location)
        let duplicate = AccountConfig(provider: .snapshot, name: "Duplicate", method: .snapshotURL, location: first.location)
        let tokens = [first.id.uuidString: "fixture-personal", second.id.uuidString: "fixture-work", duplicate.id.uuidString: "fixture-personal"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreURLProtocol.self]
        let client = ProviderClient(sessionConfiguration: configuration, credentialReader: { _, account in
            guard let token = tokens[account ?? ""] else { throw ProviderError.needsAuth }
            return Data(token.utf8)
        })
        let base: [String: Any] = ["id": "quota", "status": "connected", "lastSuccessAt": Date().timeIntervalSince1970, "windows": [["remainingPercent": 37]]]
        var bodies: [String: Data] = [:]
        for token in ["fixture-personal", "fixture-work"] {
            var object = base
            object["identity"] = ["provider": "example", "accountID": token]
            bodies["Bearer " + token] = try JSONSerialization.data(withJSONObject: object)
        }
        StoreURLProtocol.handler = { proto in
            proto.complete(data: bodies[proto.request.value(forHTTPHeaderField: "Authorization") ?? ""]!)
        }
        let store = AppStore(directory: fixture.state, client: client, startTimers: false, defaults: fixture.defaults)
        try await store.connect(first)
        try await store.connect(second)
        XCTAssertEqual(store.accounts, [first, second])
        do { try await store.connect(duplicate); XCTFail("A matching provider identity must still be rejected") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }

        // Without a distinguishable identity, different Bearers must not imply
        // separate balances at a shared endpoint/account ID.
        let fallbackData = try JSONSerialization.data(withJSONObject: base)
        StoreURLProtocol.handler = { $0.complete(data: fallbackData) }
        let fallbackStore = AppStore(directory: fixture.directory.appendingPathComponent("fallback-state"), client: client, startTimers: false, defaults: fixture.defaults)
        try await fallbackStore.connect(first)
        do { try await fallbackStore.connect(second); XCTFail("Ambiguous source identity must stay deduplicated") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }
        XCTAssertEqual(fallbackStore.accounts, [first])
    }

    @MainActor
    func testFailedConfigurationSaveDoesNotPartiallyConnectAccount() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        // A regular file at the storage directory blocks creation without
        // changing filesystem permissions or any production configuration.
        try Data("fixture".utf8).write(to: fixture.state)
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
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
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
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
        let store = AppStore(directory: fixture.state, client: mockClient(), startTimers: false, defaults: fixture.defaults)
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
        let store = AppStore(directory: fixture.state, client: mockClient(), startTimers: false, defaults: fixture.defaults)
        store.accounts = [config]
        let old = Date().addingTimeInterval(-600)
        store.now = old
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: old, lastSuccessAt: old, windows: [QuotaWindow(id: "quota", label: "额度", remainingPercent: 70)])
        let first = Task { await store.refresh() }
        await fulfillment(of: [requestStarted], timeout: 5)
        XCTAssertGreaterThan(store.now, old.addingTimeInterval(590))
        XCTAssertEqual(store.readings[config.id]?.displayStatus(at: store.now), .stale)
        XCTAssertEqual(store.menuTitle, "—")
        store.now = old
        await store.refresh()
        XCTAssertGreaterThan(store.now, old.addingTimeInterval(590))
        XCTAssertEqual(requests, 1)
        pending?.complete()
        await first.value
        XCTAssertEqual(store.readings[config.id]?.status, .connected)
        XCTAssertFalse(store.isRefreshing)
    }

    private func mockClient() -> ProviderClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreURLProtocol.self]
        return ProviderClient(sessionConfiguration: configuration, credentialReader: { _, _ in throw ProviderError.needsAuth })
    }
}

private struct StoreFixture {
    let directory: URL
    let defaults: UserDefaults
    private let defaultsSuite: String
    var state: URL { directory.appendingPathComponent("state") }

    init() throws {
        defaultsSuite = "TokenBarTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsSuite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-AppStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    func remove() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
    func snapshot(name: String, accountID: String, windows: [[String: Any]] = [["id": "weekly", "remainingPercent": 37]]) throws -> AccountConfig {
        let file = directory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        let object: [String: Any] = ["id": name, "status": "connected", "lastSuccessAt": Date().timeIntervalSince1970,
                                    "identity": ["provider": "codex", "accountID": accountID], "windows": windows]
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
    func complete(data: Data = Data(#"{"account_id":"test-account","rate_limit":{"primary_window":{"used_percent":30}}}"#.utf8)) {
        guard let client, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }
}
