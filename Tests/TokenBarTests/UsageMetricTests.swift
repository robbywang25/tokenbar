import Foundation
import XCTest
@testable import TokenBar

final class UsageMetricTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_145_600)
    private func stamp(_ offset: TimeInterval = 0) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    private func metric() -> [String: Any] {
        ["id": "project-requests", "label": "项目请求", "value": 42, "unit": "requests", "startsAt": stamp(-86400), "endsAt": stamp(), "observedAt": stamp()]
    }
    private func parse(_ metrics: [Any]) throws -> AccountReading {
        let document: [String: Any] = ["status": "connected", "product": "gemini-api", "checkedAt": stamp(), "lastSuccessAt": stamp(), "sourceCollectedAt": stamp(), "windows": [], "usageMetrics": metrics]
        return try ProviderClient.parseSnapshot(JSONSerialization.data(withJSONObject: document), at: now)
    }
    func testUsageOnlySuccessHasNoInventedQuotaAndStalesByMetricObservation() throws {
        let r = try parse([metric()])
        XCTAssertTrue(r.isFresh(at: now)); XCTAssertTrue(r.windows.isEmpty); XCTAssertNil(r.credits)
        XCTAssertEqual(r.usageMetrics?.first?.value, 42); XCTAssertEqual(r.product, "gemini-api")
        XCTAssertFalse(r.hasVisibleQuota); XCTAssertTrue(r.hasUsageMetrics)
        XCTAssertNil(try GodSyncProjection.reading(r)["usageMetrics"])
        XCTAssertNil(try GodSyncProjection.reading(r)["product"])
        var old = metric(); old["observedAt"] = stamp(-300); old["endsAt"] = stamp(-300)
        XCTAssertEqual(try parse([old]).status, .stale)
    }
    func testZeroObservedUsageIsValidButMalformedUsageCannotCreateSuccess() throws {
        var zero = metric(); zero["value"] = 0
        XCTAssertEqual(try parse([zero]).usageMetrics?.first?.value, 0)
        for value: Any in [true, -1, 1.5, "42", 9_007_199_254_740_992.0] {
            var m = metric(); m["value"] = value
            XCTAssertThrowsError(try parse([m]))
        }
        var wrong = metric(); wrong["unit"] = "percent"
        XCTAssertThrowsError(try parse([wrong]))
        wrong = metric(); wrong["endsAt"] = stamp(120)
        XCTAssertThrowsError(try parse([wrong]))
        XCTAssertThrowsError(try parse([metric(), metric()]))
        XCTAssertThrowsError(try parse([]))
    }
}
