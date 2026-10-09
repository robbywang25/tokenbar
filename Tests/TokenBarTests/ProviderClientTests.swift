import XCTest
@testable import TokenBar

final class ProviderClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_504_000)

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testCodexKeepsDefaultReserveReviewAndCreditsSeparate() throws {
        let data = try json([
            "rate_limit": ["primary_window": ["used_percent": 0, "limit_window_seconds": 18_000, "reset_at": now.timeIntervalSince1970 + 3_600]],
            "additional_rate_limits": [["limit_name": "gpt-reserve", "normal_model_slug": "example-model", "rate_limit": ["secondary_window": ["used_percent": 100, "limit_window_seconds": 604_800]]]],
            "code_review_rate_limit": ["primary_window": ["used_percent": 25]],
            "credits": ["balance": "42.5", "unlimited": false],
            "rate_limit_reset_credits": ["available": 2, "cards": [["status": "available", "expires_at": now.timeIntervalSince1970 + 86_400]]]
        ])
        let reading = try ProviderClient.parseCodex(data, at: now)
        XCTAssertEqual(reading.windows.map(\.remainingPercent), [100, 0, 75])
        XCTAssertEqual(reading.windows.map(\.group), ["default", "reserve", "code-review"])
        XCTAssertEqual(reading.windows[1].model, "example-model")
        XCTAssertEqual(reading.windows[0].label, "5 小时")
        XCTAssertEqual(reading.windows[0].startsAt, now.addingTimeInterval(3_600 - 18_000))
        XCTAssertEqual(reading.credits, 42.5)
        XCTAssertEqual(reading.resetCardsAvailable, 2)
        XCTAssertEqual(reading.resetCards[0].expiresAt, now.addingTimeInterval(86_400))
    }

    func testProviderPercentagesRejectOutOfRangeAndBooleans() throws {
        for invalid: Any in [-0.1, 100.1, true, "25"] {
            let data = try json(["rate_limit": ["primary_window": ["used_percent": invalid]]])
            XCTAssertThrowsError(try ProviderClient.parseCodex(data, at: now)) { XCTAssertEqual($0 as? ProviderError, .invalidData) }
        }
    }

    func testClaudeModelWindowsAndResetTimes() throws {
        let data = try json([
            "five_hour": ["utilization": 16.5, "resets_at": "2026-10-09T12:00:00.000Z"],
            "seven_day_opus": ["utilization": 75],
            "seven_day_sonnet": NSNull()
        ])
        let reading = try ProviderClient.parseClaude(data, at: now)
        XCTAssertEqual(reading.windows.count, 2)
        XCTAssertEqual(reading.windows[0].remainingPercent, 83.5)
        XCTAssertEqual(reading.windows[1].label, "Opus 每周")
        XCTAssertEqual(reading.windows[0].resetsAt?.timeIntervalSince(reading.windows[0].startsAt!), 18_000)
    }

    func testGrokBillingUsesProviderPeriod() throws {
        let data = try json(["config": ["creditUsagePercent": 62, "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-08T12:00:00Z", "end": "2026-10-15T12:00:00Z"]]])
        let reading = try ProviderClient.parseGrok(data, at: now)
        XCTAssertEqual(reading.windows[0].remainingPercent, 38)
        XCTAssertEqual(reading.windows[0].label, "每周")
        XCTAssertEqual(reading.windows[0].resetsAt?.timeIntervalSince(reading.windows[0].startsAt!), 604_800)
    }

    func testSnapshotNeverFreshensOldSourceTimestamp() throws {
        let old = now.addingTimeInterval(-3_600)
        let data = try snapshot(observed: old)
        let reading = try ProviderClient.parseSnapshot(data, at: now)
        XCTAssertEqual(reading.status, .stale)
        XCTAssertEqual(reading.lastSuccessAt, old)
        XCTAssertEqual(reading.checkedAt, old)
        XCTAssertEqual(reading.windows.first?.remainingPercent, 40)
    }

    func testSnapshotFutureTimestampAndMissingTimestampAreStale() throws {
        let future = try snapshot(observed: now.addingTimeInterval(61))
        XCTAssertEqual(try ProviderClient.parseSnapshot(future, at: now).status, .stale)
        let absent = try json(["id": "one", "status": "connected", "windows": [["remainingPercent": 40]]])
        let reading = try ProviderClient.parseSnapshot(absent, at: now)
        XCTAssertEqual(reading.status, .stale)
        XCTAssertNil(reading.lastSuccessAt)
    }

    func testMalformedSuccessTimestampCannotFallbackToFreshCollectionTime() throws {
        for malformed: Any in ["not-a-date", "", true, -1, "2101-01-01T00:00:00Z"] {
            let data = try json(["collectedAt": now.timeIntervalSince1970, "accounts": [["id": "quota", "status": "connected", "lastSuccessAt": malformed, "windows": [["remainingPercent": 40]]]]])
            XCTAssertThrowsError(try ProviderClient.parseSnapshot(data, at: now)) { XCTAssertEqual($0 as? ProviderError, .invalidData) }
        }
        let missing = try json(["collectedAt": now.timeIntervalSince1970, "accounts": [["id": "quota", "status": "connected", "lastSuccessAt": NSNull(), "windows": [["remainingPercent": 40]]]]])
        XCTAssertEqual(try ProviderClient.parseSnapshot(missing, at: now).lastSuccessAt, now)
    }

    func testSnapshotExpiredWindowIsStaleEvenWhenCollectionIsRecent() throws {
        let data = try json(["id": "one", "status": "connected", "lastSuccessAt": now.timeIntervalSince1970, "windows": [["remainingPercent": 40, "resetsAt": now.addingTimeInterval(-1).timeIntervalSince1970]]])
        XCTAssertEqual(try ProviderClient.parseSnapshot(data, at: now).status, .stale)
    }

    func testSnapshotRetainsReserveButItsResetDoesNotExpireVisibleQuota() throws {
        let windows: [[String: Any]] = [
            ["id": "weekly", "remainingPercent": 42, "resetsAt": now.addingTimeInterval(3600).timeIntervalSince1970],
            ["id": "reserve", "remainingPercent": 100, "quotaGroup": "reserve", "resetsAt": now.addingTimeInterval(-1).timeIntervalSince1970]
        ]
        for sourceStatus in ["connected", "stale"] {
            let data = try json(["id": "one", "status": sourceStatus, "lastSuccessAt": now.timeIntervalSince1970,
                                 "windows": windows, "credits": ["remaining": 56_000], "resetCredits": ["available": 3]])
            let reading = try ProviderClient.parseSnapshot(data, at: now)
            XCTAssertEqual(reading.status, sourceStatus == "connected" ? .connected : .stale)
            XCTAssertEqual(reading.isFresh(at: now), sourceStatus == "connected")
            XCTAssertEqual(reading.windows.map(\.group), ["default", "reserve"])
            XCTAssertEqual(reading.visibleWindows.map(\.id), ["weekly"])
            XCTAssertEqual(reading.windows[1].remainingPercent, 100)
            XCTAssertEqual(reading.lastSuccessAt, now)
            XCTAssertEqual(reading.credits, 56_000)
            XCTAssertEqual(reading.resetCardsAvailable, 3)
        }
    }

    func testSnapshotMultipleAccountsRequireExactUnambiguousSelector() throws {
        let account: [String: Any] = ["id": "one", "status": "connected", "windows": [["remainingPercent": 40]]]
        let another: [String: Any] = ["id": "two", "status": "needs_auth"]
        let data = try json(["schemaVersion": 1, "collectedAt": now.timeIntervalSince1970, "accounts": [account, another]])
        XCTAssertThrowsError(try ProviderClient.parseSnapshot(data, at: now)) { XCTAssertEqual($0 as? ProviderError, .invalidConfiguration) }
        XCTAssertThrowsError(try ProviderClient.parseSnapshot(data, sourceAccountID: "missing", at: now))
        XCTAssertEqual(try ProviderClient.parseSnapshot(data, sourceAccountID: "one", at: now).status, .connected)
        XCTAssertEqual(try ProviderClient.parseSnapshot(data, sourceAccountID: "two", at: now).status, .needsAuth)
        let duplicate = try json(["accounts": [account, account]])
        XCTAssertThrowsError(try ProviderClient.parseSnapshot(duplicate, sourceAccountID: "one", at: now))
    }

    func testSnapshotExplicitIdentityDeduplicatesAcrossSourceLocations() throws {
        let data = try json(["id": "alias", "status": "connected", "lastSuccessAt": now.timeIntervalSince1970, "identity": ["provider": "codex", "accountID": "account-123"], "windows": [["remainingPercent": 40]]])
        let first = try ProviderClient.parseSnapshot(data, source: "/first.json", at: now)
        let second = try ProviderClient.parseSnapshot(data, source: "https://example.test/quota", at: now)
        XCTAssertEqual(first.identityKey, second.identityKey)
        XCTAssertEqual(first.identityKey, ProviderClient.identity(provider: "codex", accountID: "account-123"))
        XCTAssertFalse(first.identityKey!.contains("account-123"))
    }

    func testSnapshotRejectsInvalidAbsoluteAllowanceAndDuplicateWindows() throws {
        for windows: [[String: Any]] in [
            [["remaining": 11, "limit": 10]],
            [["remaining": -1]],
            [["remainingPercent": false]],
            [["remainingPercent": 20, "unit": "invented"]],
            [["id": "same", "remainingPercent": 20], ["id": "same", "remainingPercent": 30]]
        ] {
            let data = try json(["status": "connected", "windows": windows])
            XCTAssertThrowsError(try ProviderClient.parseSnapshot(data, at: now)) { XCTAssertEqual($0 as? ProviderError, .invalidData) }
        }
    }

    func testSnapshotSupportsUnlimitedAndNumericCreditBalance() throws {
        let data = try json(["status": "connected", "lastSuccessAt": now.timeIntervalSince1970, "windows": [["id": "unlimited", "unlimited": true]], "credits": ["balance": "120.25"], "resetCredits": ["available": 0]])
        let reading = try ProviderClient.parseSnapshot(data, at: now)
        XCTAssertTrue(reading.windows[0].unlimited)
        XCTAssertEqual(reading.credits, 120.25)
        XCTAssertEqual(reading.resetCardsAvailable, 0)
    }

    func testURLsRejectCredentialsInQueryUserinfoAndFragments() throws {
        for location in ["http://example.test/quota", "file:///tmp/quota.json", "https://user:password@example.test/", "https://example.test/?token=private", "https://example.test/#secret"] {
            XCTAssertThrowsError(try ProviderClient.validatedURL(location)) { XCTAssertEqual($0 as? ProviderError, .invalidConfiguration) }
        }
        XCTAssertEqual(try ProviderClient.validatedURL("https://example.test/v1/quota").host, "example.test")
    }

    func testHTTPAuthErrorsAreSanitized() async throws {
        let config = try fixtureAccount()
        defer { try? FileManager.default.removeItem(atPath: config.location) }
        for code in [401, 403] {
            QuotaURLProtocol.handler = { request, client, proto in
                client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data("private response must not surface".utf8))
                client.urlProtocolDidFinishLoading(proto)
            }
            do { _ = try await mockClient().fetch(config); XCTFail("Expected an authentication error") }
            catch { XCTAssertEqual(error as? ProviderError, .needsAuth) }
        }
    }

    func testHTTPRejectsOversizedDeclaredAndStreamedBodies() async throws {
        let config = try fixtureAccount()
        defer { try? FileManager.default.removeItem(atPath: config.location) }
        for declared in [true, false] {
            QuotaURLProtocol.handler = { request, client, proto in
                let headers = declared ? ["Content-Length": "\(ProviderClient.maximumBytes + 1)"] : [:]
                client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                if !declared { client.urlProtocol(proto, didLoad: Data(repeating: 32, count: ProviderClient.maximumBytes + 1)) }
                client.urlProtocolDidFinishLoading(proto)
            }
            do { _ = try await mockClient().fetch(config); XCTFail("Expected size rejection") }
            catch { XCTAssertEqual(error as? ProviderError, .invalidData) }
        }
    }

    func testCodexFetchUsesFixedEndpointAndRejectsAccountMismatch() async throws {
        let config = try fixtureAccount()
        defer { try? FileManager.default.removeItem(atPath: config.location) }
        QuotaURLProtocol.handler = { request, client, proto in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "fixture-account")
            let body = Data(#"{"account_id":"different-account","rate_limit":{"primary_window":{"used_percent":10}}}"#.utf8)
            client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(proto, didLoad: body)
            client.urlProtocolDidFinishLoading(proto)
        }
        do { _ = try await mockClient().fetch(config); XCTFail("Expected account mismatch rejection") }
        catch { XCTAssertEqual(error as? ProviderError, .invalidData) }
    }

    func testMalformedResponseIsNotDisplayedAsEmptyQuota() async throws {
        let config = try fixtureAccount()
        defer { try? FileManager.default.removeItem(atPath: config.location) }
        QuotaURLProtocol.handler = { request, client, proto in
            client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(proto, didLoad: Data("not json".utf8))
            client.urlProtocolDidFinishLoading(proto)
        }
        do { _ = try await mockClient().fetch(config); XCTFail("Expected invalid data") }
        catch { XCTAssertEqual(error as? ProviderError, .invalidData) }
    }

    func testCredentialsNeverEnterReturnedReading() async throws {
        let config = try fixtureAccount()
        defer { try? FileManager.default.removeItem(atPath: config.location) }
        QuotaURLProtocol.handler = { request, client, proto in
            let body = Data(#"{"account_id":"fixture-account","rate_limit":{"primary_window":{"used_percent":10}}}"#.utf8)
            client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(proto, didLoad: body)
            client.urlProtocolDidFinishLoading(proto)
        }
        let reading = try await mockClient().fetch(config)
        let encoded = String(data: try JSONEncoder().encode(reading), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("fixture-secret"))
        XCTAssertFalse(encoded.contains("fixture-account"))
        XCTAssertEqual(reading.identityKey, ProviderClient.identity(provider: "codex", accountID: "fixture-account"))
    }

    func testHTTPRedirectCannotForwardProviderCredentials() async throws {
        let config = try fixtureAccount()
        defer { try? FileManager.default.removeItem(atPath: config.location) }
        var requestCount = 0
        QuotaURLProtocol.handler = { request, client, proto in
            requestCount += 1
            let destination = URL(string: "https://different.example.test/collect")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination.absoluteString])!
            client.urlProtocol(proto, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client.urlProtocolDidFinishLoading(proto)
        }
        do { _ = try await mockClient().fetch(config); XCTFail("Expected redirect rejection") }
        catch { XCTAssertEqual(error as? ProviderError, .invalidConfiguration) }
        XCTAssertEqual(requestCount, 1)
    }

    func testGrokACPOnlyInitializesAndReadsBillingAndRejectsServerExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-acp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-cli")
        let trace = directory.appendingPathComponent("trace.jsonl")
        // This local fake CLI never reads a real credential or reaches a network.
        let script = """
        #!/bin/sh
        IFS= read -r first
        printf '%s\\n' "$first" > '\(trace.path)'
        printf '%s\\n' '{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{}}'
        IFS= read -r rejection
        printf '%s\\n' "$rejection" >> '\(trace.path)'
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r second
        printf '%s\\n' "$second" >> '\(trace.path)'
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":20}}}'
        while IFS= read -r ignored; do :; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = AccountConfig(provider: .grok, name: "Fixture", method: .grokCLI, location: executable.path)
        let reading = try await mockClient().fetch(config)
        XCTAssertEqual(reading.windows.first?.remainingPercent, 80)
        let messages = try String(contentsOf: trace).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["method"] as? String, "initialize")
        XCTAssertEqual(messages[1]["id"] as? Int, 99)
        XCTAssertEqual((messages[1]["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(messages[2]["method"] as? String, "_x.ai/billing")
        XCTAssertEqual((messages[2]["params"] as? [String: Any])?["action"] as? String, "get")
        XCTAssertEqual(reading.identityKey, ProviderClient.identity(provider: "grok", accountID: "local-default-login"))
    }

    func testSSHArgumentsUseStrictBatchTransportAndOnlyQuotedReadCommand() throws {
        let path = "/srv/private/it's $(not-a-command); quota.json"
        let args = try ProviderClient.buildSSHArguments(host: "quota-host", path: path)
        XCTAssertEqual(Array(args.dropLast()), ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no", "-o", "RequestTTY=no", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "--", "quota-host"])
        XCTAssertEqual(args.last, "cat -- '/srv/private/it'\\''s $(not-a-command); quota.json'")
        let sudoArgs = try ProviderClient.buildSSHArguments(host: "quota-host", path: "/srv/quota.json", useSudo: true)
        XCTAssertEqual(sudoArgs.last, "sudo -n cat -- '/srv/quota.json'")
    }

    func testSSHRejectsHostOptionsUsernamesAndControlCharacters() throws {
        for host in ["", "-oProxyCommand=anything", "user@host", "host;anything", "host\nnext", "host\n", String(repeating: "a", count: 102)] {
            XCTAssertThrowsError(try ProviderClient.buildSSHArguments(host: host, path: "/srv/quota.json")) { XCTAssertEqual($0 as? ProviderError, .invalidConfiguration) }
        }
        for path in ["quota.json", "~/quota.json", "/srv/quota\n.json", "/srv/\u{0}quota", "/" + String(repeating: "a", count: 4096)] {
            XCTAssertThrowsError(try ProviderClient.buildSSHArguments(host: "quota-host", path: path)) { XCTAssertEqual($0 as? ProviderError, .invalidConfiguration) }
        }
    }

    func testSharedSnapshotSourceCoalescesAccountsAndBrieflyCachesDocument() async throws {
        let cache = SnapshotSourceCache()
        let counter = SnapshotLoaderCounter()
        let loader: @Sendable () async throws -> Data = {
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return Data("fixture-source-document".utf8)
        }
        async let first = cache.read(key: "same-source", loader: loader)
        async let second = cache.read(key: "same-source", loader: loader)
        let results = try await [first, second]
        XCTAssertEqual(results[0], results[1])
        _ = try await cache.read(key: "same-source", loader: loader)
        let count = await counter.value
        XCTAssertEqual(count, 1)
        _ = try await cache.read(key: "other-source", loader: loader)
        let updatedCount = await counter.value
        XCTAssertEqual(updatedCount, 2)
    }

    func testFailedSnapshotRowsDoNotInventSuccessfulReadFromCollectionTime() throws {
        for status in ["needs_auth", "not_configured", "unavailable", "unsupported", "stale"] {
            let data = try json(["collectedAt": now.timeIntervalSince1970, "accounts": [["id": "account", "status": status, "windows": [], "detail": "untrusted upstream detail"]]])
            let reading = try ProviderClient.parseSnapshot(data, at: now)
            XCTAssertNil(reading.lastSuccessAt, "No successful quota observation for \(status)")
            XCTAssertEqual(reading.checkedAt, now)
            XCTAssertFalse(reading.detail.isEmpty)
            XCTAssertFalse(reading.detail.contains("untrusted upstream"))
            if status == "needs_auth" { XCTAssertEqual(reading.detail, ProviderError.needsAuth.message) }
        }
        let historical = now.addingTimeInterval(-600)
        let data = try json(["collectedAt": now.timeIntervalSince1970, "accounts": [["id": "account", "status": "needs_auth", "lastSuccessAt": historical.timeIntervalSince1970]]])
        XCTAssertEqual(try ProviderClient.parseSnapshot(data, at: now).lastSuccessAt, historical)
        let pooled = try json(["status": "unavailable", "reason": "pooled"])
        XCTAssertEqual(try ProviderClient.parseSnapshot(pooled, at: now).detail, "此账号使用共享额度，来源未提供独立余量。")
    }

    func testSharedSnapshotSourceExpiresAndCachesFailuresWithoutRerunningSSH() async throws {
        let cache = SnapshotSourceCache(ttl: 0.01)
        let counter = SnapshotLoaderCounter()
        let loader: @Sendable () async throws -> Data = { await counter.increment(); throw ProviderError.unavailable }
        for _ in 0..<2 {
            do { _ = try await cache.read(key: "failing-source", loader: loader); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? ProviderError, .unavailable) }
        }
        let initialCount = await counter.value
        XCTAssertEqual(initialCount, 1)
        try await Task.sleep(nanoseconds: 30_000_000)
        do { _ = try await cache.read(key: "failing-source", loader: loader); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? ProviderError, .unavailable) }
        let finalCount = await counter.value
        XCTAssertEqual(finalCount, 2)
    }

    func testSnapshotProcessCapturesCompleteOutputAndRejectsFailureOversizeAndTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-process-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        func executable(_ name: String, body: String) throws -> String {
            let file = directory.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file.path
        }
        let success = try executable("success", body: "printf '%s' '{\"status\":\"connected\"}'")
        let result = try await SnapshotProcessReader().read(executable: success, arguments: [])
        XCTAssertEqual(String(data: result, encoding: .utf8), #"{"status":"connected"}"#)
        let failure = try executable("failure", body: "printf '%s' 'must not surface'; exit 7")
        do { _ = try await SnapshotProcessReader().read(executable: failure, arguments: []); XCTFail("Expected exit failure") }
        catch { XCTAssertEqual(error as? ProviderError, .unavailable) }
        let oversized = try executable("oversized", body: "printf '%s' '123456789'")
        do { _ = try await SnapshotProcessReader().read(executable: oversized, arguments: [], maximumBytes: 8); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(error as? ProviderError, .invalidData) }
        let timeout = try executable("timeout", body: "exec /bin/sleep 30")
        let started = Date()
        do { _ = try await SnapshotProcessReader().read(executable: timeout, arguments: [], timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ProviderError, .unavailable) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    private func snapshot(observed: Date) throws -> Data {
        try json(["schemaVersion": 1, "collectedAt": observed.timeIntervalSince1970, "accounts": [["id": "one", "status": "connected", "checkedAt": observed.timeIntervalSince1970, "lastSuccessAt": observed.timeIntervalSince1970, "windows": [["id": "weekly", "remainingPercent": 40]]]]])
    }
    private func fixtureAccount() throws -> AccountConfig {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-fixture-\(UUID().uuidString).json")
        try Data(#"{"tokens":{"access_token":"fixture-secret","account_id":"fixture-account"}}"#.utf8).write(to: url)
        return AccountConfig(provider: .codex, name: "Fixture", method: .localFile, location: url.path)
    }
    private func mockClient() -> ProviderClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaURLProtocol.self]
        return ProviderClient(sessionConfiguration: config, now: { self.now })
    }
}

private final class QuotaURLProtocol: URLProtocol {
    static var handler: ((URLRequest, URLProtocolClient, URLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let client, let handler = Self.handler else { return }
        handler(request, client, self)
    }
    override func stopLoading() {}
}

private actor SnapshotLoaderCounter {
    var value = 0
    func increment() { value += 1 }
}
