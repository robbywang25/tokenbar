import AppKit
import SwiftUI
import XCTest
@testable import TokenBar

final class QuotaAnalysisLayoutTests: XCTestCase {
    @MainActor
    func testExportPresentationKeepsHostAcrossRefreshAndRestoresOrdinaryDismissal() async throws {
        let suite = "TokenBar.QuotaExportPolicy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let storage = GodSessionStorage(read: { _ in XCTFail("Export policy must not read credentials"); throw GodError.signedOut },
            write: { _, _ in XCTFail("Export policy must not write credentials") },
            delete: { _ in XCTFail("Export policy must not delete credentials") })
        let authentication = GodAuthentication(directory: directory, storage: storage)
        let store = AppStore(directory: directory, startTimers: false, defaults: defaults)
        XCTAssertTrue(menuPanelDismissesOnFocusLoss(authentication))
        store.isPresentingFileExporter = true
        XCTAssertFalse(menuPanelDismissesOnFocusLoss(authentication, presentationActive: store.isPresentingFileExporter))
        await store.refresh()
        XCTAssertTrue(store.isPresentingFileExporter)
        XCTAssertFalse(menuPanelDismissesOnFocusLoss(authentication, presentationActive: store.isPresentingFileExporter))
        XCTAssertFalse(try store.exportCloudRecords().keys.contains { $0.lowercased().contains("export") })
        store.isPresentingFileExporter = false
        XCTAssertTrue(menuPanelDismissesOnFocusLoss(authentication, presentationActive: store.isPresentingFileExporter))
    }

    @MainActor
    func testAnalysisFitsWideAndNarrowPanelWithoutChangingSelection() throws {
        let suite = "TokenBar.QuotaAnalysisLayout." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, startTimers: false, defaults: preferences)
        let now = Date(timeIntervalSince1970: 1_793_155_200)
        store.now = now
        let accounts = (0..<2).map { index in
            AccountConfig(provider: .codex, name: "Synthetic \(index)", method: .localFile,
                location: directory.appendingPathComponent("unused-\(index)").path)
        }
        var points: [QuotaBalancePoint] = []
        for index in 0...10 {
            let seconds: Double = Double(index - 10) * 120
            let at = now.addingTimeInterval(seconds)
            let remaining = Double(90 - index)
            points.append(QuotaBalancePoint(at: at, remaining: remaining, connect: index > 0))
        }
        let trend = QuotaUsageTrend(status: "ready", from: now.addingTimeInterval(-3_600), to: now, bucketSeconds: 300,
            balancePoints: points, totalUsed: 10, coverageSeconds: 1200, observedAt: now)
        let quota = QuotaWindow(id: "weekly", label: "每周独立额度", remainingPercent: 80,
            resetsAt: now.addingTimeInterval(6 * 86_400), startsAt: now.addingTimeInterval(-86_400), usageTrend: trend)
        store.accounts = accounts
        for (index, account) in accounts.enumerated() {
            var accountQuota = quota
            if index == 1 {
                accountQuota.remainingPercent = 60
                var comparisonTrend = trend
                comparisonTrend.balancePoints = points.map { point in
                    QuotaBalancePoint(at: point.at, remaining: point.remaining - 20, connect: point.connect)
                }
                accountQuota.usageTrend = comparisonTrend
            }
            store.readings[account.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now,
                windows: [accountQuota], email: "account-\(index)-long-but-valid-display-name@example.test", identityKey: account.id.uuidString)
        }
        let semantics = try XCTUnwrap(QuotaWindowSemantics(quota))
        let selection = QuotaAnalysisSelection(accountID: accounts[0].id.uuidString, windowKey: semantics.selectionKey,
                                               comparisonID: accounts[1].id.uuidString)
        selection.save(to: preferences)
        for width in [520.0, 900.0] {
            let host = NSHostingView(rootView: QuotaAnalysisView(store: store).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: width, height: 740),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let fitted = host.fittingSize
            XCTAssertEqual(fitted.width, width, accuracy: 0.5)
            XCTAssertTrue(fitted.height.isFinite)
            XCTAssertGreaterThan(fitted.height, 350)
            XCTAssertLessThan(fitted.height, 1_400)
            for _ in 0..<3 {
                host.needsLayout = true; host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, fitted.width, accuracy: 0.5)
                XCTAssertEqual(host.fittingSize.height, fitted.height, accuracy: 0.5)
            }
            XCTAssertEqual(QuotaAnalysisSelection.load(from: preferences), selection)
            if width == 900, let path = ProcessInfo.processInfo.environment["TOKENBAR_ANALYSIS_PREVIEW_PATH"], !path.isEmpty {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                host.setFrameSize(fitted); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output, options: .atomic)
            }
        }
    }
}
