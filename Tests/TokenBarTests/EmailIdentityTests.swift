import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class EmailIdentityTests: XCTestCase {
    @MainActor func testLegacyMenuObservationCannotOutliveAnExplicitIdentityEpoch() async throws {
        let environment = try Fixture()
        defer { environment.clean() }
        try environment.write(email: "previous@example.test")
        let store = environment.store()
        defer { store.stop() }
        try await store.connect(environment.account)
        XCTAssertTrue(store.menuTitle.contains("94"))

        try environment.write(email: nil, status: "needs_auth", epoch: "22222222-2222-4222-8222-222222222222")
        await store.refresh()
        let widget = try XCTUnwrap(store.widgetSnapshot()).accounts[0]
        XCTAssertEqual(widget.status, .needsAuth)
        XCTAssertNil(widget.email)
        XCTAssertTrue(widget.metrics.isEmpty)
        XCTAssertFalse(store.menuTitle.contains("94"), "An unbound legacy balance cannot identify the new epoch.")
        let menuCache = environment.state.appendingPathComponent("menu-readings.json")
        XCTAssertFalse(String(decoding: try Data(contentsOf: menuCache), as: UTF8.self).contains("previous@example.test"))

        // A later missing epoch and a restart must not revive the discarded observation.
        try environment.write(email: nil, status: "needs_auth")
        await store.refresh()
        XCTAssertFalse(store.menuTitle.contains("94"))
        let restarted = environment.store()
        defer { restarted.stop() }
        XCTAssertFalse(restarted.menuTitle.contains("94"))
        XCTAssertTrue(try XCTUnwrap(restarted.widgetSnapshot()).accounts[0].metrics.isEmpty)
    }

    func testEmailValidationNeverAcceptsDisplayNamesOrControls() {
        XCTAssertEqual(AccountEmail.validated(" person@example.com "), "person@example.com")
        for value in ["Personal Name", "Person <person@example.com>", "person@example.com\n", "person\n@example.com", "not-an-email", "", "a@localhost"] {
            XCTAssertNil(AccountEmail.validated(value))
        }
    }

    @MainActor func testEmailRemainsIdentifiableDuringFailureWithoutMakingQuotaFresh() async throws {
        let environment = try Fixture()
        defer { environment.clean() }
        try environment.write(email: "person@example.com")
        let store = environment.store()
        try await store.connect(environment.account)
        let id = environment.account.id
        XCTAssertEqual(store.accountIdentityLabel(environment.account), "person@example.com")
        XCTAssertFalse(store.menuTooltip.contains("Legacy Personal Name"))
        let permissions = try FileManager.default.attributesOfItem(atPath: environment.state.appendingPathComponent("account-emails.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        try environment.write(email: nil, status: "needs_auth")
        await store.refresh()
        XCTAssertEqual(store.readings[id]?.status, .needsAuth)
        XCTAssertEqual(store.accountIdentityLabel(environment.account), "person@example.com")
        XCTAssertTrue(store.accountIdentityHelp(environment.account).contains("上次识别"))
        XCTAssertEqual(store.menuTitle, "~94%")
        XCTAssertTrue(store.availableMenuMetrics.allSatisfy { $0.accountName == "person@example.com" })

        let restored = environment.store()
        XCTAssertEqual(restored.accountIdentityLabel(environment.account), "person@example.com")
        XCTAssertEqual(restored.menuTitle, "~94%")
        restored.remove(environment.account)
        XCTAssertNil(restored.accountEmail(environment.account))
    }

    @MainActor func testIdentityChangeAndExplicitMissingEmailCannotReusePreviousIdentity() async throws {
        let environment = try Fixture()
        defer { environment.clean() }
        try environment.write(email: "first@example.com")
        let store = environment.store()
        try await store.connect(environment.account)
        try environment.write(email: nil, status: "needs_auth", identity: "different-account")
        await store.refresh()
        XCTAssertEqual(store.accountIdentityLabel(environment.account), "邮箱待确认")
        XCTAssertFalse(store.menuTooltip.contains("first@example.com"))

        try environment.write(email: "second@example.com", identity: "different-account")
        await store.refresh()
        XCTAssertEqual(store.accountIdentityLabel(environment.account), "second@example.com")
        try environment.write(email: nil, identity: "different-account")
        await store.refresh()
        XCTAssertNil(store.accountEmail(environment.account))
        XCTAssertEqual(store.accountIdentityLabel(environment.account), "邮箱待确认")
    }

    @MainActor func testSourceChangeDoesNotAttachSavedEmailToNewSource() async throws {
        let environment = try Fixture()
        defer { environment.clean() }
        try environment.write(email: "bound@example.com")
        let store = environment.store()
        try await store.connect(environment.account)
        var replacement = environment.account
        replacement.location = environment.root.appendingPathComponent("different-source.json").path
        try JSONEncoder().encode([replacement]).write(to: environment.state.appendingPathComponent("accounts.json"))
        let restored = environment.store()
        XCTAssertEqual(restored.accountIdentityLabel(replacement), "邮箱待确认")
        XCTAssertNil(restored.readings[replacement.id])
        XCTAssertTrue(restored.availableMenuMetrics.allSatisfy { !$0.accountName.contains("bound@example.com") && !$0.accountName.contains("Legacy") })
        let restartedAgain = environment.store()
        XCTAssertEqual(restartedAgain.accountIdentityLabel(replacement), "邮箱待确认")
        XCTAssertNil(restartedAgain.readings[replacement.id])
    }

    @MainActor func testNewEpochWithoutEmailCannotLabelNewHistoryWithPreviousAccount() async throws {
        for status in ["stale", "needs_auth", "unavailable"] {
            let environment = try Fixture()
            defer { environment.clean() }
            let firstEpoch = "11111111-1111-4111-8111-111111111111"
            let nextEpoch = "22222222-2222-4222-8222-222222222222"
            try environment.write(email: "previous@example.test", epoch: firstEpoch)
            let store = environment.store()
            defer { store.stop() }
            try await store.connect(environment.account)
            let originalIdentity = store.readings[environment.account.id]?.identityKey
            try environment.write(email: nil, status: status, epoch: nextEpoch)
            await store.refresh()
            XCTAssertEqual(store.readings[environment.account.id]?.identityKey, originalIdentity,
                           "A source slot may retain its key while its account epoch changes.")
            XCTAssertNil(store.accountEmail(environment.account))
            XCTAssertFalse(store.menuTooltip.contains("previous@example.test"))
            if let reading = store.readings[environment.account.id], let window = reading.windows.first {
                let row = try XCTUnwrap(QuotaAnalysisRow(account: environment.account, reading: reading, window: window,
                    accountLabel: store.accountIdentityLabel(environment.account), product: "codex"))
                XCTAssertFalse(QuotaRecapCSV.make(rows: [row], range: .hour, now: Date()).contains("previous@example.test"))
            }
            // Clearing the mismatched binding must survive a later response
            // without an epoch and a restart, rather than just hiding the label.
            try environment.write(email: nil, status: "needs_auth")
            await store.refresh()
            XCTAssertNil(store.accountEmail(environment.account))
            let restarted = environment.store()
            defer { restarted.stop() }
            XCTAssertNil(restarted.accountEmail(environment.account))
        }
    }

    @MainActor func testSameEpochKeepsRememberedEmailDuringAuthenticationFailure() async throws {
        let environment = try Fixture()
        defer { environment.clean() }
        let epoch = "11111111-1111-4111-8111-111111111111"
        try environment.write(email: "same@example.test", epoch: epoch)
        let store = environment.store()
        defer { store.stop() }
        try await store.connect(environment.account)
        try environment.write(email: nil, status: "needs_auth", epoch: epoch)
        await store.refresh()
        XCTAssertEqual(store.accountEmail(environment.account), "same@example.test")
        let restarted = environment.store()
        defer { restarted.stop() }
        XCTAssertEqual(restarted.accountEmail(environment.account), "same@example.test")
    }

    @MainActor func testLegacyEmailCacheLoadsButCannotIdentifyAnUnboundEpoch() async throws {
        let environment = try Fixture()
        defer { environment.clean() }
        try environment.write(email: "legacy@example.test")
        let store = environment.store()
        defer { store.stop() }
        try await store.connect(environment.account)
        let cache = environment.state.appendingPathComponent("account-emails.json")
        XCTAssertFalse(String(decoding: try Data(contentsOf: cache), as: UTF8.self).contains("resetHistoryIdentity"))
        let restarted = environment.store()
        defer { restarted.stop() }
        XCTAssertEqual(restarted.accountEmail(environment.account), "legacy@example.test")
        try environment.write(email: nil, status: "stale", epoch: "22222222-2222-4222-8222-222222222222")
        await restarted.refresh()
        XCTAssertNil(restarted.accountEmail(environment.account))
        XCTAssertFalse(String(decoding: try Data(contentsOf: cache), as: UTF8.self).contains("legacy@example.test"))
    }

    @MainActor func testNotificationsAndMenusUseEmailWithoutChangingSelectionIDs() async throws {
        let environment = try Fixture()
        defer { environment.clean() }
        try environment.write(email: "very.long.account.address.for.accessibility@example.com", alert: true)
        let store = environment.store()
        try await store.connect(environment.account)
        let metric = try XCTUnwrap(store.availableMenuMetrics.first)
        XCTAssertEqual(metric.id, MenuQuotaMetric.selectionID(accountID: environment.account.id, windowID: "weekly"))
        XCTAssertEqual(metric.accountName, "very.long.account.address.for.accessibility@example.com")
        XCTAssertEqual(store.takeNextExpiryNotice()?.accountName, metric.accountName)
        XCTAssertFalse(store.menuTooltip.contains("Legacy"))
    }

    @MainActor private final class Fixture {
        let root: URL
        let state: URL
        let snapshot: URL
        let defaults: UserDefaults
        let suite: String
        let account: AccountConfig
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            state = root.appendingPathComponent("state")
            snapshot = root.appendingPathComponent("quota.json")
            suite = "TokenBar.EmailIdentityTests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "showsAgentPrefix.v1")
            account = AccountConfig(provider: .snapshot, name: "Legacy Personal Name", method: .snapshotFile, location: snapshot.path, sourceAccountID: "example", serviceLabel: "Codex")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func store() -> AppStore { AppStore(directory: state, startTimers: false, defaults: defaults) }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func write(email: String?, status: String = "connected", identity: String = "stable-account", alert: Bool = false, epoch: String? = nil) throws {
            let now = Date()
            let formatter = ISO8601DateFormatter()
            let profile: [String: Any] = ["name": "Another Hidden Personal Name", "email": email as Any? ?? NSNull()]
            let hasQuota = status == "connected" || status == "stale"
            var account: [String: Any] = [
                "id": "example", "status": status, "checkedAt": formatter.string(from: now),
                "lastSuccessAt": hasQuota ? formatter.string(from: now) : NSNull(),
                "identity": ["provider": "example", "accountID": identity], "profile": profile,
                "windows": hasQuota ? [["id": "weekly", "label": "每周", "remainingPercent": 94,
                    "startsAt": formatter.string(from: now.addingTimeInterval(-600_000)),
                    "resetsAt": formatter.string(from: now.addingTimeInterval(alert ? 4_800 : 172_800))]] : []
            ]
            if let epoch { account["resetHistoryIdentity"] = epoch }
            try JSONSerialization.data(withJSONObject: account).write(to: snapshot, options: .atomic)
        }
    }
}
