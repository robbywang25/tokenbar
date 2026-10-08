import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// Read-only adapters. Provider response bodies and credentials must never enter logs.
struct ProviderClient {
    private let configuration: URLSessionConfiguration
    private let now: () -> Date
    private let credentialReader: @Sendable (String, String?) throws -> Data
    private let sshReader: @Sendable ([String]) async throws -> Data
    static let maximumBytes = 2 * 1_024 * 1_024

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral, now: @escaping () -> Date = Date.init,
         credentialReader: @escaping @Sendable (String, String?) throws -> Data = { try CredentialStore.read(service: $0, account: $1) },
         sshReader: @escaping @Sendable ([String]) async throws -> Data = { try await SnapshotProcessReader().read(executable: "/usr/bin/ssh", arguments: $0) }) {
        configuration = sessionConfiguration
        self.now = now
        self.credentialReader = credentialReader
        self.sshReader = sshReader
    }

    func fetch(_ config: AccountConfig) async throws -> AccountReading {
        switch (config.provider, config.method) {
        case (.codex, .localFile), (.codex, .keychain):
            let auth = try credential(config)
            guard let tokens = auth["tokens"] as? [String: Any], let token = Self.secret(tokens["access_token"]) else { throw ProviderError.needsAuth }
            let accountID = Self.identifier(tokens["account_id"])
            var headers = ["Authorization": "Bearer \(token)", "OAI-App-Brand": "codex"]
            if let accountID { headers["ChatGPT-Account-ID"] = accountID }
            let data = try await get("https://chatgpt.com/backend-api/wham/usage", headers: headers)
            let object = try Self.object(data)
            if let expected = accountID, let actual = Self.identifier(object["account_id"]), expected != actual { throw ProviderError.invalidData }
            var reading = try Self.parseCodex(data, at: now())
            let stableID = Self.identifier(object["account_id"]) ?? accountID ?? Self.jwtSubject(token)
            reading.identityKey = Self.identity(provider: "codex", accountID: stableID ?? token)
            // Reset cards are optional; a failure must not discard a valid quota read.
            if reading.resetCardsAvailable != nil,
               let details = try? await get("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: headers),
               let detailObject = try? Self.object(details),
               let count = Self.nonnegativeInteger(detailObject["available_count"]),
               let cards = detailObject["credits"] as? [[String: Any]] {
                reading.resetCardsAvailable = count
                reading.resetCards = Self.cards(cards)
            }
            return reading
        case (.claude, .localFile), (.claude, .keychain):
            let auth = try credential(config)
            let oauth = (auth["claudeAiOauth"] as? [String: Any]) ?? auth
            guard let token = Self.secret(oauth["accessToken"]) else { throw ProviderError.needsAuth }
            if let expiration = Self.date(oauth["expiresAt"]), expiration <= now() { throw ProviderError.needsAuth }
            let data = try await get("https://api.anthropic.com/api/oauth/usage", headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "TokenBar/0.1"])
            var reading = try Self.parseClaude(data, at: now())
            let profile = auth["oauthAccount"] as? [String: Any]
            let accountID = Self.identifier(oauth["accountUuid"]) ?? Self.identifier(profile?["accountUuid"]) ?? Self.jwtSubject(token)
            // Opaque credentials may omit identity. The fallback only deduplicates
            // the same credential, and deliberately does not claim cross-token identity.
            reading.identityKey = Self.identity(provider: "claude", accountID: accountID ?? token)
            return reading
        case (.grok, .grokCLI):
            let path = NSString(string: config.location).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw ProviderError.invalidConfiguration }
            let data = try await GrokBillingReader().read(executable: path)
            var reading = try Self.parseGrok(data, at: now())
            // ACP selects the CLI's default login. Changing an executable path
            // never creates a separately authenticated account.
            reading.identityKey = Self.identity(provider: "grok", accountID: "local-default-login")
            return reading
        case (.snapshot, .snapshotFile):
            let data = try Self.readFile(config.location)
            return try Self.parseSnapshot(data, sourceAccountID: config.sourceAccountID, source: URL(fileURLWithPath: NSString(string: config.location).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path, at: now())
        case (.snapshot, .snapshotURL):
            var headers: [String: String] = [:]
            if let data = try? credentialReader(CredentialStore.serviceName, config.id.uuidString),
               let raw = String(data: data, encoding: .utf8), let token = Self.secret(raw) {
                headers["Authorization"] = "Bearer \(token)"
            }
            let data = try await get(config.location, headers: headers)
            return try Self.parseSnapshot(data, sourceAccountID: config.sourceAccountID, source: config.location, at: now())
        case (.snapshot, .snapshotSSH):
            let arguments = try Self.buildSSHArguments(host: config.sshHost ?? "", path: config.location, useSudo: config.sshUseSudo == true)
            let source = "ssh:\(config.sshHost ?? ""):\(config.location)"
            let cacheKey = source + (config.sshUseSudo == true ? ":sudo" : ":user")
            let reader = sshReader
            let data = try await SnapshotSourceCache.shared.read(key: cacheKey) {
                try await reader(arguments)
            }
            return try Self.parseSnapshot(data, sourceAccountID: config.sourceAccountID, source: source, at: now())
        default: throw ProviderError.invalidConfiguration
        }
    }

    private func credential(_ config: AccountConfig) throws -> [String: Any] {
        do {
            let data = config.method == .keychain ? try credentialReader(config.location, nil) : try Self.readFile(config.location)
            return try Self.object(data)
        } catch { throw ProviderError.needsAuth }
    }

    private func get(_ location: String, headers: [String: String]) async throws -> Data {
        let url = try Self.validatedURL(location)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await BoundedHTTPReader(configuration: configuration).read(request)
    }

    static func validatedURL(_ location: String) throws -> URL {
        guard let parts = URLComponents(string: location), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else { throw ProviderError.invalidConfiguration }
        return url
    }

    static func buildSSHArguments(host: String, path: String, useSudo: Bool = false) throws -> [String] {
        guard host.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,100}\\z", options: .regularExpression) != nil,
              path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProviderError.invalidConfiguration
        }
        // SSH passes its command through the remote login shell. A single quoted
        // word with escaped quotes keeps spaces/metacharacters inside the path.
        let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = (useSudo ? "sudo -n cat -- " : "cat -- ") + quotedPath
        return ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
                "-o", "RequestTTY=no", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=8",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "--", host, command]
    }

    static func readFile(_ path: String) throws -> Data {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ProviderError.invalidConfiguration }
        let url = URL(fileURLWithPath: expanded)
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let count = values.fileSize, count <= maximumBytes else { throw ProviderError.invalidData }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw ProviderError.invalidData }
            return data
        } catch let error as ProviderError { throw error }
        catch { throw ProviderError.invalidConfiguration }
    }

    static func parseCodex(_ data: Data, at now: Date) throws -> AccountReading {
        let object = try object(data)
        var result = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now)
        func add(_ value: Any?, prefix: String = "", group: String = "default", model: String? = nil) throws {
            guard let rate = value as? [String: Any] else { return }
            for (name, key) in [("primary", "primary_window"), ("secondary", "secondary_window")] {
                guard let window = rate[key] as? [String: Any] else { continue }
                let used = try percentage(window["used_percent"])
                let seconds = number(window["limit_window_seconds"])
                let reset = date(window["reset_at"])
                result.windows.append(QuotaWindow(id: prefix + name, label: label(name, seconds: seconds), remainingPercent: 100 - used, resetsAt: reset, startsAt: start(reset, seconds: seconds), group: group, model: model))
            }
        }
        try add(object["rate_limit"])
        if let additional = object["additional_rate_limits"] as? [[String: Any]] {
            guard additional.count <= 24 else { throw ProviderError.invalidData }
            for (index, item) in additional.enumerated() {
                try add(item["rate_limit"], prefix: "additional-\(index + 1)-", group: item["limit_name"] as? String == "gpt-reserve" ? "reserve" : "additional", model: identifier(item["normal_model_slug"]))
            }
        }
        try add(object["code_review_rate_limit"], prefix: "code-review-", group: "code-review")
        guard !result.windows.isEmpty else { throw ProviderError.invalidData }
        applyCredits(object["credits"], to: &result)
        applyResetCards(object["rate_limit_reset_credits"], to: &result)
        result.email = safeEmail(object["email"])
        return result
    }

    static func parseClaude(_ data: Data, at now: Date) throws -> AccountReading {
        let object = try object(data)
        var windows: [QuotaWindow] = []
        for id in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"] {
            guard let value = object[id] as? [String: Any] else { continue }
            let reset = date(value["resets_at"])
            windows.append(QuotaWindow(id: id, label: label(id), remainingPercent: 100 - (try percentage(value["utilization"])), resetsAt: reset, startsAt: start(reset, seconds: id == "five_hour" ? 18_000 : 604_800)))
        }
        guard !windows.isEmpty else { throw ProviderError.invalidData }
        return AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: windows)
    }

    static func parseGrok(_ data: Data, at now: Date) throws -> AccountReading {
        let object = try object(data)
        guard let config = object["config"] as? [String: Any] else { throw ProviderError.invalidData }
        let period = config["currentPeriod"] as? [String: Any]
        let kind = period?["type"] as? String
        let id = kind == "USAGE_PERIOD_TYPE_WEEKLY" ? "weekly" : kind == "USAGE_PERIOD_TYPE_DAILY" ? "daily" : "primary"
        let window = QuotaWindow(id: id, label: label(id), remainingPercent: 100 - (try percentage(config["creditUsagePercent"])), resetsAt: date(period?["end"] ?? config["billingPeriodEnd"]), startsAt: date(period?["start"]))
        return AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [window])
    }

    /// Accepts the documented portable schema and the existing collector's v1 schema.
    /// Source timestamps are preserved; opening a stale file never refreshes its age.
    static func parseSnapshot(_ data: Data, sourceAccountID: String = "", source: String = "snapshot", at now: Date) throws -> AccountReading {
        let root = try object(data)
        if let version = root["schemaVersion"], number(version) != 1 { throw ProviderError.invalidData }
        let account: [String: Any]
        if let accounts = root["accounts"] as? [[String: Any]] {
            guard accounts.count <= 1_000 else { throw ProviderError.invalidData }
            let matches = sourceAccountID.isEmpty ? accounts : accounts.filter { ($0["id"] as? String) == sourceAccountID }
            guard matches.count == 1, let match = matches.first else { throw ProviderError.invalidConfiguration }
            account = match
        } else {
            guard sourceAccountID.isEmpty || accountID(root) == sourceAccountID else { throw ProviderError.invalidConfiguration }
            account = root
        }
        let statuses: [String: ReadingStatus] = ["connected": .connected, "stale": .stale, "needsAuth": .needsAuth, "needs_auth": .needsAuth, "unavailable": .unavailable, "notConfigured": .notConfigured, "not_configured": .notConfigured, "unsupported": .unsupported]
        guard let rawStatus = account["status"] as? String, let status = statuses[rawStatus] else { throw ProviderError.invalidData }
        let rawObserved = account["lastSuccessAt"]
        let observed = date(rawObserved)
        // Only absent/null success times may fall back to a document timestamp.
        // An explicitly malformed timestamp cannot turn an untrusted balance fresh.
        if let rawObserved, !(rawObserved is NSNull), observed == nil { throw ProviderError.invalidData }
        let checked = date(account["checkedAt"]) ?? date(root["collectedAt"]) ?? observed ?? now
        var result = AccountReading(status: status, checkedAt: checked, lastSuccessAt: observed)
        if let items = account["windows"] {
            guard let windows = items as? [[String: Any]], windows.count <= 64 else { throw ProviderError.invalidData }
            result.windows = try windows.enumerated().map { try snapshotWindow($0.element, index: $0.offset) }
            guard Set(result.windows.map(\.id)).count == result.windows.count else { throw ProviderError.invalidData }
        }
        applyCredits(account["credits"], to: &result)
        applyResetCards(account["resetCredits"], to: &result)
        let hasQuota = !result.windows.isEmpty || result.credits != nil || result.unlimitedCredits || result.resetCardsAvailable != nil
        if result.lastSuccessAt == nil && (status == .connected || (status == .stale && hasQuota)) {
            result.lastSuccessAt = date(root["collectedAt"])
        }
        if status == .connected, result.windows.isEmpty, result.credits == nil, !result.unlimitedCredits, result.resetCardsAvailable == nil { throw ProviderError.invalidData }
        let profile = account["profile"] as? [String: Any]
        result.name = safeName(profile?["name"])
        result.email = safeEmail(profile?["email"])
        if let identityValue = account["identity"] as? [String: Any], let provider = identifier(identityValue["provider"]), let id = identifier(identityValue["accountID"]) {
            result.identityKey = identity(provider: provider, accountID: id)
        } else {
            result.identityKey = identity(provider: "snapshot", accountID: source + "\u{0}" + (accountID(account) ?? sourceAccountID))
        }
        if status == .connected && !result.isFresh(at: now) { result.status = .stale }
        let reason = account["reason"] as? String
        switch result.status {
        case .connected: result.detail = ""
        case .stale: result.detail = "来源读数已过期，等待数据源更新。"
        case .needsAuth: result.detail = ProviderError.needsAuth.message
        case .unavailable:
            result.detail = reason == "pooled" ? "此账号使用共享额度，来源未提供独立余量。" : reason == "unsupported" ? ProviderError.unsupported.message : ProviderError.unavailable.message
        case .notConfigured:
            result.detail = reason == "duplicate" ? ProviderError.duplicate.message : reason == "unsupported" ? ProviderError.unsupported.message : "尚未配置此账号的独立额度来源。"
        case .unsupported: result.detail = ProviderError.unsupported.message
        }
        return result
    }

    private static func snapshotWindow(_ value: [String: Any], index: Int) throws -> QuotaWindow {
        let percent = value["remainingPercent"] == nil || value["remainingPercent"] is NSNull ? nil : try percentage(value["remainingPercent"])
        func optionalAmount(_ key: String) throws -> Double? {
            guard let raw = value[key], !(raw is NSNull) else { return nil }
            guard let amount = number(raw), amount >= 0 else { throw ProviderError.invalidData }
            return amount
        }
        let remaining = try optionalAmount("remaining"), limit = try optionalAmount("limit")
        if let remaining, let limit, remaining > limit { throw ProviderError.invalidData }
        let unlimited = boolean(value["unlimited"]) == true
        guard percent != nil || remaining != nil || unlimited else { throw ProviderError.invalidData }
        let id = identifier(value["id"]) ?? "window-\(index + 1)"
        let group = value["quotaGroup"] as? String ?? value["group"] as? String ?? "default"
        guard ["default", "reserve", "code-review", "additional"].contains(group) else { throw ProviderError.invalidData }
        let unit = value["unit"] as? String ?? "percent"
        guard ["percent", "tokens", "messages", "credits", "USD"].contains(unit) else { throw ProviderError.invalidData }
        return QuotaWindow(id: id, label: safeName(value["label"]) ?? label(id, seconds: number(value["windowSeconds"])), remainingPercent: percent, remaining: remaining, limit: limit, unit: unit, resetsAt: date(value["resetsAt"]), startsAt: date(value["startsAt"]), group: group, model: identifier(value["model"]), unlimited: unlimited)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes,
              let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else { throw ProviderError.invalidData }
        return object
    }
    private static func accountID(_ value: [String: Any]) -> String? { identifier(value["id"]) }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func percentage(_ value: Any?) throws -> Double {
        guard let value = number(value), (0...100).contains(value) else { throw ProviderError.invalidData }
        return value
    }
    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let value = number(value), value >= 0, value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }
    private static func secret(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 128 * 1_024,
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else { return nil }
        return value
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 256,
              value.range(of: "^[A-Za-z0-9._:@+/-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }
    private static func safeName(_ value: Any?) -> String? {
        guard let value = value as? String, (1...80).contains(value.count),
              value.range(of: "^[\\p{L}\\p{N} .·（）()_+/-]+$", options: .regularExpression) != nil,
              value.range(of: "bearer|secret|eyJ|sk-", options: [.caseInsensitive, .regularExpression]) == nil else { return nil }
        return value
    }
    private static func safeEmail(_ value: Any?) -> String? {
        guard let value = value as? String, value.count <= 254,
              value.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    private static func date(_ raw: Any?) -> Date? {
        let result: Date?
        if let epoch = number(raw) { result = Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1_000 : epoch) }
        else if let value = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            result = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        } else { result = nil }
        guard let result, result.timeIntervalSince1970 >= 1_577_836_800, result.timeIntervalSince1970 <= 4_102_444_800 else { return nil }
        return result
    }
    private static func start(_ reset: Date?, seconds: Double?) -> Date? {
        guard let reset, let seconds, seconds > 0, seconds <= 366 * 86_400 else { return nil }
        return reset.addingTimeInterval(-seconds)
    }
    private static func label(_ id: String, seconds: Double? = nil) -> String {
        if seconds == 18_000 { return "5 小时" }; if seconds == 604_800 { return "每周" }; if seconds == 86_400 { return "每日" }
        return ["five_hour": "5 小时", "seven_day": "每周", "weekly": "每周", "daily": "每日", "seven_day_opus": "Opus 每周", "seven_day_sonnet": "Sonnet 每周", "seven_day_oauth_apps": "OAuth 应用每周", "credits": "可用点数"][id] ?? "额度窗口"
    }
    private static func applyCredits(_ raw: Any?, to reading: inout AccountReading) {
        guard let value = raw as? [String: Any] else { return }
        if boolean(value["unlimited"]) == true { reading.unlimitedCredits = true; return }
        let rawAmount = value["remaining"] ?? value["balance"]
        let amount = number(rawAmount) ?? (rawAmount as? String).flatMap { $0.range(of: "^\\d+(?:\\.\\d+)?$", options: .regularExpression) == nil ? nil : Double($0) }
        if let amount, amount.isFinite, amount >= 0, amount <= 9_007_199_254_740_991 { reading.credits = amount }
    }
    private static func applyResetCards(_ raw: Any?, to reading: inout AccountReading) {
        guard let value = raw as? [String: Any], let count = nonnegativeInteger(value["available"] ?? value["available_count"]) else { return }
        reading.resetCardsAvailable = count
        if let values = value["cards"] as? [[String: Any]] { reading.resetCards = cards(values) }
    }
    private static func cards(_ values: [[String: Any]]) -> [ResetCard] {
        values.prefix(100).map { value in
            let status = value["status"] as? String ?? "unknown"
            return ResetCard(status: ["available", "redeemed", "expired", "redeeming"].contains(status) ? status : "unknown", expiresAt: date(value["expiresAt"] ?? value["expires_at"]))
        }
    }
    static func identity(provider: String, accountID: String) -> String {
        SHA256.hash(data: Data((provider.lowercased() + "\u{0}" + accountID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var segment = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
        guard let data = Data(base64Encoded: segment), let value = try? object(data) else { return nil }
        return identifier(value["sub"])
    }
}

/// Each request owns an ephemeral session; redirects cannot forward credentials.
private final class BoundedHTTPReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var cancelled = false
    init(configuration: URLSessionConfiguration) { self.configuration = configuration.copy() as! URLSessionConfiguration }

    func read(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: ProviderError.unavailable); return }
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 20
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                configuration.urlCredentialStorage = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(ProviderError.unavailable))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let session = self.session
        self.session = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(ProviderError.invalidData)); return }
        guard (200...299).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(response.statusCode == 401 || response.statusCode == 403 ? ProviderError.needsAuth : ProviderError.unavailable))
            return
        }
        guard response.expectedContentLength <= ProviderClient.maximumBytes else { completionHandler(.cancel); finish(.failure(ProviderError.invalidData)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        guard buffer.count + data.count <= ProviderClient.maximumBytes else { lock.unlock(); finish(.failure(ProviderError.invalidData)); return }
        buffer.append(data)
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let data = buffer; lock.unlock()
        finish(error == nil ? .success(data) : .failure(ProviderError.unavailable))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(ProviderError.invalidConfiguration))
    }
}

/// A bounded ACP client. No conversation/session, prompt, execution, or purchase methods.
private final class GrokBillingReader: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var bytes = 0
    private var initialized = false
    private var rejectedServerRequests = 0
    private var cancelled = false

    func read(executable: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: ProviderError.unavailable); return }
                self.continuation = continuation
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["agent", "--no-leader", "stdio"]
                process.environment = ProcessInfo.processInfo.environment.merging(["GROK_TELEMETRY_ENABLED": "false"]) { _, new in new }
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
                process.terminationHandler = { [weak self] _ in self?.finish(.failure(ProviderError.unavailable)) }
                do {
                    try process.run()
                    send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "TokenBar", "version": "0.1"]]])
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(.failure(ProviderError.unavailable)) }
                } catch { finish(.failure(ProviderError.unavailable)) }
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; self.lock.unlock()
            self.finish(.failure(ProviderError.unavailable))
        }
    }
    private func send(_ value: [String: Any]) {
        guard continuation != nil, var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        guard data.count < 1_024 else { finish(.failure(ProviderError.invalidData)); return }
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { finish(.failure(ProviderError.unavailable)) }
    }
    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil else { return }
        guard !data.isEmpty else { finish(.failure(ProviderError.unavailable)); return }
        bytes += data.count
        guard bytes <= ProviderClient.maximumBytes else { finish(.failure(ProviderError.invalidData)); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { finish(.failure(ProviderError.invalidData)); return }
            if message["method"] != nil, let id = message["id"] {
                // Keep all writes below pipe capacity, including a hostile peer
                // that requests permission repeatedly without reading responses.
                rejectedServerRequests += 1
                let boundedID = id is NSNumber || (id as? String).map { $0.utf8.count <= 128 } == true
                guard boundedID, rejectedServerRequests <= 8 else { finish(.failure(ProviderError.invalidData)); return }
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Read-only quota client"]])
            } else if message["id"] as? Int == 1 && !initialized {
                guard message["error"] == nil else { finish(.failure(ProviderError.unavailable)); return }
                initialized = true
                send(["jsonrpc": "2.0", "id": 2, "method": "_x.ai/billing", "params": ["action": "get"]])
            } else if message["id"] as? Int == 2 && initialized {
                guard message["error"] == nil, let result = message["result"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: result) else { finish(.failure(ProviderError.unavailable)); return }
                finish(.success(data)); return
            }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        let running = process.isRunning
        if running { process.terminate() }
        lock.unlock()
        if running {
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        continuation.resume(with: result)
    }
}

/// One source document may contain many configured rows. Share its in-flight
/// read and briefly reuse both success and failure so a poll creates one process.
actor SnapshotSourceCache {
    static let shared = SnapshotSourceCache()
    private struct Entry { let expires: Date; let result: Result<Data, ProviderError> }
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let ttl: TimeInterval
    init(ttl: TimeInterval = 5) { self.ttl = ttl }

    func read(key: String, loader: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let now = Date()
        if let entry = entries[key], entry.expires > now { return try entry.result.get() }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await loader() }
        inFlight[key] = task
        let result: Result<Data, ProviderError>
        do { result = .success(try await task.value) }
        catch { result = .failure(error as? ProviderError ?? .unavailable) }
        inFlight[key] = nil
        entries = entries.filter { $0.value.expires > Date() }
        entries[key] = Entry(expires: Date().addingTimeInterval(ttl), result: result)
        return try result.get()
    }
}

/// Captures bounded stdout only. All production calls choose the fixed SSH
/// executable and validated, read-only arguments above; no shell is run locally.
final class SnapshotProcessReader: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let process = Process()
    private let output = Pipe()
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var cancelled = false
    private var outputEnded = false
    private var exitStatus: Int32?
    private var maximumBytes = ProviderClient.maximumBytes

    func read(executable: String, arguments: [String], timeout: TimeInterval = 20, maximumBytes: Int = ProviderClient.maximumBytes) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: ProviderError.unavailable); return }
                self.continuation = continuation
                self.maximumBytes = maximumBytes
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
                process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(ProviderError.unavailable)) }
                } catch { finish(.failure(ProviderError.unavailable)) }
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; self.lock.unlock()
            self.finish(.failure(ProviderError.unavailable))
        }
    }

    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil else { return }
        guard !data.isEmpty else {
            outputEnded = true
            output.fileHandleForReading.readabilityHandler = nil
            completeIfReady()
            return
        }
        guard buffer.count + data.count <= maximumBytes else { finish(.failure(ProviderError.invalidData)); return }
        buffer.append(data)
    }
    private func exited(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        exitStatus = status
        if status != 0 { finish(.failure(ProviderError.unavailable)) }
        else { completeIfReady() }
    }
    private func completeIfReady() {
        if outputEnded && exitStatus == 0 { finish(.success(buffer)) }
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        let running = process.isRunning
        if running { process.terminate() }
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        if running {
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        continuation.resume(with: result)
    }
}
