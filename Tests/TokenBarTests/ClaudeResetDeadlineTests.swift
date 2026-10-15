import XCTest
@testable import TokenBar

final class ClaudeResetDeadlineTests: XCTestCase {
    private let five = Date(timeIntervalSince1970: 1_792_065_600)
    private let week = Date(timeIntervalSince1970: 1_792_670_400)
    private var account: AccountConfig {
        AccountConfig(provider: .snapshot, name: "Fixture", method: .snapshotFile, location: "/fixture.json", serviceLabel: "Claude Code")
    }
    func testBothCyclesKeepTheirOwnDateRegardlessOfWindowOrder() {
        let reading = AccountReading(status: .connected, checkedAt: .now, windows: [
            QuotaWindow(id: "seven_day", label: "每周", remainingPercent: 75, resetsAt: week),
            QuotaWindow(id: "five_hour", label: "5 小时", remainingPercent: 40, resetsAt: five)
        ])
        let rows = ClaudeResetDeadline.rows(account: account, reading: reading)
        XCTAssertEqual(rows.map(\.label), ["5 小时重置", "每周重置"])
        XCTAssertEqual(rows.map(\.date), [five, week])
    }
    func testMissingFiveHourDateDoesNotUseWeeklyOrReserveAndStaleDatesRemain() {
        let reading = AccountReading(status: .stale, checkedAt: .now, windows: [
            QuotaWindow(id: "five_hour", label: "5 小时", remainingPercent: 100, resetsAt: five, group: "reserve"),
            QuotaWindow(id: "seven_day", label: "每周", remainingPercent: 75, resetsAt: week)
        ])
        XCTAssertEqual(ClaudeResetDeadline.rows(account: account, reading: reading).map(\.date), [nil, week])
        XCTAssertEqual(ClaudeResetDeadline.rows(account: account, reading: AccountReading(status: .unavailable, checkedAt: .now)).map(\.date), [nil, nil])
    }
    func testOtherProvidersDoNotGainClaudeLabelsAndGenericLabelsAreSupported() {
        var codex = account;codex.serviceLabel = "Codex"
        let reading = AccountReading(status: .connected, checkedAt: .now, windows: [QuotaWindow(id: "session", label: "5 小时额度", remainingPercent: 20, resetsAt: five)])
        XCTAssertTrue(ClaudeResetDeadline.rows(account: codex, reading: reading).isEmpty)
        XCTAssertEqual(ClaudeResetDeadline.rows(account: account, reading: reading).first?.date, five)
    }
}
