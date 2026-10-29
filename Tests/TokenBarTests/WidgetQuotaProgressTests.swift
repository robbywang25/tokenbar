import XCTest
import TokenBarWidgetShared

final class WidgetQuotaProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_280_000)

    func testGeometryPreservesExactRemainingAmountIncludingZeroAndAlmostFull() throws {
        for percent in [0.0, 0.1, 9.9, 10, 19.9, 20, 49.9, 50, 63, 99, 100] {
            let progress = try XCTUnwrap(meter(percent))
            let cells = (0..<10).map { progress.fill(in: $0) }
            XCTAssertEqual(cells.reduce(0, +) * 10, percent, accuracy: 0.000_001)
            XCTAssertTrue(cells.allSatisfy { (0...1).contains($0) })
            XCTAssertEqual(cells.filter { $0 == 1 }.count, Int(percent / 10))
        }
        XCTAssertEqual(meter(0)?.fill(in: 0), 0)
        XCTAssertEqual(meter(100)?.fill(in: 9), 1)
        XCTAssertEqual(meter(99)?.fill(in: 9) ?? -1, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(meter(50)?.fill(in: -1), 0)
        XCTAssertEqual(meter(50)?.fill(in: 10), 0)
    }

    func testUnknownUnlimitedPointsAndUnobservedValuesHaveNoMeter() {
        for percent: Double? in [nil, .nan, .infinity, -.infinity, -1, 101] {
            XCTAssertNil(meter(percent))
        }
        for value in ["—", "∞", "不限量"] {
            XCTAssertNil(meter(50, value: value))
        }
        XCTAssertNil(meter(50, id: "credits"))
        XCTAssertNil(meter(50, id: "reset-cards"))
        var unobserved = account(); unobserved.observedAt = nil
        XCTAssertNil(meter(50, account: unobserved))
    }

    func testFreshThresholdsMatchAndroidAndExpirationTurnsHistorical() {
        XCTAssertEqual(meter(0)?.tone, .low)
        XCTAssertEqual(meter(19.9)?.tone, .low)
        XCTAssertEqual(meter(20)?.tone, .warning)
        XCTAssertEqual(meter(49.9)?.tone, .warning)
        XCTAssertEqual(meter(50)?.tone, .healthy)
        XCTAssertEqual(meter(100)?.tone, .healthy)
        for status in [TokenBarWidgetStatus.stale, .needsAuth, .unavailable, .notConfigured, .unsupported] {
            var historical = account(); historical.status = status
            XCTAssertEqual(meter(63, account: historical)?.tone, .historical)
            XCTAssertEqual(meter(63, account: historical)?.remainingPercent, 63)
        }
        var expired = account(); expired.freshUntil = now
        XCTAssertEqual(meter(63, account: expired)?.tone, .historical)
    }

    func testEachWindowUsesItsOwnPercentageAndPointsStayIndependent() throws {
        var row = account()
        row.metrics = [
            .init(id: "short", label: "5 小时", value: "63%", remainingPercent: 63),
            .init(id: "weekly", label: "每周", value: "12%", remainingPercent: 12)
        ]
        let meters = row.displayMetrics().compactMap { TokenBarWidgetQuotaProgress(metric: $0, account: row, at: now) }
        XCTAssertEqual(meters.map(\.remainingPercent), [63, 12])
        XCTAssertEqual(meters.map(\.tone), [.healthy, .low])
        row.metrics.append(.init(id: "credits", label: "剩余点数", value: "100 点", remainingPercent: nil))
        XCTAssertEqual(row.displayMetrics().map(\.id), ["short", "credits"])
        XCTAssertEqual(row.displayMetrics().compactMap { TokenBarWidgetQuotaProgress(metric: $0, account: row, at: now) }.count, 1)
    }

    private func account() -> TokenBarWidgetAccount {
        .init(id: UUID(), email: "fixture@example.com", provider: "Codex", plan: nil,
              status: .connected, observedAt: now, freshUntil: now.addingTimeInterval(120), metrics: [])
    }

    private func meter(_ percent: Double?, value: String = "50%", id: String = "weekly",
                       account row: TokenBarWidgetAccount? = nil) -> TokenBarWidgetQuotaProgress? {
        .init(metric: .init(id: id, label: "每周", value: value, remainingPercent: percent),
              account: row ?? account(), at: now)
    }
}
