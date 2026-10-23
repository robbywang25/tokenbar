import Foundation
import XCTest
@testable import TokenBar

final class GodSyncTests: XCTestCase {
    func testDeviceGrantAndConfigurationRejectForeignOriginsAndUnexpectedAuthority() throws {
        let config = SyncFixture.configuration
        try config.validate(origin: SyncFixture.origin)
        var broadened = config; broadened.scopes.append("god.mobile.account.write")
        XCTAssertThrowsError(try broadened.validate(origin: SyncFixture.origin))
        var foreign = config; foreign.apiURL = "https://another.example.test/api/tokenbar/v1"
        XCTAssertThrowsError(try foreign.validate(origin: SyncFixture.origin))
        let grant = GodDeviceGrant(device_code: "synthetic-device-secret", user_code: "TEST-CODE",
            verification_uri: config.issuer + "/consent/openid/device-authorization", expires_in: 600, interval: 5)
        try grant.validate(issuer: config.issuer)
        var bad = grant; bad.verification_uri_complete = "https://another.example.test/?user_code=TEST-CODE"
        XCTAssertThrowsError(try bad.validate(issuer: config.issuer))
        bad = grant; bad.verification_uri_complete = grant.verification_uri + "?user_code=WRONG-CODE"
        XCTAssertThrowsError(try bad.validate(issuer: config.issuer))
        XCTAssertThrowsError(try GodHTTP.origin("http://workbench.example.test"))
        XCTAssertThrowsError(try GodHTTP.origin("https://user:secret@workbench.example.test"))
        XCTAssertEqual(String(data: GodHTTP.form(["value": "a+b&c=d e"]), encoding: .utf8), "value=a%2Bb%26c%3Dd%20e")
    }

    func testJournalRebasesIndependentEditsAndKeepsNewerChangesDuringAcknowledgement() throws {
        let first = preference("refreshSeconds", .number(10)), newer = preference("refreshSeconds", .number(15))
        var journal = GodSyncJournal(remote: GodSyncDocument(), baseline: ["p:refreshSeconds": first], initialized: true)
        journal.capture(["p:refreshSeconds": newer], switches: true)
        let remote = GodSyncDocument(revision: 3, records: ["p:calendarTimeZone": preference("calendarTimeZone", .string("UTC"))])
        journal.rebase(remote, switches: true)
        let request = journal.patch()
        XCTAssertEqual(request.baseRevision, 3)
        XCTAssertEqual(request.operations.map(\.key), ["p:refreshSeconds"])
        journal.capture(["p:refreshSeconds": preference("refreshSeconds", .number(30))], switches: true)
        journal.acknowledge(request, document: GodSyncDocument(revision: 4, records: [:]))
        XCTAssertEqual(journal.pending["p:refreshSeconds"]?["value"], .number(30))
    }

    func testHistoryMergeDeduplicatesAndDoesNotCrossIdentityEpochs() throws {
        func history(_ time: Double, epoch: String) -> SyncJSON {
            .object(["kind": .string("history"), "accountID": .string("god:claude-1"), "epoch": .string(epoch),
                     "events": .array([.object(["id": .string("week"), "label": .string("每周"), "group": .string("default"), "resetsAt": .number(time)])])])
        }
        let a = history(100, epoch: "same"), b = history(200, epoch: "same")
        let union = GodSyncJournal.mergeHistory(local: a, remote: b)
        XCTAssertEqual(union["events"]?.array?.count, 2)
        XCTAssertEqual(GodSyncJournal.mergeHistory(local: union, remote: a)["events"]?.array?.count, 2)
        XCTAssertEqual(GodSyncJournal.mergeHistory(local: a, remote: history(200, epoch: "other")), a)
    }

    @MainActor
    func testExpiredSessionRefreshIsSharedAndPersistedBeforeUse() async throws {
        let backend = SyncBackend(); backend.tokenDelay = 0.03
        SyncURLProtocol.handler = { backend.respond($0) }
        let f = try SyncFixture(expired: true); defer { f.remove(); SyncURLProtocol.handler = nil }
        let auth = f.auth()
        let restore = Task { await auth.restore() }
        await Task.yield()
        let request = Task { try? await auth.request(path: "/session") }
        await restore.value; _ = await request.value
        XCTAssertTrue(auth.hasSession)
        XCTAssertEqual(backend.refreshCount, 1)
        let saved = try JSONDecoder().decode(GodToken.self, from: XCTUnwrap(f.tokenBytes))
        XCTAssertTrue(saved.refreshToken.hasSuffix("rotated"))
        XCTAssertGreaterThan(saved.expiresAt, Date().addingTimeInterval(200))
    }

    @MainActor
    func testLogoutDuringRestoreCannotResurrectTheSession() async throws {
        let backend = SyncBackend(); let started = expectation(description: "refresh started")
        backend.tokenDelay = 0.05; backend.onRefresh = { started.fulfill() }
        SyncURLProtocol.handler = { backend.respond($0) }
        let f = try SyncFixture(expired: true); defer { f.remove(); SyncURLProtocol.handler = nil }
        let auth = f.auth(); let restore = Task { await auth.restore() }
        await fulfillment(of: [started], timeout: 3)
        auth.signOut(); await restore.value
        XCTAssertNil(auth.user); XCTAssertNil(auth.token); XCTAssertNil(f.tokenBytes)
    }

    @MainActor
    func testTwoIndependentClientsSyncByUserAndCanOptOutAndBackIn() async throws {
        let backend = SyncBackend()
        SyncURLProtocol.handler = { backend.respond($0) }
        let a = try SyncFixture(), b = try SyncFixture(), other = try SyncFixture(userID: SyncFixture.otherID, quotaAccess: false)
        defer { a.remove(); b.remove(); other.remove(); SyncURLProtocol.handler = nil }
        let first = a.workspace(), second = b.workspace(), isolated = other.workspace()
        defer { first.stop(); second.stop(); isolated.stop() }
        await first.authentication.restore(); await second.authentication.restore()
        XCTAssertTrue(first.authentication.hasSession)
        XCTAssertEqual(first.store.accounts.map(\.sourceAccountID), ["claude-1"])
        XCTAssertEqual(second.store.accounts.map(\.sourceAccountID), ["claude-1"])
        XCTAssertTrue(first.syncSwitches); XCTAssertTrue(second.syncSwitches)
        first.store.setShowsAgentPrefix(false); await first.synchronize(); await second.synchronize()
        XCTAssertFalse(second.store.showsAgentPrefix)
        second.setSyncSwitches(false); second.store.setShowsAgentPrefix(true); await second.synchronize()
        first.store.setExpiryAlertsEnabled(false); first.store.updateRefreshInterval(15)
        await first.synchronize(); await second.synchronize()
        XCTAssertTrue(second.store.showsAgentPrefix)
        XCTAssertTrue(second.store.expiryAlertsEnabled)
        XCTAssertEqual(second.store.refreshSeconds, 15, "non-switch preferences still sync")
        second.setSyncSwitches(true); await second.synchronize()
        XCTAssertFalse(second.store.showsAgentPrefix); XCTAssertFalse(second.store.expiryAlertsEnabled)
        await isolated.authentication.restore()
        XCTAssertTrue(isolated.authentication.hasSession)
        XCTAssertTrue(isolated.store.accounts.isEmpty)
        XCTAssertTrue(isolated.store.showsAgentPrefix)
        XCTAssertEqual(isolated.store.refreshSeconds, 10)
        XCTAssertNil(first.syncMessage); XCTAssertNil(second.syncMessage)
        let oldDirectory = first.store.storageDirectory
        first.authentication.signOut()
        XCTAssertEqual(first.store.storageDirectory, a.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDirectory.appendingPathComponent("sync-journal.json").path))
    }

    @MainActor
    func testConcurrentChangesAndArchivedDatesSurviveConflictAndRestart() async throws {
        let backend = SyncBackend(); SyncURLProtocol.handler = { backend.respond($0) }
        let a = try SyncFixture(), b = try SyncFixture(); defer { a.remove(); b.remove(); SyncURLProtocol.handler = nil }
        let first = a.workspace(), second = b.workspace(); defer { first.stop(); second.stop() }
        await first.authentication.restore(); await second.authentication.restore()
        first.store.setCalendarTimeZone("UTC"); second.store.setExpiryAlertsEnabled(false)
        await first.synchronize(); backend.injectConflict = true; await second.synchronize(); await first.synchronize()
        XCTAssertEqual(second.store.calendarTimeZoneID, "UTC")
        XCTAssertFalse(first.store.expiryAlertsEnabled)
        let account = try XCTUnwrap(first.store.accounts.first)
        let record: SyncJSON = .object(["kind": .string("history"), "accountID": .string("god:claude-1"),
            "epoch": .string(SyncFixture.historyEpoch), "events": .array([.object(["id": .string("historic"), "label": .string("每周"), "group": .string("default"), "resetsAt": .number(Date().addingTimeInterval(-86400).timeIntervalSince1970)])])])
        try first.store.applyCloudRecords(["h:god:claude-1": record], switches: false)
        await first.synchronize(); await second.synchronize()
        XCTAssertTrue(second.store.calendarModel().events.contains { $0.id.windowID == "historic" })
        first.stop()
        let restored = a.workspace(); defer { restored.stop() }
        await restored.authentication.restore()
        XCTAssertEqual(restored.store.accounts.first?.id, account.id)
        XCTAssertTrue(restored.store.calendarModel().events.contains { $0.id.windowID == "historic" })
        XCTAssertNil(restored.syncMessage)
    }

    @MainActor
    func testMigrationPreservesExistingSelectionAndDoesNotUploadPathsOrCredentials() async throws {
        let backend = SyncBackend(); SyncURLProtocol.handler = { backend.respond($0) }
        let f = try SyncFixture(); defer { f.remove(); SyncURLProtocol.handler = nil }
        let source = f.root.appendingPathComponent("private-local-source.json")
        try JSONSerialization.data(withJSONObject: backend.quotas()).write(to: source)
        let cloud = f.workspace(); defer { cloud.stop() }
        var local = AccountConfig(provider: .snapshot, name: "Private local name", method: .snapshotFile, location: source.path, sourceAccountID: "claude-1", serviceLabel: "Claude Code")
        try await cloud.store.connect(local)
        cloud.store.setMenuQuota(accountID: local.id, windowID: "weekly", enabled: true)
        await cloud.authentication.restore()
        XCTAssertEqual(cloud.store.accounts.count, 1)
        local = try XCTUnwrap(cloud.store.accounts.first)
        XCTAssertTrue(cloud.store.menuQuotaSelected(accountID: local.id, windowID: "weekly"))
        let records = try cloud.store.exportCloudRecords(), bytes = try JSONEncoder().encode(records)
        XCTAssertNil(records["h:god:claude-1"], "future schedules must not be unioned into historical events")
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in [f.root.path, "private-local-source", "Private local name", "accessToken", "refreshToken", "sshHost", "location"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        if let path = ProcessInfo.processInfo.environment["TOKENBAR_EXPORT_SYNC_FIXTURE"] { try bytes.write(to: URL(fileURLWithPath: path), options: .atomic) }
        XCTAssertNil(cloud.syncMessage)
    }

    @MainActor
    func testMenuPanelKeepsPendingGodConfirmationCodeWhenFocusLeaves() async throws {
        let flow = DeviceAuthorizationFlow()
        SyncURLProtocol.handler = { flow.respond($0) }
        let fixture = try SyncFixture()
        defer { fixture.remove(); SyncURLProtocol.handler = nil }
        let auth = fixture.auth()
        let opened = OpenedVerificationPages()
        auth.openVerificationPage = { url, _ in opened.urls.append(url) }
        let page = URL(string: "https://identity.example.test/consent/openid/device-authorization?user_code=TEST-CODE")!

        XCTAssertTrue(menuPanelDismissesOnFocusLoss(auth))
        XCTAssertFalse(auth.isSigningIn)
        XCTAssertNil(auth.userCode)
        XCTAssertNil(auth.verificationURL)
        XCTAssertNil(auth.user)

        flow.setPhase(.pending)
        auth.signIn()
        await waitUntil("synthetic grant exposes the confirmation code") { auth.userCode == "TEST-CODE" }
        XCTAssertFalse(menuPanelDismissesOnFocusLoss(auth))
        XCTAssertTrue(auth.isSigningIn)
        XCTAssertEqual(auth.userCode, "TEST-CODE")
        XCTAssertEqual(auth.verificationURL, page)
        XCTAssertEqual(opened.urls.last, page)
        auth.openVerification()
        XCTAssertEqual(opened.urls.last, auth.verificationURL)
        auth.cancelSignIn()
        XCTAssertFalse(auth.isSigningIn)
        XCTAssertNil(auth.userCode)
        XCTAssertNil(auth.verificationURL)
        XCTAssertTrue(menuPanelDismissesOnFocusLoss(auth))
        await Task.yield()
        XCTAssertNil(auth.userCode, "a cancelled attempt must not publish the code again")
        XCTAssertFalse(auth.isSigningIn)

        flow.setPhase(.expired)
        auth.signIn()
        await waitUntil("code is visible before expiry") { auth.userCode == "TEST-CODE" }
        XCTAssertFalse(menuPanelDismissesOnFocusLoss(auth))
        XCTAssertEqual(auth.verificationURL, page)
        await waitUntil("expiry clears the pending sign-in", timeout: 12) { auth.isSigningIn == false && auth.userCode == nil }
        XCTAssertNil(auth.verificationURL)
        XCTAssertNil(auth.user)
        XCTAssertEqual(auth.message, GodError.expired.localizedDescription)
        XCTAssertTrue(menuPanelDismissesOnFocusLoss(auth))

        auth.message = nil
        flow.setPhase(.finished)
        auth.signIn()
        await waitUntil("code is visible before the grant finishes") { auth.userCode == "TEST-CODE" }
        XCTAssertFalse(menuPanelDismissesOnFocusLoss(auth))
        XCTAssertEqual(auth.verificationURL, page)
        await waitUntil("a finished grant clears the confirmation code", timeout: 12) { auth.isSigningIn == false && auth.userCode == nil && auth.user != nil }
        XCTAssertNil(auth.verificationURL)
        XCTAssertEqual(auth.user?.id, SyncFixture.ownerID)
        XCTAssertNil(auth.message)
        XCTAssertTrue(menuPanelDismissesOnFocusLoss(auth))
        XCTAssertEqual(flow.deviceGrants, 3)
        XCTAssertFalse(opened.urls.isEmpty)
        XCTAssertTrue(opened.urls.allSatisfy { $0.host == "identity.example.test" })
        XCTAssertTrue(flow.hosts.allSatisfy { $0 == "workbench.example.test" || $0 == "identity.example.test" })
    }

    @MainActor
    private func waitUntil(_ label: String, timeout: TimeInterval = 12, _ ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() {
            if Date() >= deadline {
                XCTFail(label)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func preference(_ name: String, _ value: SyncJSON) -> SyncJSON { .object(["kind": .string("preference"), "name": .string(name), "value": value]) }
}

private final class SyncFixture {
    static let origin = "https://workbench.example.test", ownerID = "11111111-1111-4111-8111-111111111111", otherID = "22222222-2222-4222-8222-222222222222"
    static let historyEpoch = "12345678-1234-1234-1234-123456789abc"
    static let configuration = GodConfiguration(schemaVersion: 1, issuer: "https://identity.example.test", clientID: "tokenbar-macos", audience: origin + "/api/tokenbar/v1", apiURL: origin + "/api/tokenbar/v1", scopes: ["openid", "offline_access", "god.tokenbar.read", "god.tokenbar.sync"], authentication: "device_authorization", switchSyncDefault: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "GodSyncFixture." + UUID().uuidString
    let userID: String
    var tokenBytes: Data?
    init(userID: String = ownerID, quotaAccess: Bool = true, expired: Bool = false) throws {
        self.userID = userID
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(GodConnection(origin: Self.origin)).write(to: root.appendingPathComponent("god-connection.json"))
        let token = GodToken(accessToken: "synthetic-access-" + userID, refreshToken: "synthetic-refresh-" + userID, expiresAt: Date().addingTimeInterval(expired ? -1 : 300), configuration: Self.configuration,
                             user: GodUser(id: userID, label: "Fixture user", quotaAccess: quotaAccess))
        tokenBytes = try JSONEncoder().encode(token)
    }
    @MainActor func auth() -> GodAuthentication {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [SyncURLProtocol.self]
        let storage = GodSessionStorage(read: { _ in guard let data = self.tokenBytes else { throw GodError.signedOut }; return data },
                                       write: { data, _ in self.tokenBytes = data }, delete: { _ in self.tokenBytes = nil })
        return GodAuthentication(directory: root, http: GodHTTP(configuration: session), storage: storage)
    }
    @MainActor func workspace() -> GodWorkspace {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [SyncURLProtocol.self]
        let storage = GodSessionStorage(read: { _ in guard let data = self.tokenBytes else { throw GodError.signedOut }; return data },
                                       write: { data, _ in self.tokenBytes = data }, delete: { _ in self.tokenBytes = nil })
        return GodWorkspace(directory: root, defaults: UserDefaults(suiteName: suite)!, http: GodHTTP(configuration: session), storage: storage, startTimers: false)
    }
    func remove() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        let hash = GodAuthentication.digest(Self.configuration.apiURL + "\n" + userID)
        let preferences = "wang.robby.tokenbar.god." + GodAuthentication.digest(root.appendingPathComponent("GodProfiles").appendingPathComponent(hash).path)
        UserDefaults(suiteName: preferences)?.removePersistentDomain(forName: preferences)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SyncBackend: @unchecked Sendable {
    let lock = NSLock()
    var documents: [String: GodSyncDocument] = [:]
    var injectConflict = false
    var refreshCount = 0
    var tokenDelay: TimeInterval = 0
    var onRefresh: (() -> Void)?
    let observed = Date()
    func quotas() -> [String: Any] {
        ["schemaVersion": 1, "collectedAt": observed.timeIntervalSince1970, "accounts": [["id": "claude-1", "serviceLabel": "Claude Code", "status": "connected",
          "profile": ["email": "fixture@example.test"], "lastSuccessAt": observed.timeIntervalSince1970, "resetHistoryIdentity": SyncFixture.historyEpoch,
          "windows": [["id": "weekly", "label": "每周", "remainingPercent": 70, "resetsAt": observed.addingTimeInterval(3600).timeIntervalSince1970]]]]]
    }
    func respond(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let user = auth.hasSuffix(SyncFixture.otherID) ? SyncFixture.otherID : SyncFixture.ownerID
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        switch request.url!.path {
        case "/.well-known/openid-configuration":
            let issuer = SyncFixture.configuration.issuer
            return (200, json(["issuer": issuer, "device_authorization_endpoint": issuer + "/api/oidc/device-authorization", "token_endpoint": issuer + "/api/oidc/token", "revocation_endpoint": issuer + "/api/oidc/revocation",
                               "grant_types_supported": ["authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code"], "token_endpoint_auth_methods_supported": ["none"]]))
        case "/api/oidc/token":
            refreshCount += 1; onRefresh?(); if tokenDelay > 0 { Thread.sleep(forTimeInterval: tokenDelay) }
            return (200, json(["access_token": "synthetic-access-" + SyncFixture.ownerID, "refresh_token": "synthetic-refresh-rotated", "token_type": "Bearer", "expires_in": 300, "scope": SyncFixture.configuration.scopes.joined(separator: " ")]))
        case "/api/oidc/revocation": return (200, Data("{}".utf8))
        case "/api/tokenbar/v1/session": return (200, json(["schemaVersion": 1, "user": ["id": user, "label": "Fixture user", "quotaAccess": user == SyncFixture.ownerID]]))
        case "/api/tokenbar/v1/quotas": return user == SyncFixture.ownerID ? (200, json(quotas())) : (403, json(["error": "quotas_not_configured"]))
        case "/api/tokenbar/v1/sync":
            var document = documents[user] ?? GodSyncDocument()
            if request.httpMethod == "PATCH" {
                let patch = try! JSONDecoder().decode(GodSyncPatch.self, from: request.httpBody ?? Data(reading: request.httpBodyStream!))
                if injectConflict { injectConflict = false; document.revision += 1; documents[user] = document }
                if patch.baseRevision != document.revision { return (409, json(["error": "conflict"])) }
                for operation in patch.operations { document.records[operation.key] = operation.value }
                document.revision += 1; documents[user] = document
            }
            return (200, try! JSONEncoder().encode(document))
        default: return (404, json(["error": "not_found"]))
        }
    }
}
private extension Data {
    init(reading stream: InputStream) {
        self.init(); stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; append(bytes, count: count) }
    }
}
private final class OpenedVerificationPages: @unchecked Sendable {
    var urls: [URL] = []
}

private final class DeviceAuthorizationFlow: @unchecked Sendable {
    enum Phase { case pending, expired, finished }
    private let lock = NSLock()
    private var phase = Phase.pending
    private var requestedHosts: [String] = []
    private var grants = 0
    func setPhase(_ phase: Phase) { lock.lock(); self.phase = phase; lock.unlock() }
    var deviceGrants: Int { lock.lock(); defer { lock.unlock() }; return grants }
    var hosts: [String] { lock.lock(); defer { lock.unlock() }; return requestedHosts }
    func respond(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        if let host = request.url?.host { requestedHosts.append(host) }
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let issuer = SyncFixture.configuration.issuer
        switch request.url?.path {
        case "/api/tokenbar/v1/configuration":
            return (200, try! JSONEncoder().encode(SyncFixture.configuration))
        case "/.well-known/openid-configuration":
            return (200, json(["issuer": issuer, "device_authorization_endpoint": issuer + "/api/oidc/device-authorization", "token_endpoint": issuer + "/api/oidc/token", "revocation_endpoint": issuer + "/api/oidc/revocation",
                               "grant_types_supported": ["urn:ietf:params:oauth:grant-type:device_code"], "token_endpoint_auth_methods_supported": ["none"]]))
        case "/api/oidc/device-authorization":
            grants += 1
            return (200, json(["device_code": "synthetic-device-secret", "user_code": "TEST-CODE",
                               "verification_uri": issuer + "/consent/openid/device-authorization",
                               "verification_uri_complete": issuer + "/consent/openid/device-authorization?user_code=TEST-CODE",
                               "expires_in": phase == .expired ? 1 : 600, "interval": 5]))
        case "/api/oidc/token":
            if phase == .finished {
                return (200, json(["access_token": "synthetic-access-token-value", "refresh_token": "synthetic-refresh-token-value", "token_type": "Bearer", "expires_in": 300, "scope": SyncFixture.configuration.scopes.joined(separator: " ")]))
            }
            return (400, json(["error": "authorization_pending"]))
        case "/api/tokenbar/v1/session":
            return (200, json(["schemaVersion": 1, "user": ["id": SyncFixture.ownerID, "label": "Fixture user", "quotaAccess": true]]))
        case "/api/oidc/revocation":
            return (200, Data("{}".utf8))
        default:
            return (404, json(["error": "not_found"]))
        }
    }
}

private final class SyncURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let (status, data) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
