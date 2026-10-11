import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class WidgetPublicationTests: XCTestCase {
    @MainActor
    func testPublishesCommittedUpdatesAndRemovalButNeverDemoOrClockTicks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TokenBar.WidgetPublicationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("fixture.json")
        func write(percent: Double) throws {
            let now = Date().timeIntervalSince1970
            let object: [String: Any] = ["id": "fixture", "status": "connected", "lastSuccessAt": now,
                "profile": ["email": "widget@example.com"],
                "windows": [["id": "weekly", "remainingPercent": percent]]]
            try JSONSerialization.data(withJSONObject: object).write(to: input)
        }
        try write(percent: 63)
        let config = AccountConfig(provider: .snapshot, name: "Hidden name", method: .snapshotFile,
                                   location: input.path, sourceAccountID: "fixture", serviceLabel: "Codex")
        let store = AppStore(directory: root.appendingPathComponent("state"), startTimers: false, defaults: defaults)
        var snapshots: [TokenBarWidgetSnapshot] = []
        store.onWidgetSnapshotChange = { snapshots.append($0) }
        store.publishWidgetSnapshot()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].accounts.isEmpty)
        try await store.connect(config)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.accounts.first?.metrics.first?.value, "63%")

        store.now = Date().addingTimeInterval(15)
        store.setShowsAgentPrefix(false)
        XCTAssertEqual(snapshots.count, 2, "Clock and menu typography changes must not write widget snapshots.")
        let metric = try XCTUnwrap(store.availableMenuMetrics.first)
        store.setMenuMetric(metric, enabled: false)
        XCTAssertEqual(snapshots.count, 3)

        try write(percent: 42)
        await store.refresh()
        XCTAssertEqual(snapshots.count, 4, "A complete refresh publishes once, after applying all account results.")
        XCTAssertEqual(snapshots.last?.accounts.first?.metrics.first?.value, "42%")
        store.loadDemo()
        store.publishWidgetSnapshot()
        await store.refresh()
        XCTAssertEqual(snapshots.count, 4, "Demo must never replace the real shared state.")
        store.exitDemo()
        XCTAssertEqual(snapshots.count, 5)
        XCTAssertEqual(snapshots.last?.accounts.first?.email, "widget@example.com")

        // An unreadable source must publish its failure, not retain a current balance.
        try FileManager.default.removeItem(at: input)
        await store.refresh()
        XCTAssertEqual(snapshots.count, 6)
        XCTAssertFalse(try XCTUnwrap(snapshots.last?.accounts.first).isFresh(at: Date()))
        XCTAssertTrue(try XCTUnwrap(snapshots.last?.accounts.first).metrics.isEmpty)
        store.remove(config)
        XCTAssertEqual(snapshots.count, 7)
        XCTAssertTrue(try XCTUnwrap(snapshots.last).accounts.isEmpty)
    }
}
