import Foundation
import XCTest
@testable import TokenBar

final class ResetCalendarHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_792_022_400)
    private func config(enabled: Bool = true) -> AccountConfig {
        AccountConfig(provider: .snapshot, name: "Fixture", method: .snapshotFile, location: "/fixture.json", enabled: enabled, serviceLabel: "Codex")
    }
    private func reading(_ reset: Date, at observed: Date, id: String = "weekly", email: String = "fixture@example.test") -> AccountReading {
        AccountReading(status: .connected, checkedAt: observed, lastSuccessAt: observed,
                       windows: [QuotaWindow(id: id, label: "每周", remainingPercent: 73, resetsAt: reset)], email: email, identityKey: "synthetic-identity")
    }
    private func model(_ history: ResetCalendarHistory, _ account: AccountConfig, _ value: AccountReading?, at now: Date) -> ResetCalendarModel {
        ResetCalendarModel(accounts: [account], readings: value.map { [account.id: $0] } ?? [:], history: history, now: now, identity: { _ in "fixture@example.test" })
    }

    func testRolloverRetainsOldEventAlongsideNewCycleAndDeduplicatesReplay() throws {
        let account = config(), first = reading(base.addingTimeInterval(10), at: base)
        let next = reading(base.addingTimeInterval(100), at: base.addingTimeInterval(20))
        var history = ResetCalendarHistory()
        history.incorporate(account: account, previous: nil, next: first, at: base)
        for _ in 0..<5 { history.incorporate(account: account, previous: first, next: next, at: base.addingTimeInterval(20)) }
        let result = model(history, account, next, at: base.addingTimeInterval(20))
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.filter { $0.status == .expired }.count, 1)
        XCTAssertEqual(result.summary(in: result.events), "本月 2 项重置")
        let restored = try JSONDecoder().decode(ResetCalendarHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored, history)
    }

    func testFirstOverwrittenReadingAndTimerOnlyElapsedDateAreRetained() {
        let account = config(), first = reading(base.addingTimeInterval(10), at: base)
        var history = ResetCalendarHistory()
        history.incorporate(account: account, previous: nil, next: first, at: base)
        let failed = AccountReading(status: .unavailable, checkedAt: base.addingTimeInterval(20), lastSuccessAt: nil)
        XCTAssertEqual(model(history, account, failed, at: base.addingTimeInterval(20)).events.first?.status, .expired)
        history.incorporate(account: account, previous: first, next: failed, at: base.addingTimeInterval(20))
        XCTAssertEqual(history.accounts[account.id]?.archived.count, 1)
        var migration = ResetCalendarHistory()
        migration.incorporate(account: account, previous: first, next: reading(base.addingTimeInterval(100), at: base.addingTimeInterval(20)), at: base.addingTimeInterval(20))
        XCTAssertEqual(migration.accounts[account.id]?.archived.count, 1)
    }

    func testFutureCorrectionsIncludingDelayedTransportCannotCreatePhantomHistory() {
        let account = config(), first = reading(base.addingTimeInterval(10), at: base)
        let corrected = reading(base.addingTimeInterval(30), at: base.addingTimeInterval(1))
        var history = ResetCalendarHistory()
        history.incorporate(account: account, previous: nil, next: first, at: base)
        // The correction was observed before the old deadline but delivered later.
        history.incorporate(account: account, previous: first, next: corrected, at: base.addingTimeInterval(20))
        XCTAssertTrue(history.accounts[account.id]?.archived.isEmpty == true)
        XCTAssertEqual(model(history, account, corrected, at: base.addingTimeInterval(20)).events.map(\.resetsAt), [corrected.windows[0].resetsAt!])
        history.incorporate(account: account, previous: corrected, next: first, at: base.addingTimeInterval(21))
        XCTAssertEqual(history.accounts[account.id]?.pending.first?.resetsAt, corrected.windows[0].resetsAt)
    }

    func testSourceIdentityAndEmailChangesCannotInheritHistory() {
        for change in 0..<4 {
            var account = config(), history = ResetCalendarHistory()
            var first = reading(base.addingTimeInterval(-1), at: base)
            first.resetHistoryIdentity = "12345678-1234-1234-1234-123456789abc"
            history.incorporate(account: account, previous: nil, next: first, at: base)
            var next = reading(base.addingTimeInterval(100), at: base.addingTimeInterval(1))
            next.resetHistoryIdentity = first.resetHistoryIdentity
            if change == 0 { account.location = "/replacement.json" }
            if change == 1 { next.identityKey = "replacement-identity" }
            if change == 2 { next.email = "replacement@example.test" }
            if change == 3 { next.resetHistoryIdentity = "87654321-1234-1234-1234-123456789abc" }
            history.incorporate(account: account, previous: first, next: next, at: base.addingTimeInterval(1))
            XCTAssertTrue(history.accounts[account.id]?.archived.isEmpty == true)
        }
    }

    func testImportedHistoryIsCalendarOnlyAndHiddenForDisabledAccounts() throws {
        var account = config(), current = reading(base.addingTimeInterval(100), at: base)
        let past = QuotaResetRecord(id: "weekly", label: "旧每周", group: "default", resetsAt: base.addingTimeInterval(-100))
        current.resetHistory = [past, past]
        var history = ResetCalendarHistory();history.incorporate(account: account, previous: nil, next: current, at: base)
        XCTAssertEqual(model(history, account, current, at: base).events.count, 2)
        XCTAssertEqual(current.windows.count, 1);XCTAssertTrue(current.isFresh(at: base))
        account.enabled = false;XCTAssertTrue(model(history, account, current, at: base).events.isEmpty)
        XCTAssertEqual(history.accounts[account.id]?.archived.count, 1)
        let bytes = try JSONEncoder().encode(history), text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("fixture@example.test"));XCTAssertFalse(text.contains("remainingPercent"))
    }

    func testUntrustedObservationAndReserveCannotSeedHistory() {
        let account = config();var history = ResetCalendarHistory()
        var value = reading(base.addingTimeInterval(-1), at: base.addingTimeInterval(100))
        history.incorporate(account: account, previous: nil, next: value, at: base);XCTAssertTrue(history.accounts.isEmpty)
        value.lastSuccessAt = base;value.sourceCollectedAtPresent = true
        history.incorporate(account: account, previous: nil, next: value, at: base);XCTAssertTrue(history.accounts.isEmpty)
        value.sourceCollectedAt = base;value.windows[0].group = "reserve"
        history.incorporate(account: account, previous: nil, next: value, at: base);XCTAssertTrue(history.accounts.isEmpty)
    }

    func testSnapshotImportsOptionalPastMetadataWithoutInvalidatingBalances() throws {
        var source: [String: Any] = ["id":"fixture", "status":"connected", "lastSuccessAt":base.timeIntervalSince1970,
            "windows":[["id":"weekly","remainingPercent":73,"resetsAt":base.addingTimeInterval(100).timeIntervalSince1970]],
            "resetHistory":[["id":"weekly","label":"每周","quotaGroup":NSNull(),"resetsAt":base.addingTimeInterval(-100).timeIntervalSince1970],
                            ["id":"bad","resetsAt":"invalid"], ["id":"future","label":"每周","resetsAt":base.addingTimeInterval(100).timeIntervalSince1970],
                            ["id":"reserve","label":"每周","quotaGroup":"reserve","resetsAt":base.addingTimeInterval(-100).timeIntervalSince1970]]]
        var result = try ProviderClient.parseSnapshot(JSONSerialization.data(withJSONObject: source), at: base)
        XCTAssertEqual(result.resetHistory?.count, 1);XCTAssertEqual(result.windows[0].remainingPercent, 73)
        for invalid: Any in ["wrong", Array(repeating: ["id":"weekly"], count:10001)] {
            source["resetHistory"] = invalid
            result = try ProviderClient.parseSnapshot(JSONSerialization.data(withJSONObject: source), at: base)
            XCTAssertNil(result.resetHistory);XCTAssertEqual(result.windows[0].remainingPercent, 73)
        }
    }

    @MainActor func testCacheMigrationRestartRemovalDemoAndPrivateFileMode() async throws {
        let f = try Fixture();defer { f.remove() }
        let observed = Date().addingTimeInterval(-60), reset = Date().addingTimeInterval(-30)
        var cached = reading(reset, at: observed)
        cached.identityKey = nil
        try FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        try JSONEncoder().encode([f.account]).write(to: f.state.appendingPathComponent("accounts.json"))
        try JSONEncoder().encode([f.account.id: cached]).write(to: f.state.appendingPathComponent("readings.json"))
        try f.publish(reset: Date().addingTimeInterval(3600))
        let store = f.store();XCTAssertEqual(store.calendarModel().events.filter { $0.status == .expired }.count, 1)
        await store.refresh();XCTAssertEqual(store.calendarModel().events.count, 2)
        let file = f.state.appendingPathComponent(ResetCalendarHistory.fileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let before = try Data(contentsOf: file)
        store.loadDemo();XCTAssertFalse(store.calendarModel().events.contains { $0.resetsAt == reset })
        XCTAssertEqual(try Data(contentsOf: file), before)
        store.exitDemo();XCTAssertEqual(store.calendarModel().events.count, 2)
        let restored = f.store();XCTAssertEqual(restored.calendarModel().events.count, 2)
        restored.remove(f.account);XCTAssertFalse(FileManager.default.fileExists(atPath: file.path));XCTAssertTrue(f.store().calendarModel().events.isEmpty)
    }

    @MainActor func testCorruptArchiveIsPreservedAndWriteFailuresRemainVisible() async throws {
        let f = try Fixture();defer { f.remove() };try f.publish(reset: Date().addingTimeInterval(-1))
        try FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        let file = f.state.appendingPathComponent(ResetCalendarHistory.fileName)
        try Data("broken original".utf8).write(to: file)
        let store = f.store();try await store.connect(f.account)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken original")
        XCTAssertEqual(store.errorMessage, "重置历史未能读取，原文件已保留。")
        let another = try Fixture();defer { another.remove() };try another.publish(reset: Date().addingTimeInterval(-1))
        let fresh = another.store()
        try FileManager.default.createDirectory(at: another.state.appendingPathComponent(ResetCalendarHistory.fileName), withIntermediateDirectories: true)
        try await fresh.connect(another.account)
        XCTAssertEqual(fresh.errorMessage, ResetCalendarHistory.persistenceError)
    }

    @MainActor private final class Fixture {
        let root: URL, state: URL, source: URL, defaults: UserDefaults, suite: String, account: AccountConfig
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            state = root.appendingPathComponent("state");source = root.appendingPathComponent("source.json")
            suite = "TokenBar.ResetHistoryTests." + UUID().uuidString;defaults = UserDefaults(suiteName: suite)!
            account = AccountConfig(provider: .snapshot, name: "Fixture", method: .snapshotFile, location: source.path, serviceLabel: "Codex")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func publish(reset: Date) throws {
            let value: [String: Any] = ["id":"fixture","status":"connected","lastSuccessAt":Date().addingTimeInterval(-2).timeIntervalSince1970,"profile":["email":"fixture@example.test"],"windows":[["id":"weekly","label":"每周","remainingPercent":73,"resetsAt":reset.timeIntervalSince1970]]]
            try JSONSerialization.data(withJSONObject: value).write(to: source)
        }
        func store() -> AppStore { AppStore(directory: state, startTimers: false, defaults: defaults) }
        func remove() { defaults.removePersistentDomain(forName: suite);try? FileManager.default.removeItem(at: root) }
    }
}
