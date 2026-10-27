import AppKit
import SwiftUI
import XCTest
@testable import TokenBar

final class QuotaTrendLayoutTests: XCTestCase {
    func testRenderedCurveNeverDrawsAcrossAResetOrMissingObservation() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let points = [
            QuotaBalancePoint(at: start, remaining: 70, connect: false),
            QuotaBalancePoint(at: start.addingTimeInterval(60), remaining: 68, connect: true),
            QuotaBalancePoint(at: start.addingTimeInterval(120), remaining: 100, connect: false),
            QuotaBalancePoint(at: start.addingTimeInterval(180), remaining: 99, connect: true),
            QuotaBalancePoint(at: start.addingTimeInterval(480), remaining: 98, connect: false)
        ]
        let path = QuotaTrendLine(points: points, from: start, to: start.addingTimeInterval(600))
            .path(in: CGRect(x: 0, y: 0, width: 300, height: 100))
        var elements: [CGPathElementType] = []
        path.cgPath.applyWithBlock { elements.append($0.pointee.type) }
        XCTAssertEqual(elements, [.moveToPoint, .addLineToPoint, .moveToPoint, .addLineToPoint, .moveToPoint])
    }

    func testRenderedCurveUsesTheWholeRequestedTimeAndPercentageRange() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let point = QuotaBalancePoint(at: start.addingTimeInterval(1800), remaining: 90, connect: false)
        let position = QuotaTrendLine.position(point, from: start, to: start.addingTimeInterval(3600),
                                              in: CGRect(x: 0, y: 0, width: 400, height: 100))
        XCTAssertEqual(position.x, 200, accuracy: 0.001)
        XCTAssertEqual(position.y, 10, accuracy: 0.001,
                       "A small quota decline must not expand to fill the chart's vertical range.")
    }

    @MainActor
    func testLongTrendSummaryAndForecastStayWithinNarrowNativeCard() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let formatter = ISO8601DateFormatter()
        func stamp(_ seconds: TimeInterval) -> String { formatter.string(from: now.addingTimeInterval(seconds)) }
        var balancePoints: [[String: Any]] = []
        for index in 0...10 {
            let at = stamp(Double(index - 10) * 120)
            let remaining = Double(90 - index)
            balancePoints.append(["at": at, "remaining": remaining, "connect": index > 0])
        }
        let trend: [String: Any] = [
            "status": "ready", "metric": "quota", "unit": "percentage-points",
            "from": stamp(-3600), "to": stamp(0), "bucketSeconds": 300,
            "balancePoints": balancePoints,
            "totalUsed": 10, "coverageSeconds": 1200, "observedAt": stamp(0)
        ]
        let document: [String: Any] = ["schemaVersion": 1, "collectedAt": stamp(0), "accounts": [[
            "id": "fixture", "status": "connected", "lastSuccessAt": stamp(0),
            "windows": [["id": "weekly", "label": "每周独立额度", "remainingPercent": 80,
                         "startsAt": stamp(-86400), "resetsAt": stamp(6 * 86400), "usageTrend": trend]]
        ]]]
        let reading = try ProviderClient.parseSnapshot(JSONSerialization.data(withJSONObject: document),
                                                       sourceAccountID: "fixture", source: "synthetic-trend", at: now)
        let quota = try XCTUnwrap(reading.windows.first)
        XCTAssertNotNil(quota.usageTrend)
        let view = NSHostingView(rootView: QuotaTrendView(window: quota, reading: reading, now: now)
            .frame(width: 260).background(Color(nsColor: .controlBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 260, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let size = view.fittingSize
        XCTAssertEqual(size.width, 260, accuracy: 0.5)
        XCTAssertTrue(size.height.isFinite)
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThan(size.height, 300)
        for _ in 0..<5 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize.width, size.width, accuracy: 0.5)
            XCTAssertEqual(view.fittingSize.height, size.height, accuracy: 0.5)
        }
        // Opt-in local review artifact. This view is entirely synthetic; default
        // test runs never create a screenshot or touch application state.
        if let previewPath = ProcessInfo.processInfo.environment["TOKENBAR_TREND_PREVIEW_PATH"], !previewPath.isEmpty {
            let output = URL(fileURLWithPath: previewPath)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output, options: .atomic)
        }
    }
}
