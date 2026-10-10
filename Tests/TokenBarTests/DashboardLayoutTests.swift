import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TokenBar

final class DashboardLayoutTests: XCTestCase {
    @MainActor
    func testThirtyAccountDashboardKeepsFiniteStableGeometryAcrossRepeatedLayouts() throws {
        let fixture = try DashboardLayoutFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        fixture.populate(store, crowded: true, stale: false)
        let host = NSHostingView(rootView: DashboardView(store: store))
        let window = hiddenWindow(hosting: host)
        defer { window.contentView = nil; window.close() }

        let first = try layout(host)
        XCTAssertEqual(store.accounts.count, 30)
        XCTAssertEqual(store.accountIdentityLabel(store.accounts[0]), fixture.longEmail(index: 0))
        XCTAssertGreaterThan(first.documentSize.height, Self.panelSize.height,
                             "The test must lay out the actual overflowing account list, not just its fixed outer frame.")
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            host.needsLayout = true
            let next = try layout(host)
            assertSameGeometry(first, next)
            // A coarse runaway guard, not a machine-speed benchmark. The known
            // failure spends minutes repeatedly laying out an unchanged popover.
            if ProcessInfo.processInfo.systemUptime - started > 30 {
                XCTFail("Twenty unchanged layouts exceeded a generous 30-second runaway budget.")
                break
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @MainActor
    func testDashboardSettlesAfterMetricEmailAndFreshnessUpdates() throws {
        let fixture = try DashboardLayoutFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        fixture.populate(store, crowded: false, stale: false)
        let host = NSHostingView(rootView: DashboardView(store: store))
        let window = hiddenWindow(hosting: host)
        defer { window.contentView = nil; window.close() }
        let compact = try layout(host)

        fixture.populate(store, crowded: true, stale: false)
        let crowded = try layout(host)
        XCTAssertGreaterThan(crowded.documentSize.height, compact.documentSize.height,
                             "Published changes must reach the hosted dashboard and produce additional metric rows.")
        fixture.populate(store, crowded: true, stale: true)
        let stale = try layout(host)
        XCTAssertTrue(store.readings.values.allSatisfy { !$0.isFresh(at: store.now) })
        XCTAssertGreaterThan(stale.documentSize.height, crowded.documentSize.height,
                             "Stale rows add status text, exercising a second real content-height change.")

        let started = ProcessInfo.processInfo.systemUptime
        for cycle in 0..<12 {
            let isCrowded = cycle % 3 != 0
            let isStale = cycle % 3 == 2
            fixture.populate(store, crowded: isCrowded, stale: isStale)
            let updated = try layout(host)
            let expected = isStale ? stale : isCrowded ? crowded : compact
            assertSameGeometry(expected, updated)
            host.needsLayout = true
            assertSameGeometry(updated, try layout(host))
            if ProcessInfo.processInfo.systemUptime - started > 30 {
                XCTFail("Repeated data changes exceeded a generous 30-second runaway budget.")
                break
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    private static let panelSize = CGSize(width: 440, height: 620)

    private struct Geometry {
        let fittingSize: CGSize
        let documentSize: CGSize
    }

    @MainActor
    private func hiddenWindow(hosting host: NSHostingView<DashboardView>) -> NSWindow {
        // AppKit does not finish ScrollView document layout without a window.
        // This test-owned window is never ordered front or activated.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: Self.panelSize)
        XCTAssertFalse(window.isVisible)
        return window
    }

    @MainActor
    private func layout(_ host: NSHostingView<DashboardView>, file: StaticString = #filePath, line: UInt = #line) throws -> Geometry {
        // Drive a local, hidden AppKit view tree. No window is shown and no
        // button action, provider refresh, or real application's UI is invoked.
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let fitting = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSScrollView }.first,
                                  "The real SwiftUI ScrollView must be instantiated.", file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let size = document.frame.size
        for view in descendants(of: host) + [host] {
            XCTAssertTrue(view.frame.origin.x.isFinite && view.frame.origin.y.isFinite &&
                          view.frame.width.isFinite && view.frame.height.isFinite,
                          "Non-finite frame in hosted dashboard: \(type(of: view))", file: file, line: line)
            XCTAssertGreaterThanOrEqual(view.frame.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(view.frame.height, 0, file: file, line: line)
        }
        XCTAssertEqual(host.frame.width, Self.panelSize.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(host.frame.height, Self.panelSize.height, accuracy: 0.5, file: file, line: line)
        XCTAssertTrue(fitting.width.isFinite && fitting.height.isFinite, file: file, line: line)
        XCTAssertEqual(fitting.width, Self.panelSize.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(fitting.height, Self.panelSize.height, accuracy: 0.5, file: file, line: line)
        XCTAssertGreaterThan(size.width, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(size.width, Self.panelSize.width + 0.5, file: file, line: line)
        XCTAssertGreaterThan(size.height, 0, file: file, line: line)
        return Geometry(fittingSize: fitting, documentSize: size)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func assertSameGeometry(_ expected: Geometry, _ actual: Geometry,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.fittingSize.width, expected.fittingSize.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.fittingSize.height, expected.fittingSize.height, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.documentSize.width, expected.documentSize.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.documentSize.height, expected.documentSize.height, accuracy: 0.5, file: file, line: line)
    }
}

private struct DashboardLayoutFixture {
    let state: URL
    let defaults: UserDefaults
    private let suite: String
    private let now = Date(timeIntervalSince1970: 1_791_633_600)
    private let ids = (0..<30).map { _ in UUID() }

    init() throws {
        suite = "TokenBar.DashboardLayoutTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        state = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-DashboardLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: state)
    }

    @MainActor
    func makeStore() -> AppStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardNoNetworkProtocol.self]
        let client = ProviderClient(sessionConfiguration: configuration,
            credentialReader: { _, _ in
                XCTFail("Dashboard layout must not read Keychain credentials.")
                throw ProviderError.needsAuth
            }, sshReader: { _ in
                XCTFail("Dashboard layout must not start SSH.")
                throw ProviderError.unavailable
            })
        return AppStore(directory: state, client: client, startTimers: false, defaults: defaults)
    }

    func longEmail(index: Int) -> String {
        "account-\(index)-" + String(repeating: "long", count: 12) + "@" +
        String(repeating: "workspace", count: 6) + "." + String(repeating: "example", count: 6) + ".test"
    }

    @MainActor
    func populate(_ store: AppStore, crowded: Bool, stale: Bool) {
        store.now = now
        let accounts = ids.enumerated().map { index, id in
            AccountConfig(id: id, provider: .snapshot, name: "Synthetic \(index)", method: .snapshotFile,
                          location: state.appendingPathComponent("unused-\(index).json").path,
                          sourceAccountID: "fixture-\(index)", serviceLabel: index % 2 == 0 ? "Codex" : "Claude Code")
        }
        store.accounts = accounts
        store.readings = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { index, account in
            let windows = (0..<(crowded ? 10 : 1)).map { metric in
                QuotaWindow(id: "window-\(metric)", label: metric == 0 ? "5 小时" : "第 \(metric) 个模型每周额度",
                    remainingPercent: Double((index * 7 + metric * 11) % 101),
                    resetsAt: now.addingTimeInterval(172_800), startsAt: now.addingTimeInterval(-432_000),
                    group: metric == 9 ? "reserve" : metric > 5 ? "additional" : "default")
            }
            let observed = stale ? now.addingTimeInterval(-180) : now
            let reading = AccountReading(status: .connected, checkedAt: observed, lastSuccessAt: observed,
                windows: windows, credits: crowded ? 1_234_567.89 : nil,
                resetCardsAvailable: crowded ? 12 : nil,
                email: crowded ? longEmail(index: index) : "account-\(index)@example.test",
                detail: stale ? "来源读数已过期，等待数据源更新。" : "",
                planName: crowded ? "Synthetic multi-model subscription" : nil)
            return (account.id, reading)
        })
    }
}

private final class DashboardNoNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Dashboard layout must not issue network requests.")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
