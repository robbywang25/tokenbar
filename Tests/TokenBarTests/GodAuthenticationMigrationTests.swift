import Foundation
import XCTest
@testable import TokenBar

final class GodAuthenticationMigrationTests: XCTestCase {
    func testIssuerPolicyAcceptsOnlyExactCanonicalAndLegacyOrigins() throws {
        for issuer in [GodIssuerPolicy.canonical, GodIssuerPolicy.legacy] {
            var config = MigrationFixture.configuration; config.issuer = issuer
            try config.validate(origin: MigrationFixture.origin)
        }
        for issuer in ["https://identity.example.test", "http://auth.robby.wang", "https://auth.robby.wang/",
                       "https://auth.robby.wang:443", "https://auth.robby.wang.evil.example", "https://user@auth.robby.wang",
                       "https://auth.robby.wang/path", "https://auth.robby.wang?next=1", "https://auth.robby.wang#fragment"] {
            var config = MigrationFixture.configuration; config.issuer = issuer
            XCTAssertThrowsError(try config.validate(origin: MigrationFixture.origin), issuer)
        }
    }

    @MainActor
    func testLegacyRestoreAndRefreshDoNotConsultNewIssuerConfiguration() async throws {
        let fixture = try MigrationFixture(expired: true)
        defer { fixture.remove() }
        let auth = fixture.auth()
        await auth.restore()
        XCTAssertTrue(auth.hasSession)
        XCTAssertTrue(auth.needsAuthenticationMigration)
        XCTAssertEqual(fixture.savedToken?.configuration.issuer, GodIssuerPolicy.legacy)
        XCTAssertEqual(fixture.backend.records.filter { $0.path == "/api/tokenbar/v1/configuration" }.count, 0)
        let refresh = try XCTUnwrap(fixture.backend.records.first { $0.form["grant_type"] == "refresh_token" })
        XCTAssertEqual(refresh.origin, GodIssuerPolicy.legacy)
        XCTAssertEqual(refresh.form["refresh_token"], MigrationFixture.oldRefresh)
        XCTAssertFalse(fixture.backend.records.contains { $0.origin == GodIssuerPolicy.canonical })
    }

    @MainActor
    func testCanonicalSessionSurvivesRestartWithoutSendingItsRefreshTokenToLegacyConfiguration() async throws {
        let fixture = try MigrationFixture(expired: true, issuer: GodIssuerPolicy.canonical)
        defer { fixture.remove() }
        fixture.backend.advertise(issuer: GodIssuerPolicy.legacy, foreignTokenEndpoint: false)
        let auth = fixture.auth()
        await auth.restore()
        XCTAssertTrue(auth.hasSession)
        XCTAssertFalse(auth.needsAuthenticationMigration)
        XCTAssertEqual(fixture.savedToken?.configuration.issuer, GodIssuerPolicy.canonical)
        let refresh = try XCTUnwrap(fixture.backend.records.first { $0.form["grant_type"] == "refresh_token" })
        XCTAssertEqual(refresh.origin, GodIssuerPolicy.canonical)
        XCTAssertEqual(refresh.form["refresh_token"], MigrationFixture.newRefresh)
        XCTAssertFalse(fixture.backend.records.contains { $0.origin == GodIssuerPolicy.legacy || $0.path == "/api/tokenbar/v1/configuration" })
    }

    @MainActor
    func testUntrustedStoredIssuerIsNeverContactedAndDoesNotDeleteTheStoredRecord() async throws {
        let fixture = try MigrationFixture(expired: true, issuer: "https://identity.example.test")
        defer { fixture.remove() }
        let original = fixture.tokenBytes, auth = fixture.auth()
        await auth.restore()
        XCTAssertNil(auth.token)
        XCTAssertNil(auth.user)
        XCTAssertEqual(fixture.tokenBytes, original)
        XCTAssertTrue(fixture.backend.records.isEmpty)
    }

    @MainActor
    func testMigrationAtomicallyReplacesSameUserAndRefreshesOnlyAtTheOwningIssuer() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let auth = fixture.auth()
        await auth.restore()
        let original = fixture.tokenBytes
        auth.migrateAuthentication()
        await waitUntil { auth.userCode == "TEST-CODE" }
        XCTAssertTrue(auth.hasSession)
        XCTAssertTrue(auth.isMigratingAuthentication)
        XCTAssertEqual(fixture.tokenBytes, original)
        XCTAssertEqual(auth.token?.configuration.issuer, GodIssuerPolicy.legacy)
        XCTAssertEqual(auth.verificationURL?.host, "auth.robby.wang")
        let session = try await auth.request(path: "/session")
        XCTAssertEqual(session.status, 200)
        fixture.backend.setFinished()
        await waitUntil { !auth.isSigningIn && auth.token?.configuration.issuer == GodIssuerPolicy.canonical }
        XCTAssertEqual(auth.user?.id, MigrationFixture.userID)
        XCTAssertEqual(fixture.savedToken?.configuration.issuer, GodIssuerPolicy.canonical)
        XCTAssertFalse(auth.needsAuthenticationMigration)
        await waitUntil { [MigrationFixture.oldRefresh, MigrationFixture.oldAccess].allSatisfy(fixture.backend.revoked.contains) }
        fixture.backend.rejectNextQuota()
        let quotas = try await auth.request(path: "/quotas")
        XCTAssertEqual(quotas.status, 200)
        let refresh = try XCTUnwrap(fixture.backend.records.last { $0.form["grant_type"] == "refresh_token" })
        XCTAssertEqual(refresh.origin, GodIssuerPolicy.canonical)
        XCTAssertEqual(refresh.form["refresh_token"], MigrationFixture.newRefresh)
        XCTAssertTrue(fixture.backend.records.filter { $0.form["token"] == MigrationFixture.oldRefresh }.allSatisfy { $0.origin == GodIssuerPolicy.legacy })
        XCTAssertFalse(fixture.backend.records.contains { $0.origin == GodIssuerPolicy.canonical && $0.form["refresh_token"] == MigrationFixture.oldRefresh })
    }

    @MainActor
    func testCancellingMigrationDoesNotCancelOrRevokeAnInFlightLegacyRefresh() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let auth = fixture.auth()
        await auth.restore()
        auth.migrateAuthentication()
        await waitUntil { auth.userCode == "TEST-CODE" }
        let started = expectation(description: "legacy refresh started")
        fixture.backend.delayRefresh(0.15, onStart: { started.fulfill() })
        fixture.backend.rejectNextQuota()
        let request = Task { try await auth.request(path: "/quotas") }
        await fulfillment(of: [started], timeout: 3)
        auth.cancelSignIn()
        let response = try await request.value
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(auth.hasSession)
        XCTAssertFalse(auth.isSigningIn)
        XCTAssertEqual(fixture.savedToken?.configuration.issuer, GodIssuerPolicy.legacy)
        XCTAssertEqual(fixture.savedToken?.refreshToken, MigrationFixture.oldRefresh + "-rotated")
        XCTAssertTrue(fixture.backend.revoked.isEmpty)
    }

    @MainActor
    func testDifferentUserCannotReplaceLegacySession() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let auth = fixture.auth()
        await auth.restore()
        let original = fixture.tokenBytes
        fixture.backend.setFinished(userID: MigrationFixture.otherUserID)
        auth.migrateAuthentication()
        await waitUntil { !auth.isSigningIn }
        XCTAssertTrue(auth.hasSession)
        XCTAssertEqual(auth.user?.id, MigrationFixture.userID)
        XCTAssertEqual(fixture.tokenBytes, original)
        XCTAssertEqual(auth.message, GodError.denied.localizedDescription)
        await waitUntil { [MigrationFixture.newRefresh, MigrationFixture.newAccess].allSatisfy(fixture.backend.revoked.contains) }
        XCTAssertFalse(fixture.backend.revoked.contains(MigrationFixture.oldRefresh))
    }

    @MainActor
    func testStorageFailureKeepsTheWorkingSessionAndRevokesOnlyTheCandidate() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let auth = fixture.auth()
        await auth.restore()
        let original = fixture.tokenBytes
        fixture.failWrites = true
        fixture.backend.setFinished()
        auth.migrateAuthentication()
        await waitUntil { !auth.isSigningIn }
        XCTAssertTrue(auth.hasSession)
        XCTAssertEqual(auth.token?.configuration.issuer, GodIssuerPolicy.legacy)
        XCTAssertEqual(fixture.tokenBytes, original)
        XCTAssertEqual(auth.message, GodError.storage.localizedDescription)
        await waitUntil { [MigrationFixture.newRefresh, MigrationFixture.newAccess].allSatisfy(fixture.backend.revoked.contains) }
        XCTAssertFalse(fixture.backend.revoked.contains(MigrationFixture.oldRefresh))
    }

    @MainActor
    func testMigrationRequiresCanonicalConfigurationAndRejectsCrossOriginDiscoveryBeforeSendingSecrets() async throws {
        for (issuer, foreignEndpoint) in [(GodIssuerPolicy.legacy, false), ("https://identity.example.test", false), (GodIssuerPolicy.canonical, true)] {
            let fixture = try MigrationFixture()
            let auth = fixture.auth()
            await auth.restore()
            let original = fixture.tokenBytes
            fixture.backend.advertise(issuer: issuer, foreignTokenEndpoint: foreignEndpoint)
            auth.migrateAuthentication()
            await waitUntil { !auth.isSigningIn }
            XCTAssertTrue(auth.hasSession)
            XCTAssertEqual(fixture.tokenBytes, original)
            XCTAssertFalse(fixture.backend.records.contains { $0.path == "/api/oidc/device-authorization" })
            XCTAssertFalse(fixture.backend.records.contains { $0.origin == "https://identity.example.test" })
            fixture.remove()
        }
    }

    @MainActor
    func testSigningOutDuringCandidateVerificationCannotResurrectEitherSession() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let auth = fixture.auth()
        await auth.restore()
        let started = expectation(description: "candidate verification started")
        fixture.backend.setFinished()
        fixture.backend.delayCandidateVerification(0.15, onStart: { started.fulfill() })
        auth.migrateAuthentication()
        await fulfillment(of: [started], timeout: 12)
        auth.signOut()
        await waitUntil { [MigrationFixture.newRefresh, MigrationFixture.newAccess, MigrationFixture.oldRefresh, MigrationFixture.oldAccess].allSatisfy(fixture.backend.revoked.contains) }
        XCTAssertNil(auth.user)
        XCTAssertNil(auth.token)
        XCTAssertNil(fixture.tokenBytes)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 12, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("Migration condition did not become true"); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class MigrationFixture {
    static let origin = "https://workbench.example.test"
    static let userID = "11111111-1111-4111-8111-111111111111"
    static let otherUserID = "22222222-2222-4222-8222-222222222222"
    static let oldAccess = "synthetic-old-access-token"
    static let oldRefresh = "synthetic-old-refresh-token"
    static let newAccess = "synthetic-new-access-token"
    static let newRefresh = "synthetic-new-refresh-token"
    static let configuration = GodConfiguration(schemaVersion: 1, issuer: GodIssuerPolicy.legacy, clientID: "tokenbar-macos",
        audience: origin + "/api/tokenbar/v1", apiURL: origin + "/api/tokenbar/v1",
        scopes: ["openid", "offline_access", "god.tokenbar.read", "god.tokenbar.sync"], authentication: "device_authorization", switchSyncDefault: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backend = MigrationBackend()
    var tokenBytes: Data?
    var failWrites = false
    var savedToken: GodToken? { tokenBytes.flatMap { try? JSONDecoder().decode(GodToken.self, from: $0) } }
    init(expired: Bool = false, issuer: String = GodIssuerPolicy.legacy) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(GodConnection(origin: Self.origin)).write(to: root.appendingPathComponent("god-connection.json"))
        var config = Self.configuration; config.issuer = issuer
        let canonical = issuer == GodIssuerPolicy.canonical
        tokenBytes = try JSONEncoder().encode(GodToken(accessToken: canonical ? Self.newAccess : Self.oldAccess, refreshToken: canonical ? Self.newRefresh : Self.oldRefresh,
            expiresAt: Date().addingTimeInterval(expired ? -1 : 300), configuration: config,
            user: GodUser(id: Self.userID, label: "Fixture user", quotaAccess: true)))
        MigrationURLProtocol.backend = backend
    }
    @MainActor func auth() -> GodAuthentication {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [MigrationURLProtocol.self]
        let storage = GodSessionStorage(read: { _ in guard let data = self.tokenBytes else { throw GodError.signedOut }; return data },
            write: { data, _ in if self.failWrites { throw GodError.storage }; self.tokenBytes = data }, delete: { _ in self.tokenBytes = nil })
        let result = GodAuthentication(directory: root, http: GodHTTP(configuration: session), storage: storage)
        result.openVerificationPage = { _, _ in }
        return result
    }
    func remove() { MigrationURLProtocol.backend = nil; try? FileManager.default.removeItem(at: root) }
}

private final class MigrationBackend: @unchecked Sendable {
    struct Record { var origin: String; var path: String; var form: [String: String] }
    private let lock = NSLock()
    private var recorded: [Record] = []
    private var finished = false
    private var newUserID = MigrationFixture.userID
    private var configurationIssuer = GodIssuerPolicy.canonical
    private var foreignEndpoint = false
    private var rejectQuota = false
    private var refreshDelay: TimeInterval = 0
    private var verifyDelay: TimeInterval = 0
    private var onRefresh: (() -> Void)?
    private var onVerify: (() -> Void)?
    var records: [Record] { lock.lock(); defer { lock.unlock() }; return recorded }
    var revoked: [String] { records.filter { $0.path == "/api/oidc/revocation" }.compactMap { $0.form["token"] } }
    func setFinished(userID: String = MigrationFixture.userID) { lock.lock(); finished = true; newUserID = userID; lock.unlock() }
    func advertise(issuer: String, foreignTokenEndpoint: Bool) { lock.lock(); configurationIssuer = issuer; foreignEndpoint = foreignTokenEndpoint; lock.unlock() }
    func rejectNextQuota() { lock.lock(); rejectQuota = true; lock.unlock() }
    func delayRefresh(_ seconds: TimeInterval, onStart: @escaping () -> Void) { lock.lock(); refreshDelay = seconds; onRefresh = onStart; lock.unlock() }
    func delayCandidateVerification(_ seconds: TimeInterval, onStart: @escaping () -> Void) { lock.lock(); verifyDelay = seconds; onVerify = onStart; lock.unlock() }
    func respond(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let url = request.url!, origin = "https://" + url.host!
        let rawBody: Data
        if let body = request.httpBody { rawBody = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(bytes, count: count) }
            rawBody = data
        } else { rawBody = Data() }
        var formURL = URLComponents(); formURL.percentEncodedQuery = String(decoding: rawBody, as: UTF8.self)
        let form = Dictionary((formURL.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        recorded.append(Record(origin: origin, path: url.path, form: form))
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        switch url.path {
        case "/api/tokenbar/v1/configuration":
            var config = MigrationFixture.configuration; config.issuer = configurationIssuer
            return (200, try! JSONEncoder().encode(config))
        case "/.well-known/openid-configuration":
            return (200, json(["issuer": origin, "device_authorization_endpoint": origin + "/api/oidc/device-authorization",
                "token_endpoint": (foreignEndpoint ? "https://identity.example.test" : origin) + "/api/oidc/token", "revocation_endpoint": origin + "/api/oidc/revocation",
                "grant_types_supported": ["urn:ietf:params:oauth:grant-type:device_code"], "token_endpoint_auth_methods_supported": ["none"]]))
        case "/api/oidc/device-authorization":
            return (200, json(["device_code": "synthetic-device-secret", "user_code": "TEST-CODE", "verification_uri": origin + "/consent/openid/device-authorization",
                "verification_uri_complete": origin + "/consent/openid/device-authorization?user_code=TEST-CODE", "expires_in": 600, "interval": 5]))
        case "/api/oidc/token":
            if form["grant_type"] == "refresh_token" {
                onRefresh?(); if refreshDelay > 0 { Thread.sleep(forTimeInterval: refreshDelay) }
                let old = origin == GodIssuerPolicy.legacy
                return (200, json(["access_token": old ? MigrationFixture.oldAccess : MigrationFixture.newAccess,
                    "refresh_token": (old ? MigrationFixture.oldRefresh : MigrationFixture.newRefresh) + "-rotated", "token_type": "Bearer", "expires_in": 300]))
            }
            guard finished else { return (400, json(["error": "authorization_pending"])) }
            return (200, json(["access_token": MigrationFixture.newAccess, "refresh_token": MigrationFixture.newRefresh, "token_type": "Bearer", "expires_in": 300]))
        case "/api/tokenbar/v1/session":
            let candidate = request.value(forHTTPHeaderField: "Authorization") == "Bearer " + MigrationFixture.newAccess
            if candidate { onVerify?(); if verifyDelay > 0 { Thread.sleep(forTimeInterval: verifyDelay) } }
            return (200, json(["schemaVersion": 1, "user": ["id": candidate ? newUserID : MigrationFixture.userID, "label": "Fixture user", "quotaAccess": true]]))
        case "/api/tokenbar/v1/quotas":
            if rejectQuota { rejectQuota = false; return (401, json(["error": "expired"])) }
            return (200, Data("{}".utf8))
        case "/api/oidc/revocation": return (200, Data("{}".utf8))
        default: return (404, Data("{}".utf8))
        }
    }
}

private final class MigrationURLProtocol: URLProtocol {
    static var backend: MigrationBackend?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let backend = Self.backend else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let (status, data) = backend.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
