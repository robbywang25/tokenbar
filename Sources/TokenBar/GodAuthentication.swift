import AppKit
import Combine
import CryptoKit
import Foundation

struct GodConnection: Codable, Equatable {
    var origin: String
    var preferredBrowserBundleID: String?
    var migrationSourceIDs: [UUID]? = nil
}

struct GodConfiguration: Codable, Equatable {
    var schemaVersion: Int
    var issuer: String
    var clientID: String
    var audience: String
    var apiURL: String
    var scopes: [String]
    var authentication: String
    var switchSyncDefault: Bool
    func validate(origin: String) throws {
        _ = try GodHTTP.origin(origin); _ = try GodHTTP.origin(issuer)
        guard schemaVersion == 1, clientID == "tokenbar-macos", apiURL == origin + "/api/tokenbar/v1", audience == apiURL,
              authentication == "device_authorization", switchSyncDefault,
              Set(scopes) == Set(["openid", "offline_access", "god.tokenbar.read", "god.tokenbar.sync"]), scopes.count == 4 else { throw GodError.invalidResponse }
    }
}

struct GodToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var configuration: GodConfiguration
    var user: GodUser?
    static func validSecret(_ value: String) -> Bool {
        (16...8192).contains(value.utf8.count) && value.range(of: "\\A[A-Za-z0-9._~+/=-]+\\z", options: .regularExpression) != nil
    }
}
struct GodUser: Codable, Equatable {
    var id: String
    var label: String
    var quotaAccess: Bool
    func validate() throws {
        guard (1...256).contains(id.count), id.range(of: "\\A[A-Za-z0-9-]+\\z", options: .regularExpression) != nil,
              (1...80).contains(label.count), label.rangeOfCharacter(from: .controlCharacters) == nil else { throw GodError.invalidResponse }
    }
}

struct GodDeviceGrant: Decodable {
    var device_code: String
    var user_code: String
    var verification_uri: String
    var verification_uri_complete: String?
    var expires_in: Int
    var interval: Int?
    func validate(issuer: String) throws {
        guard GodToken.validSecret(device_code), (4...64).contains(user_code.count),
              user_code.range(of: "\\A[A-Za-z0-9-]+\\z", options: .regularExpression) != nil,
              verification_uri == issuer + "/consent/openid/device-authorization",
              (1...900).contains(expires_in), (1...900).contains(interval ?? 5) else { throw GodError.invalidResponse }
        if let complete = verification_uri_complete {
            guard let url = URL(string: complete), GodHTTP.sameOrigin(url, try GodHTTP.origin(issuer)), url.path == "/consent/openid/device-authorization",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 1, items[0].name == "user_code", items[0].value == user_code else { throw GodError.invalidResponse }
        }
    }
}

struct GodSessionStorage {
    var read: (String) throws -> Data
    var write: (Data, String) throws -> Void
    var delete: (String) -> Void
    static let live = GodSessionStorage(
        read: { try CredentialStore.read(service: "wang.robby.tokenbar.god-session", account: $0) },
        write: { try CredentialStore.save($0, service: "wang.robby.tokenbar.god-session", account: $1) },
        delete: { CredentialStore.delete(service: "wang.robby.tokenbar.god-session", account: $0) })
}

/// Device authorization uses the same God Passkey page as the workbench. The
/// device code stays in memory; each Mac receives its own revocable grant.
@MainActor
final class GodAuthentication: ObservableObject {
    @Published private(set) var user: GodUser?
    @Published private(set) var isSigningIn = false
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    @Published var message: String?
    @Published private(set) var connection: GodConnection?
    var onSignIn: ((GodUser, GodConfiguration) async throws -> Void)?
    var onSignOut: (() -> Void)?
    private(set) var token: GodToken?
    private let http: GodHTTP
    private let directory: URL
    private let storage: GodSessionStorage
    private var loginTask: Task<Void, Never>?
    private var refreshTask: Task<GodToken, Error>?
    private var generation = 0
    static let keychainService = "wang.robby.tokenbar.god-session"

    init(directory: URL, http: GodHTTP = GodHTTP(), storage: GodSessionStorage = .live) {
        self.directory = directory; self.http = http; self.storage = storage
        let file = directory.appendingPathComponent("god-connection.json")
        if let bytes = try? Data(contentsOf: file), bytes.count <= 8192,
           let config = try? JSONDecoder().decode(GodConnection.self, from: bytes), (try? GodHTTP.origin(config.origin)) != nil {
            connection = config
        }
    }
    var hasSession: Bool { user != nil && token != nil }
    private var keychainAccount: String? { connection.map { Self.digest($0.origin) } }
    nonisolated static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    func configure(_ origin: String) throws {
        guard !isSigningIn, user == nil else { throw GodError.denied }
        let url = try GodHTTP.origin(origin.trimmingCharacters(in: .whitespacesAndNewlines))
        var value = url.absoluteString; if value.hasSuffix("/") { value.removeLast() }
        let next = GodConnection(origin: value, preferredBrowserBundleID: connection?.preferredBrowserBundleID,
                                 migrationSourceIDs: connection?.origin == value ? connection?.migrationSourceIDs : nil)
        try Self.savePrivate(JSONEncoder().encode(next), to: directory.appendingPathComponent("god-connection.json"))
        connection = next
    }

    func restore() async {
        let run = generation
        guard let key = keychainAccount, let connection,
              let bytes = try? storage.read(key), bytes.count <= 32768,
              let saved = try? JSONDecoder().decode(GodToken.self, from: bytes),
              (try? saved.configuration.validate(origin: connection.origin)) != nil,
              GodToken.validSecret(saved.accessToken), GodToken.validSecret(saved.refreshToken),
              let previousUser = saved.user, (try? previousUser.validate()) != nil else { return }
        token = saved
        do {
            let verified = try await verifyUser()
            try check(run)
            guard verified.id == previousUser.id else { throw GodError.signedOut }
            user = verified; try await onSignIn?(verified, saved.configuration)
        } catch {
            guard generation == run else { return }
            if error as? GodError == .signedOut { signOut() }
            else { message = GodError.unavailable.localizedDescription }
        }
    }

    func signIn() {
        guard !isSigningIn, user == nil, connection != nil else { return }
        generation += 1; let run = generation
        isSigningIn = true; message = nil
        loginTask = Task {
            defer { if generation == run { isSigningIn = false; userCode = nil; verificationURL = nil } }
            do { try await performSignIn(run: run) }
            catch is CancellationError { }
            catch { if generation == run { message = (error as? GodError ?? .unavailable).localizedDescription } }
        }
    }

    private func performSignIn(run: Int) async throws {
        guard let connection else { throw GodError.signedOut }
        let response = try await http.send(URLRequest(url: URL(string: connection.origin + "/api/tokenbar/v1/configuration")!), limit: 32768)
        guard response.status == 200 else { throw GodError.unavailable }
        let config = try JSONDecoder().decode(GodConfiguration.self, from: response.data)
        try config.validate(origin: connection.origin)
        let discovery = try await discover(config)
        let responseGrant = try await post(discovery.device, ["client_id": config.clientID, "scope": config.scopes.joined(separator: " "), "audience": config.audience])
        guard responseGrant.status == 200 else { throw GodError.denied }
        let grant = try JSONDecoder().decode(GodDeviceGrant.self, from: responseGrant.data); try grant.validate(issuer: config.issuer)
        try check(run)
        userCode = grant.user_code
        verificationURL = URL(string: grant.verification_uri_complete ?? grant.verification_uri)
        openVerification()
        let deadline = ProcessInfo.processInfo.systemUptime + Double(grant.expires_in)
        var interval = max(5, grant.interval ?? 5)
        while true {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try check(run)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GodError.expired }
            let result: GodHTTPResponse
            do { result = try await post(discovery.token, ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": grant.device_code,
                                                          "client_id": config.clientID, "audience": config.audience]) }
            catch { try check(run); interval = min(900, interval * 2); continue }
            if result.status == 200 {
                var next = try decodeToken(result.data, configuration: config)
                guard ProcessInfo.processInfo.systemUptime < deadline, generation == run else { await revoke(next); throw GodError.expired }
                token = next
                do {
                    let verified = try await verifyUser(); try check(run)
                    next.user = verified; try persist(next); token = next; user = verified
                } catch { token = nil; user = nil; await revoke(next); throw error }
                if let user {
                    do { try await onSignIn?(user, config) }
                    catch { if generation == run { message = GodError.unavailable.localizedDescription } }
                }
                return
            }
            let code = (try? JSONSerialization.jsonObject(with: result.data) as? [String: Any])?["error"] as? String
            if code == "authorization_pending" { continue }
            if code == "slow_down" { interval = min(900, interval + 5); continue }
            if result.status == 429 || result.status >= 500 { interval = min(900, interval * 2); continue }
            throw code == "expired_token" ? GodError.expired : GodError.denied
        }
    }

    func openVerification() {
        guard let url = verificationURL else { return }
        if let browser = connection?.preferredBrowserBundleID,
           let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(url) }
    }

    func cancelSignIn() {
        generation += 1; loginTask?.cancel(); loginTask = nil
        isSigningIn = false; userCode = nil; verificationURL = nil
    }
    func signOut() {
        let previous = token
        cancelSignIn(); refreshTask?.cancel(); refreshTask = nil
        token = nil; user = nil; message = nil
        if let key = keychainAccount { storage.delete(key) }
        onSignOut?()
        if let previous { Task { await revoke(previous) } }
    }

    func request(path: String, method: String = "GET", body: Data? = nil, limit: Int = 16 * 1024 * 1024) async throws -> GodHTTPResponse {
        guard ["/session", "/quotas", "/sync"].contains(path), method == "GET" || (path == "/sync" && method == "PATCH") else { throw GodError.invalidResponse }
        let run = generation
        var current = try await validToken()
        for attempt in 0...1 {
            var req = URLRequest(url: URL(string: current.configuration.apiURL + path)!)
            req.httpMethod = method; req.httpBody = body; req.setValue("Bearer " + current.accessToken, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let response = try await http.send(req, limit: limit)
            try check(run)
            if response.status == 401 && attempt == 0 { current = try await validToken(forceRefresh: true); continue }
            if response.status == 401 { throw GodError.signedOut }
            return response
        }
        throw GodError.signedOut
    }
    private func verifyUser() async throws -> GodUser {
        struct Envelope: Decodable { var schemaVersion: Int; var user: GodUser }
        let result = try await request(path: "/session", limit: 32768)
        guard result.status == 200 else { throw GodError.denied }
        let value = try JSONDecoder().decode(Envelope.self, from: result.data)
        guard value.schemaVersion == 1 else { throw GodError.invalidResponse }; try value.user.validate(); return value.user
    }

    private func validToken(forceRefresh: Bool = false) async throws -> GodToken {
        guard let saved = token else { throw GodError.signedOut }
        if !forceRefresh && saved.expiresAt > Date().addingTimeInterval(30) { return saved }
        if let refreshTask { return try await refreshTask.value }
        let run = generation
        let task = Task { @MainActor () throws -> GodToken in
            let discovery = try await discover(saved.configuration)
            let result = try await post(discovery.token, ["grant_type": "refresh_token", "refresh_token": saved.refreshToken,
                                                         "client_id": saved.configuration.clientID, "audience": saved.configuration.audience])
            if result.status == 400 || result.status == 401 { throw GodError.signedOut }
            guard result.status == 200 else { throw GodError.unavailable }
            var next = try decodeToken(result.data, configuration: saved.configuration, fallbackRefresh: saved.refreshToken); next.user = saved.user
            guard run == generation else { await revoke(next); throw CancellationError() }
            do { try persist(next) }
            catch { await revoke(next); throw error }
            token = next; return next
        }
        refreshTask = task
        defer { if run == generation { refreshTask = nil } }
        return try await task.value
    }

    private func decodeToken(_ data: Data, configuration: GodConfiguration, fallbackRefresh: String? = nil) throws -> GodToken {
        struct Body: Decodable { var access_token: String; var refresh_token: String?; var token_type: String; var expires_in: Int; var scope: String? }
        let value = try JSONDecoder().decode(Body.self, from: data)
        guard let refreshToken = value.refresh_token ?? fallbackRefresh,
              value.token_type.lowercased() == "bearer", GodToken.validSecret(value.access_token), GodToken.validSecret(refreshToken),
              (60...600).contains(value.expires_in), value.scope == nil || Set(value.scope!.split(separator: " ").map(String.init)) == Set(configuration.scopes) else { throw GodError.invalidResponse }
        return GodToken(accessToken: value.access_token, refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(Double(value.expires_in)), configuration: configuration)
    }
    private func persist(_ value: GodToken) throws {
        guard let key = keychainAccount else { throw GodError.storage }
        do { try storage.write(JSONEncoder().encode(value), key) }
        catch { throw GodError.storage }
    }
    private func check(_ run: Int) throws { try Task.checkCancellation(); if run != generation { throw CancellationError() } }
    private struct Discovery { var device: URL; var token: URL; var revoke: URL }
    private func discover(_ config: GodConfiguration) async throws -> Discovery {
        let issuer = try GodHTTP.origin(config.issuer)
        let response = try await http.send(URLRequest(url: URL(string: config.issuer + "/.well-known/openid-configuration")!), limit: 131072)
        guard response.status == 200, let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], object["issuer"] as? String == config.issuer,
              (object["grant_types_supported"] as? [String])?.contains("urn:ietf:params:oauth:grant-type:device_code") == true,
              (object["token_endpoint_auth_methods_supported"] as? [String])?.contains("none") == true else { throw GodError.invalidResponse }
        func endpoint(_ key: String, _ path: String) throws -> URL {
            guard let value = object[key] as? String, let url = URL(string: value), GodHTTP.sameOrigin(url, issuer), url.query == nil, url.path == path else { throw GodError.invalidResponse }
            return url
        }
        return try Discovery(device: endpoint("device_authorization_endpoint", "/api/oidc/device-authorization"), token: endpoint("token_endpoint", "/api/oidc/token"), revoke: endpoint("revocation_endpoint", "/api/oidc/revocation"))
    }
    private func post(_ url: URL, _ values: [String: String]) async throws -> GodHTTPResponse {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = GodHTTP.form(values)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.send(request, limit: 65536)
    }
    private func revoke(_ value: GodToken) async {
        guard let discovery = try? await discover(value.configuration) else { return }
        for (token, hint) in [(value.refreshToken, "refresh_token"), (value.accessToken, "access_token")] {
            _ = try? await post(discovery.revoke, ["client_id": value.configuration.clientID, "token": token, "token_type_hint": hint])
        }
    }
    static func savePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw GodError.storage }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary); try file.write(contentsOf: data); try file.synchronize(); try file.close()
        guard rename(temporary.path, url.path) == 0 else { throw GodError.storage }
    }
}
