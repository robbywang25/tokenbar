import Foundation
import XCTest
@testable import TokenBar

final class QuotaUsageTrendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_145_600)
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func rawTrend() -> [String: Any] {
        ["status": "ready", "metric": "quota", "unit": "percentage-points",
         "from": iso(now.addingTimeInterval(-3_600)), "to": iso(now), "bucketSeconds": 300,
         "balancePoints": (0...5).map { i in ["at": iso(now.addingTimeInterval(Double(i - 5) * 120)), "remaining": 80 - i, "connect": i > 0] as [String: Any] },
         "coverageSeconds": 600, "totalUsed": 5, "observedAt": iso(now)]
    }
    private func window(id: String = "session", trend: QuotaUsageTrend? = nil) -> QuotaWindow {
        QuotaWindow(id: id, label: id, remainingPercent: 75, resetsAt: now.addingTimeInterval(3_600),
                    startsAt: now.addingTimeInterval(-3_600), usageTrend: trend)
    }
    private func reading(_ windows: [QuotaWindow]) -> AccountReading {
        AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: windows)
    }
    private func snapshot(trends: [Any]) throws -> AccountReading {
        let windows: [[String: Any]] = trends.enumerated().map { i, trend in
            ["id": i == 0 ? "session" : "weekly", "label": i == 0 ? "会话" : "每周", "remainingPercent": i == 0 ? 75 : 40,
             "usageTrend": trend]
        }
        let data = try JSONSerialization.data(withJSONObject: ["status": "connected", "lastSuccessAt": iso(now), "windows": windows])
        return try ProviderClient.parseSnapshot(data, at: now)
    }

    func testIndependentWindowHistoryNeverBorrowsSiblingOrLegacyTrend() throws {
        let parsed = try snapshot(trends: [rawTrend(), NSNull()])
        XCTAssertEqual(parsed.windows[0].usageTrend?.balancePoints.last?.remaining, 75)
        XCTAssertNil(parsed.windows[1].usageTrend)
        XCTAssertEqual(parsed.windows[1].remainingPercent, 40)
    }

    func testMalformedOptionalHistoryDoesNotRejectValidBalances() throws {
        var variants: [[String: Any]] = []
        for field in ["bucketSeconds", "coverageSeconds", "totalUsed"] {
            var raw = rawTrend(); raw[field] = true; variants.append(raw)
        }
        var raw = rawTrend(); raw["from"] = "2026-02-30T00:00:00Z"; variants.append(raw)
        raw = rawTrend(); raw["unit"] = "points"; variants.append(raw)
        raw = rawTrend(); raw["balancePoints"] = Array(repeating: ["at": iso(now), "remaining": 75, "connect": false] as [String: Any], count: 513); variants.append(raw)
        for mutation: Any in [true, -1, 101, "75"] {
            raw = rawTrend(); raw["balancePoints"] = [["at": iso(now), "remaining": mutation, "connect": false]]; variants.append(raw)
        }
        raw = rawTrend(); raw["balancePoints"] = [["at": iso(now), "remaining": 75, "connect": 1]]; variants.append(raw)
        raw = rawTrend(); raw["balancePoints"] = [["at": iso(now), "remaining": 75, "connect": false], ["at": iso(now), "remaining": 70, "connect": true]]; variants.append(raw)
        for variant in variants {
            let result = try snapshot(trends: [variant])
            XCTAssertEqual(result.windows[0].remainingPercent, 75)
            XCTAssertNil(result.windows[0].usageTrend)
        }
    }

    func testForecastNeedsRecentContinuousMatchingSourceObservations() throws {
        let trend = try XCTUnwrap(QuotaUsageTrend.parse(rawTrend()))
        let w = window(trend: trend), r = reading([window(trend: trend)])
        let a = trend.analysis(window: w, reading: r, now: now)
        XCTAssertEqual(a.forecast?.burnPerHour, 30)
        XCTAssertEqual(a.forecast?.minutesLeft, 150)
        XCTAssertEqual(a.forecast?.beforeReset, false)
        XCTAssertEqual(a.used, 5)
        XCTAssertEqual(a.coveragePercent, 100.0 / 6, accuracy: 0.001)
        var broken = trend; broken.balancePoints[3].connect = false
        XCTAssertNil(broken.analysis(window: w, reading: r, now: now).forecast)
        var changed = w; changed.remainingPercent = 76
        XCTAssertNil(trend.analysis(window: changed, reading: r, now: now).forecast)
        var newer = r; newer.lastSuccessAt = now.addingTimeInterval(-5)
        XCTAssertNil(trend.analysis(window: w, reading: newer, now: now).forecast)
        XCTAssertNil(trend.analysis(window: w, reading: r, now: now.addingTimeInterval(121)).forecast)
        XCTAssertEqual(trend.analysis(window: w, reading: r, now: now.addingTimeInterval(121)).status, "stale")
    }

    func testResetIncreaseBreaksLineAndForecast() throws {
        var raw = rawTrend()
        raw["balancePoints"] = [["at": iso(now.addingTimeInterval(-120)), "remaining": 10, "connect": true], ["at": iso(now), "remaining": 75, "connect": true]]
        let trend = try XCTUnwrap(QuotaUsageTrend.parse(raw))
        XCTAssertEqual(trend.balancePoints.map(\.connect), [false, false])
        XCTAssertNil(trend.analysis(window: window(), reading: reading([window()]), now: now).forecast)
    }

    func testFutureAndInvalidStatusCannotShowPrivateHistory() throws {
        let trend = try XCTUnwrap(QuotaUsageTrend.parse(rawTrend()))
        var r = reading([window()]); r.status = .needsAuth
        XCTAssertTrue(trend.analysis(window: window(), reading: r, now: now).points.isEmpty)
        XCTAssertTrue(trend.analysis(window: window(), reading: reading([window()]), now: now.addingTimeInterval(-61)).points.isEmpty)
    }

    func testPaceUsesSourceTimeAndRequiresRealCycleStart() {
        let w = window(), r = reading([window()])
        let pace = QuotaUsageAnalysis.cyclePace(window: w, reading: r, now: now)
        XCTAssertEqual(pace?.status, "behind")
        XCTAssertEqual(pace?.elapsedPercent, 50)
        var gemini = w; gemini.startsAt = nil
        XCTAssertNil(QuotaUsageAnalysis.cyclePace(window: gemini, reading: r, now: now))
        var early = w; early.startsAt = now.addingTimeInterval(-60)
        XCTAssertNil(QuotaUsageAnalysis.cyclePace(window: early, reading: r, now: now))
        XCTAssertNil(QuotaUsageAnalysis.cyclePace(window: w, reading: r, now: now.addingTimeInterval(121)))
    }

    func testHistoryIsCachedLocallyButExcludedFromStrictGodSyncSchema() throws {
        let trend = try XCTUnwrap(QuotaUsageTrend.parse(rawTrend()))
        let r = reading([window(trend: trend)])
        let local = try JSONDecoder().decode(AccountReading.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(local.windows[0].usageTrend, trend)
        let portable = try GodSyncProjection.reading(r)
        XCTAssertNil(portable["windows"]?.array?.first?["usageTrend"])
        let old = reading([window()])
        XCTAssertEqual(try GodSyncProjection.reading(old), portable)
    }

    func testUnknownApiUsageIsNotZeroOrGenericConnectionError() throws {
        let data = try JSONSerialization.data(withJSONObject: ["status": "unavailable", "reason": "no_usage_data", "windows": []])
        let r = try ProviderClient.parseSnapshot(data, at: now)
        XCTAssertEqual(r.reason, "no_usage_data")
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertTrue(r.detail.contains("当前额度未知"))
        XCTAssertFalse(r.isFresh(at: now))
        XCTAssertNil(try GodSyncProjection.reading(r)["reason"])
    }
}
