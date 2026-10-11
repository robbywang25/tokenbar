import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class WidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_676_800)

    func testLegacyMetricWithoutResetDateDecodesAndOptionalDateRoundTrips() throws {
        let old = validSnapshot()
        let encoded = try JSONEncoder().encode(old)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)!.contains("resetsAt"))
        let decoded = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: encoded)
        XCTAssertNil(decoded.accounts[0].metrics[0].resetsAt)
        XCTAssertNoThrow(try decoded.validate())
        var updated = old
        updated.accounts[0].metrics[0].resetsAt = now.addingTimeInterval(3600)
        let restored = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.accounts[0].metrics[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertNoThrow(try restored.validate())
    }

    @MainActor
    func testProjectionCarriesEachWindowResetWithoutStartOrBorrowingDateForCredits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let config = account("Fixture")
        let shortReset = now.addingTimeInterval(3600), weeklyReset = now.addingTimeInterval(259_200)
        store.accounts = [config]
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: [QuotaWindow(id: "short", label: "5 小时", remainingPercent: 60, resetsAt: shortReset),
                      QuotaWindow(id: "weekly", label: "每周", remainingPercent: 40, resetsAt: weeklyReset),
                      QuotaWindow(id: "unknown", label: "其他", remainingPercent: 30)])
        var snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.resetsAt), [shortReset, weeklyReset, nil])
        XCTAssertNil(snapshot.accounts[0].urgencyWindow, "Missing cycle start does not prevent displaying an explicit reset date.")
        store.readings[config.id]?.credits = 125.5
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.id), ["window-0", "window-1", "credits"])
        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.resetsAt), [shortReset, weeklyReset, nil])
    }

    @MainActor
    func testHistoricalResetDateIsPreservedButUnknownObservationCannotExposeOne() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let config = account("Fixture")
        let expiredReset = now.addingTimeInterval(-60)
        store.accounts = [config]
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now.addingTimeInterval(-600),
            windows: [QuotaWindow(id: "weekly", label: "每周", remainingPercent: 40, resetsAt: expiredReset)], credits: 10)
        var snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        XCTAssertEqual(snapshot.accounts[0].status, .stale)
        XCTAssertEqual(snapshot.accounts[0].metrics.first?.resetsAt, expiredReset)
        XCTAssertNil(snapshot.accounts[0].metrics.first(where: { $0.id == "credits" })?.resetsAt)
        XCTAssertFalse(snapshot.accounts[0].isFresh(at: now))
        store.readings[config.id]?.status = .needsAuth
        store.readings[config.id]?.lastSuccessAt = nil
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertTrue(snapshot.accounts[0].metrics.isEmpty)
        XCTAssertNil(snapshot.accounts[0].observedAt)
    }

    @MainActor
    func testInvalidOptionalResetDateIsRejectedOnReadAndDroppedDuringProjection() throws {
        var invalid = validSnapshot()
        invalid.accounts[0].metrics[0].resetsAt = .distantFuture
        XCTAssertThrowsError(try invalid.validate())
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let config = account("Fixture")
        store.accounts = [config]
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: [QuotaWindow(id: "weekly", label: "每周", remainingPercent: 40, resetsAt: .distantFuture)])
        let snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertNil(snapshot.accounts[0].metrics[0].resetsAt)
        XCTAssertNoThrow(try snapshot.validate())
    }

    @MainActor
    func testProjectionIncludesOnlyDisplayFieldsAndNeverPrivateInputs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = AccountConfig(provider: .snapshot, name: "PRIVATE_PERSON_NAME", method: .snapshotSSH,
                                    location: "/PRIVATE_PATH/snapshot.json", sourceAccountID: "PRIVATE_SOURCE_ID",
                                    sshHost: "PRIVATE_SSH_HOST", sshUseSudo: true, serviceLabel: "Codex")
        let store = fixture.store()
        store.accounts = [account]
        store.readings[account.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: [QuotaWindow(id: "PRIVATE_WINDOW_ID", label: "每周", remainingPercent: 42, resetsAt: now.addingTimeInterval(3600)),
                      QuotaWindow(id: "reserve", label: "PRIVATE_RESERVE_LABEL", remainingPercent: 99, group: "reserve")],
            credits: 125.5, name: "PRIVATE_PROFILE_NAME", email: "fixture@example.test", detail: "PRIVATE_DETAIL_Bearer_SECRET",
            identityKey: "PRIVATE_IDENTITY_HASH", planName: "ChatGPT Pro 500", planMultiplier: 25)
        let snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["PRIVATE_", "sshHost", "sourceAccountID", "location", "credentials", "identityKey", "detail", "paymentHistory", "monthlyPrice"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let row = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(row.email, "fixture@example.test")
        XCTAssertEqual(row.provider, "Codex")
        XCTAssertEqual(row.plan, "Pro 25x")
        XCTAssertEqual(row.metrics.map(\.label), ["每周", "剩余点数"])
        XCTAssertEqual(row.metrics.map(\.value), ["42%", "125.5 点"])
        XCTAssertEqual(row.freshUntil, now.addingTimeInterval(120))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
    }

    @MainActor
    func testProjectionPrioritizesSelectedAccountsAndMetricsWhileExcludingDisabledAndReserve() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let first = account("First"), second = account("Second"), third = account("Third")
        var disabled = account("Disabled"); disabled.enabled = false
        store.accounts = [first, second, third, disabled]
        for config in store.accounts {
            store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [
                QuotaWindow(id: "one", label: "第一额度", remainingPercent: 10),
                QuotaWindow(id: "two", label: "第二额度", remainingPercent: 20),
                QuotaWindow(id: "three", label: "第三额度", remainingPercent: 30),
                QuotaWindow(id: "reserve", label: "Reserve", remainingPercent: 100, group: "reserve")
            ], credits: 80)
        }
        store.setMenuQuota(accountID: first.id, windowID: "one", enabled: false)
        store.setMenuQuota(accountID: third.id, windowID: "three", enabled: true)
        let credits = try XCTUnwrap(store.availableMenuMetrics.first(where: { $0.accountID == third.id && $0.kind == .credits }))
        store.setMenuMetric(credits, enabled: true)
        let snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertEqual(snapshot.accounts.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.label), ["第三额度", "剩余点数", "第一额度"])
        XCTAssertEqual(snapshot.accounts[0].metrics.count, 3)
        XCTAssertTrue(snapshot.accounts.flatMap(\.metrics).allSatisfy { !$0.label.contains("Reserve") })
        store.loadDemo()
        XCTAssertNil(store.widgetSnapshot(at: now))
    }

    @MainActor
    func testFreshnessExpiresAtSourceOrVisibleResetBoundaryWithoutFresheningHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let config = account("Fixture")
        store.accounts = [config]
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: [QuotaWindow(id: "weekly", label: "每周", remainingPercent: 42, resetsAt: now.addingTimeInterval(80)),
                      QuotaWindow(id: "reserve", label: "每周", remainingPercent: 100, resetsAt: now.addingTimeInterval(-10), group: "reserve")],
            sourceCollectedAt: now.addingTimeInterval(-60), sourceCollectedAtPresent: true)
        var snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        var row = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(row.freshUntil, now.addingTimeInterval(60))
        XCTAssertTrue(row.isFresh(at: now.addingTimeInterval(59)))
        XCTAssertFalse(row.isFresh(at: now.addingTimeInterval(60)))
        XCTAssertEqual(row.displayStatus(at: now.addingTimeInterval(60)), .stale)
        XCTAssertEqual(row.metrics.first?.value, "42%")
        store.readings[config.id]?.sourceCollectedAt = now
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertEqual(snapshot.accounts[0].freshUntil, now.addingTimeInterval(80))
        store.readings[config.id]?.sourceCollectedAt = nil
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        row = snapshot.accounts[0]
        XCTAssertEqual(row.status, .stale)
        XCTAssertNil(row.freshUntil)
        XCTAssertEqual(row.observedAt, now)
        XCTAssertEqual(row.metrics.first?.remainingPercent, 42)
        XCTAssertEqual(snapshot.generatedAt, now)
    }

    @MainActor
    func testUnknownAndAuthFailureCannotInventZeroWhileVerifiedHistoryRemainsExplicit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let config = account("Fixture")
        store.accounts = [config]
        var snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertEqual(snapshot.accounts[0].status, .notConfigured)
        XCTAssertTrue(snapshot.accounts[0].metrics.isEmpty)
        store.readings[config.id] = AccountReading(status: .needsAuth, checkedAt: now, lastSuccessAt: nil,
            windows: [QuotaWindow(id: "zero", label: "额度", remainingPercent: 0)], credits: 0)
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertEqual(snapshot.accounts[0].status, .needsAuth)
        XCTAssertNil(snapshot.accounts[0].observedAt)
        XCTAssertTrue(snapshot.accounts[0].metrics.isEmpty)
        store.readings[config.id]?.lastSuccessAt = now.addingTimeInterval(-600)
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertEqual(snapshot.accounts[0].status, .needsAuth)
        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.value), ["0%", "0 点"])
        XCTAssertFalse(snapshot.accounts[0].isFresh(at: now))
        XCTAssertNil(snapshot.accounts[0].freshUntil)
        store.readings[config.id]?.lastSuccessAt = now.addingTimeInterval(61)
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertTrue(snapshot.accounts[0].metrics.isEmpty)
        XCTAssertNil(snapshot.accounts[0].observedAt)
    }

    @MainActor
    func testUnicodeProviderAndUnsafeOptionalPlanDoNotBreakWholeSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        var config = account("Never Display Name")
        config.serviceLabel = "自建助手"
        store.accounts = [config]
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
            windows: [QuotaWindow(id: "window", label: "/private/source", remainingPercent: 75)], email: "invalid-email",
            planName: "Plan /private/path")
        let snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        XCTAssertEqual(snapshot.accounts[0].provider, "自建助手")
        XCTAssertNil(snapshot.accounts[0].plan)
        XCTAssertNil(snapshot.accounts[0].email)
        XCTAssertEqual(snapshot.accounts[0].metrics[0].label, "额度")
    }

    func testStoreRoundTripsPrivateAtomicFileAndEmptySnapshotReplacesOldData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = validSnapshot()
        try TokenBarWidgetSnapshotStore.write(snapshot, directory: fixture.state)
        XCTAssertEqual(try TokenBarWidgetSnapshotStore.read(directory: fixture.state), snapshot)
        let file = fixture.state.appendingPathComponent(TokenBarWidgetConstants.snapshotFilename)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.state.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path), [TokenBarWidgetConstants.snapshotFilename])
        let empty = TokenBarWidgetSnapshot(generatedAt: now, accounts: [])
        try TokenBarWidgetSnapshotStore.write(empty, directory: fixture.state)
        XCTAssertEqual(try TokenBarWidgetSnapshotStore.read(directory: fixture.state), empty)
    }

    func testStoreRejectsCorruptOversizedUnsupportedAndSymlinkFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.read(directory: fixture.state))
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: false)
        let file = fixture.state.appendingPathComponent(TokenBarWidgetConstants.snapshotFilename)
        try Data("invalid-json".utf8).write(to: file)
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.read(directory: fixture.state)) { XCTAssertEqual($0 as? TokenBarWidgetSnapshotError, .invalidSnapshot) }
        try Data(repeating: 32, count: TokenBarWidgetConstants.maximumBytes + 1).write(to: file)
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.read(directory: fixture.state)) { XCTAssertEqual($0 as? TokenBarWidgetSnapshotError, .oversizedSnapshot) }
        var unsupported = validSnapshot(); unsupported.schemaVersion = 2
        try JSONEncoder().encode(unsupported).write(to: file)
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.read(directory: fixture.state)) { XCTAssertEqual($0 as? TokenBarWidgetSnapshotError, .invalidSnapshot) }
        let other = fixture.root.appendingPathComponent("other.json")
        try JSONEncoder().encode(validSnapshot()).write(to: other)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.read(directory: fixture.state)) { XCTAssertEqual($0 as? TokenBarWidgetSnapshotError, .unavailableFile) }
    }

    func testStoreValidationRejectsUnsafeOrUnboundedDisplayFieldsBeforeWriting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var invalid = validSnapshot()
        invalid.accounts[0].metrics[0].remainingPercent = 101
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.write(invalid, directory: fixture.state))
        invalid = validSnapshot(); invalid.accounts[0].provider = "/private/path"
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.write(invalid, directory: fixture.state))
        invalid = validSnapshot(); invalid.accounts[0].metrics[0].value = "Bearer private"
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.write(invalid, directory: fixture.state))
        invalid = validSnapshot(); invalid.accounts[0].freshUntil = now.addingTimeInterval(121)
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.write(invalid, directory: fixture.state))
        invalid = validSnapshot(); invalid.accounts[0].observedAt = nil
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.write(invalid, directory: fixture.state))
        invalid = validSnapshot(); invalid.accounts[0].metrics = (0..<4).map { TokenBarWidgetMetric(id: "window-\($0)", label: "额度", value: "42%", remainingPercent: 42) }
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.write(invalid, directory: fixture.state))
        invalid = validSnapshot(); invalid.accounts = (0..<31).map { _ in var row = invalid.accounts[0]; row.id = UUID(); return row }
        XCTAssertThrowsError(try TokenBarWidgetSnapshotStore.write(invalid, directory: fixture.state))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
    }

    private func validSnapshot() -> TokenBarWidgetSnapshot {
        TokenBarWidgetSnapshot(generatedAt: now, accounts: [TokenBarWidgetAccount(id: UUID(), email: "fixture@example.test", provider: "Codex", plan: "Pro 25x",
            status: .connected, observedAt: now, freshUntil: now.addingTimeInterval(120),
            metrics: [TokenBarWidgetMetric(id: "weekly", label: "每周", value: "42%", remainingPercent: 42)])])
    }

    private func account(_ name: String) -> AccountConfig {
        AccountConfig(provider: .snapshot, name: name, method: .snapshotFile, location: "/fixture/unused.json", serviceLabel: "Codex")
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        var state: URL { root.appendingPathComponent("state") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-WidgetSnapshotTests-\(UUID().uuidString)")
            suite = "TokenBar.WidgetSnapshotTests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        @MainActor func store() -> AppStore {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WidgetNoNetworkProtocol.self]
            let client = ProviderClient(sessionConfiguration: configuration, credentialReader: { _, _ in
                XCTFail("Projection must not read credentials"); throw ProviderError.needsAuth
            }, sshReader: { _ in
                XCTFail("Projection must not start SSH"); throw ProviderError.unavailable
            })
            return AppStore(directory: state, client: client, startTimers: false, defaults: defaults)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class WidgetNoNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Projection must not perform network requests")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
