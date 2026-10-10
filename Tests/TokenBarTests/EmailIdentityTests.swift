import XCTest
@testable import TokenBar

final class EmailIdentityTests: XCTestCase {
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
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertTrue(store.availableMenuMetrics.allSatisfy { $0.accountName == "person@example.com" })

        let restored = environment.store()
        XCTAssertEqual(restored.accountIdentityLabel(environment.account), "person@example.com")
        XCTAssertEqual(restored.menuTitle, "—")
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
        func write(email: String?, status: String = "connected", identity: String = "stable-account", alert: Bool = false) throws {
            let now = Date()
            let formatter = ISO8601DateFormatter()
            let profile: [String: Any] = ["name": "Another Hidden Personal Name", "email": email as Any? ?? NSNull()]
            let account: [String: Any] = [
                "id": "example", "status": status, "checkedAt": formatter.string(from: now),
                "lastSuccessAt": status == "connected" ? formatter.string(from: now) : NSNull(),
                "identity": ["provider": "example", "accountID": identity], "profile": profile,
                "windows": status == "connected" ? [["id": "weekly", "label": "每周", "remainingPercent": 94,
                    "startsAt": formatter.string(from: now.addingTimeInterval(-600_000)),
                    "resetsAt": formatter.string(from: now.addingTimeInterval(alert ? 4_800 : 172_800))]] : []
            ]
            try JSONSerialization.data(withJSONObject: account).write(to: snapshot, options: .atomic)
        }
    }
}
