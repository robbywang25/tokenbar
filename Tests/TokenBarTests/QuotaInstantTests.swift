import Foundation
import XCTest
@testable import TokenBar

final class QuotaInstantTests: XCTestCase {
    func testStrictUTCIntervalAndOffsetBoundaries() throws {
        let lower: TimeInterval = 1_577_836_800, upper: TimeInterval = 4_102_444_800
        XCTAssertEqual(QuotaUsageTrend.instant("2020-01-01T00:00:00Z")?.timeIntervalSince1970, lower)
        XCTAssertEqual(QuotaUsageTrend.instant("2019-12-31T10:00:00-14:00")?.timeIntervalSince1970, lower)
        XCTAssertEqual(QuotaUsageTrend.instant("2020-01-01T14:00:00+14:00")?.timeIntervalSince1970, lower)
        XCTAssertNil(QuotaUsageTrend.instant("2019-12-31T23:59:59.999999999Z"))
        XCTAssertNil(QuotaUsageTrend.instant("2020-01-01T13:59:59+14:00"))
        XCTAssertNil(QuotaUsageTrend.instant("2100-01-01T00:00:00Z"))
        XCTAssertNil(QuotaUsageTrend.instant("2100-01-01T14:00:00+14:00"))
        XCTAssertEqual(QuotaUsageTrend.instant("2100-01-01T13:59:59+14:00")?.timeIntervalSince1970, upper - 1)
        let last = try XCTUnwrap(QuotaUsageTrend.instant("2099-12-31T23:59:59.999999999Z"))
        XCTAssertLessThan(last.timeIntervalSince1970, upper)
        XCTAssertGreaterThan(last.timeIntervalSince1970, upper - 0.001)
        XCTAssertNil(QuotaUsageTrend.instant("2099-12-31T10:00:00-14:00"))
    }

    func testGregorianDatesAndFixedOffsetsMatchIndependentCalendarConversion() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for year in [2019, 2020, 2024, 2026, 2096, 2099, 2100] {
            for month in 1...12 {
                let first = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: 1)))
                let lastDay = try XCTUnwrap(calendar.range(of: .day, in: .month, for: first)).count
                for day in [1, lastDay] {
                    let local = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 13, minute: 59, second: 59)))
                    for offset in [-50_400, -19_800, 0, 19_800, 50_400] {
                        let zone = String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3_600, (abs(offset) / 60) % 60)
                        let stamp = String(format: "%04d-%02d-%02dT13:59:59.125", year, month, day) + zone
                        let expected = local.timeIntervalSince1970 - Double(offset) + 0.125
                        let actual = QuotaUsageTrend.instant(stamp)
                        if expected >= 1_577_836_800 && expected < 4_102_444_800 {
                            XCTAssertEqual(try XCTUnwrap(actual).timeIntervalSince1970, expected, accuracy: 0.000001, stamp)
                        } else {
                            XCTAssertNil(actual, stamp)
                        }
                    }
                }
            }
        }
        XCTAssertNotNil(QuotaUsageTrend.instant("2024-02-29T23:59:59Z"))
        XCTAssertNotNil(QuotaUsageTrend.instant("2096-02-29T23:59:59Z"))
    }

    func testMalformedDatesNumbersAndBooleansAreRejectedWithoutNormalization() {
        let invalid: [Any] = [true, false, 1_793_145_600, NSNull(), "", "2026-10-28", "2026-10-28T00:00:00",
            "2026-10-28t00:00:00Z", "2026-10-28T00:00:00z", "2026-10-28 00:00:00Z", "2026-10-28T00:00:00Z\n",
            " 2026-10-28T00:00:00Z", "2026-10-28T00:00:00Z ", "2026-02-29T00:00:00Z", "2100-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z", "2026-00-01T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-00T00:00:00Z",
            "2026-10-28T24:00:00Z", "2026-10-28T00:60:00Z", "2026-10-28T00:00:60Z", "2026-10-28T-1:00:00Z",
            "2026-10-28T00:00:00.Z", "2026-10-28T00:00:00.1234567890Z", "2026-10-28T00:00:00.1",
            "2026-10-28T00:00:00+14:01", "2026-10-28T00:00:00-14:01", "2026-10-28T00:00:00+15:00",
            "2026-10-28T00:00:00+00:60", "2026-10-28T00:00:00+1400", "2026-10-28T00:00:00+01:00:00",
            "2026-10-28T00:00:00UTC", "2026-１０-28T00:00:00Z", "0000-01-01T00:00:00Z", "9999-01-01T00:00:00Z"]
        for value in invalid { XCTAssertNil(QuotaUsageTrend.instant(value), String(describing: value)) }
    }

    func testFractionalSecondsAndConcurrentCallsHaveNoSharedMutableState() async throws {
        let base = try XCTUnwrap(QuotaUsageTrend.instant("2026-10-28T03:04:05Z"))
        let fractions = ["1", "12", "123", "1234", "12345", "123456", "1234567", "12345678", "123456789"]
        for fraction in fractions {
            let value = try XCTUnwrap(QuotaUsageTrend.instant("2026-10-28T03:04:05." + fraction + "Z"))
            XCTAssertEqual(value.timeIntervalSince1970, base.timeIntervalSince1970 + Double("0." + fraction)!, accuracy: 0.000001)
        }
        let input = ["2026-10-28T11:04:05.123456789+08:00", "2026-10-27T13:04:05.123456789-14:00", "2026-10-28T03:04:05.123456789Z"]
        let values = await withTaskGroup(of: [Date?].self, returning: [[Date?]].self) { group in
            for _ in 0..<32 { group.addTask { input.map(QuotaUsageTrend.instant) } }
            var output: [[Date?]] = []
            for await result in group { output.append(result) }
            return output
        }
        let expected = QuotaUsageTrend.instant(input[0])
        XCTAssertNotNil(expected)
        XCTAssertEqual(values.count, 32)
        XCTAssertTrue(values.allSatisfy { $0.allSatisfy { $0 == expected } })
    }

    @MainActor
    func testBoundedSyntheticSnapshotParsePerformance() throws {
        let now = Date(timeIntervalSince1970: 1_793_145_600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now)
        var points: [[String: Any]] = []
        for index in 0..<512 {
            let at = now.addingTimeInterval(Double(index - 511) * 7)
            let remaining = 80 - Double(index) * 5 / 511
            points.append(["at": formatter.string(from: at), "remaining": remaining, "connect": index > 0])
        }
        let trend: [String: Any] = ["status": "ready", "metric": "quota", "unit": "percentage-points",
            "from": formatter.string(from: now.addingTimeInterval(-3_600)), "to": stamp,
            "bucketSeconds": 300, "balancePoints": points, "totalUsed": 5, "coverageSeconds": 3577, "observedAt": stamp]
        var windows: [[String: Any]] = []
        for index in 0..<16 {
            windows.append(["id": "weekly-\(index)", "label": "Synthetic window \(index)", "remainingPercent": 75,
                            "unit": "percent", "usageTrend": trend])
        }
        let account: [String: Any] = ["id": "synthetic-account", "product": "fixture", "status": "connected",
            "lastSuccessAt": stamp, "checkedAt": stamp, "windows": windows]
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "collectedAt": stamp, "accounts": [account]])
        XCTAssertLessThan(data.count, ProviderClient.maximumBytes)
        XCTAssertTrue(Thread.isMainThread)
        let started = ProcessInfo.processInfo.systemUptime
        let catalog = try SnapshotCatalog.parse(data, source: "synthetic-performance-fixture", at: now)
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        XCTAssertEqual(catalog.entries.first?.reading.windows.count, 16)
        XCTAssertTrue(catalog.entries[0].reading.windows.allSatisfy { $0.usageTrend?.balancePoints.count == 512 })
        // One bounded sample, not a hardware-dependent pass/fail threshold or
        // XCTest's repeated measure loop. No real source or credentials used.
        print("QUOTA_PARSE_BENCHMARK windows=16 points=8192 bytes=\(data.count) mainThread=true elapsedMs=\(String(format: "%.3f", milliseconds))")
    }
}
