import XCTest
@testable import TokenBar

final class ResetCalendarTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func account(_ name: String = "first@example.test", enabled: Bool = true) -> AccountConfig {
        AccountConfig(provider: .snapshot, name: name, method: .snapshotFile,
                      location: "/synthetic.json", enabled: enabled, serviceLabel: "Codex")
    }
    private func window(_ id: String = "weekly", reset: Date?) -> QuotaWindow {
        QuotaWindow(id: id, label: "每周", remainingPercent: 42, resetsAt: reset)
    }
    private func reading(_ windows: [QuotaWindow], status: ReadingStatus = .connected) -> AccountReading {
        AccountReading(status: status, checkedAt: now, lastSuccessAt: now, windows: windows)
    }
    private func model(_ accounts: [AccountConfig], _ readings: [UUID: AccountReading], at: Date? = nil) -> ResetCalendarModel {
        ResetCalendarModel(accounts: accounts, readings: readings, now: at ?? now, identity: { $0.name })
    }
    private func calendar(_ zone: String = "Asia/Singapore") -> Calendar {
        ResetCalendarDates.calendar(timeZone: TimeZone(identifier: zone)!)
    }

    func testVisibleWindowsRetainDistinctAccountsGroupsModelsAndResetInstants() {
        let first = account(), second = account("second@example.test")
        let reset = now.addingTimeInterval(86_400)
        let weekly = window(reset: reset)
        var additional = weekly; additional.group = "additional"; additional.model = "model-a"
        var reserve = weekly; reserve.group = "reserve"
        var later = weekly; later.resetsAt = reset.addingTimeInterval(3600)
        let result = model([first, first, second], [first.id: reading([weekly, weekly, additional, reserve, later]),
                                                 second.id: reading([weekly])])
        XCTAssertEqual(result.events.count, 4)
        XCTAssertEqual(Set(result.events.map(\.id)).count, 4)
        XCTAssertTrue(result.events.allSatisfy { $0.status == .scheduled })
        XCTAssertTrue(result.events.contains { $0.windowLabel == "附加 · 每周 · model-a" })
        XCTAssertEqual(result.events.last?.resetsAt, later.resetsAt)
        XCTAssertEqual(result.events.filter { $0.accountName == second.name }.count, 1)
    }

    func testUnknownDatesAndUnconfiguredAccountsStayMissingNotInvented() {
        let first = account(), missing = account("missing"), disabled = account("disabled", enabled: false)
        var reserve = window(reset: nil); reserve.group = "reserve"
        let result = model([first, missing, disabled], [first.id: reading([window(reset: nil), reserve])])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.missingAccounts, 1)
        XCTAssertEqual(result.missingWindows, 1)
        XCTAssertEqual(result.missingLabel, "1 个账号、1 项额度未提供日期")
    }

    func testResetCardsAndCreditsAreNotQuotaResetEvents() {
        let first = account()
        var value = reading([])
        value.credits = 100
        value.resetCardsAvailable = 1
        value.resetCards = [ResetCard(status: "available", expiresAt: now.addingTimeInterval(3600))]
        let result = model([first], [first.id: value])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.missingAccounts, 1)
    }

    func testInvalidDatesAreNotPlacedOnCalendar() {
        let first = account()
        let dates = [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .infinity),
                     Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 253_402_300_800)]
        let result = model([first], [first.id: reading(dates.enumerated().map { window("\($0.offset)", reset: $0.element) })])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.missingWindows, dates.count)
    }

    func testExpiredResetDoesNotClaimResetSucceededOrPredictAnotherCycle() {
        let first = account()
        let result = model([first], [first.id: reading([window(reset: now)])])
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.status, .expired)
        XCTAssertEqual(result.events.first?.status.label, "已过期")
        XCTAssertEqual(result.events.first?.resetsAt, now)
        XCTAssertEqual(result.summary(in: result.events), "本月 1 项重置")
    }

    func testAuthenticationAndSourceFreshnessCannotBeRenewedByReadingCache() {
        let first = account()
        for status in [ReadingStatus.stale, .needsAuth, .unavailable, .notConfigured, .unsupported] {
            let result = model([first], [first.id: reading([window(reset: now.addingTimeInterval(3600))], status: status)])
            XCTAssertEqual(result.events.first?.status, .stale)
        }
        var value = reading([window(reset: now.addingTimeInterval(3600))])
        value.sourceCollectedAtPresent = true
        XCTAssertEqual(model([first], [first.id: value]).events.first?.status, .stale)
        value.sourceCollectedAt = now.addingTimeInterval(-121)
        XCTAssertEqual(model([first], [first.id: value]).events.first?.status, .stale)
        value.sourceCollectedAt = now
        XCTAssertEqual(model([first], [first.id: value]).events.first?.status, .scheduled)
        XCTAssertEqual(model([first], [first.id: value], at: now.addingTimeInterval(121)).events.first?.status, .stale)
        value.sourceCollectedAt = now.addingTimeInterval(61)
        XCTAssertEqual(model([first], [first.id: value]).events.first?.status, .stale)
    }

    func testOneInstantMovesBetweenCivilDaysAcrossTimeZones() {
        let first = account(), instant = date("2026-10-16T00:30:00Z")
        let result = model([first], [first.id: reading([window(reset: instant)])])
        let sg = calendar(), la = calendar("America/Los_Angeles")
        XCTAssertEqual(sg.component(.day, from: instant), 16)
        XCTAssertEqual(la.component(.day, from: instant), 15)
        XCTAssertEqual(result.events(on: date("2026-10-16T04:00:00Z"), calendar: sg).count, 1)
        XCTAssertTrue(result.events(on: date("2026-10-16T19:00:00Z"), calendar: la).isEmpty)
        XCTAssertEqual(result.events(on: date("2026-10-15T19:00:00Z"), calendar: la).count, 1)
    }

    func testMonthSummaryUsesSelectedTimeZoneAndExcludesNextMonthBoundary() {
        let first = account(), reset = date("2026-11-01T00:00:00Z")
        let result = model([first], [first.id: reading([window(reset: reset)])])
        XCTAssertTrue(result.events(inMonth: now, calendar: calendar("UTC")).isEmpty)
        XCTAssertEqual(result.events(inMonth: now, calendar: calendar("America/Los_Angeles")).count, 1)
    }

    func testMonthGridAlwaysHasSixMondayFirstWeeksIncludingLeapDay() {
        let cal = calendar()
        let days = ResetCalendarDates.monthDays(containing: date("2024-02-15T12:00:00Z"), calendar: cal)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(cal.component(.weekday, from: days[0]), 2)
        XCTAssertEqual(days.filter { cal.component(.month, from: $0) == 2 }.count, 29)
        XCTAssertEqual(Set(days).count, 42)
    }

    func testDSTMonthsKeepEveryLocalDayExactlyOnce() {
        let cal = calendar("America/Los_Angeles")
        for instant in ["2026-03-15T12:00:00Z", "2026-11-15T12:00:00Z"] {
            let days = ResetCalendarDates.monthDays(containing: date(instant), calendar: cal)
            XCTAssertEqual(days.count, 42)
            for index in 1..<days.count {
                XCTAssertEqual(cal.dateComponents([.day], from: days[index - 1], to: days[index]).day, 1)
                XCTAssertEqual(cal.component(.hour, from: days[index]), 0)
            }
            XCTAssertTrue(zip(days, days.dropFirst()).contains { $1.timeIntervalSince($0) != 86_400 })
        }
    }

    func testMonthNavigationClampsDayAndCrossesYear() {
        let cal = calendar("UTC")
        let feb = ResetCalendarDates.movingMonth(date("2024-01-31T12:00:00Z"), by: 1, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: feb), 2)
        XCTAssertEqual(cal.component(.day, from: feb), 29)
        let previous = ResetCalendarDates.movingMonth(now, by: -10, calendar: cal)
        XCTAssertEqual(cal.component(.year, from: previous), 2025)
        XCTAssertEqual(cal.component(.month, from: previous), 12)
    }

    func testFreshRefreshReplacesOldDateWithoutKeepingPhantomEvents() {
        let first = account(), reset = now.addingTimeInterval(3600)
        var value = reading([window(reset: reset)])
        let old = model([first], [first.id: value], at: now.addingTimeInterval(121))
        XCTAssertEqual(old.events.first?.status, .stale)
        value.windows[0].resetsAt = reset.addingTimeInterval(86_400 * 7)
        value.lastSuccessAt = now.addingTimeInterval(121)
        let updated = model([first], [first.id: value], at: now.addingTimeInterval(121))
        XCTAssertEqual(updated.events.count, 1)
        XCTAssertEqual(updated.events.first?.status, .scheduled)
        XCTAssertNotEqual(updated.events.first?.id, old.events.first?.id)
        XCTAssertFalse(updated.events.contains { $0.resetsAt == reset })
    }

    func testMonthlySummaryCountsOnlyFutureStaleResets() {
        let first = account()
        let past = window("weekly", reset: now)
        let future = window("daily", reset: now.addingTimeInterval(3_600))
        let result = model([first], [first.id: reading([past, future])])
        XCTAssertEqual(result.events.map(\.status), [.expired, .stale])
        XCTAssertEqual(result.summary(in: result.events), "本月 2 项重置，1 项待核实")
        XCTAssertEqual(result.summary(in: []), "本月暂无已知重置")
        let scheduled = model([first], [first.id: reading([future])])
        XCTAssertEqual(scheduled.summary(in: scheduled.events), "本月 1 项重置")
    }

    func testHistoryRemainsWhenTheCurrentReadingHasNoWindowsAndLabelChangesDoNotDuplicate() {
        let first = account(), disabled = account("disabled", enabled: false)
        let past = now.addingTimeInterval(-3_600), future = now.addingTimeInterval(86_400)
        var history = ResetCalendarHistory()
        history.accounts[first.id] = .init(sourceSignature: AccountEmail.sourceSignature(first),
            pending: [QuotaResetRecord(id: "daily", label: "每日", group: "default", resetsAt: future)],
            archived: [QuotaResetRecord(id: "weekly", label: "旧标签", group: "default", resetsAt: past)])
        history.accounts[disabled.id] = history.accounts[first.id]
        var reading = self.reading([window("weekly", reset: past)])
        reading.windows[0].label = "新标签"
        reading.resetHistory = [QuotaResetRecord(id: "weekly", label: "服务端标签", group: "default", resetsAt: past)]
        let outage = AccountReading(status: .unavailable, checkedAt: now, detail: "暂时无法连接数据来源，请检查网络后重试。")
        let merged = ResetCalendarModel(accounts: [first], readings: [first.id: reading], history: history, now: now, identity: { $0.name })
        XCTAssertEqual(merged.events.count, 2)
        XCTAssertEqual(merged.events.first?.windowLabel, "新标签")
        XCTAssertEqual(merged.events.first?.status, .expired)
        XCTAssertEqual(merged.events.last?.status, .stale)
        let hidden = ResetCalendarModel(accounts: [first, disabled], readings: [first.id: outage], history: history, now: now, identity: { $0.name })
        XCTAssertEqual(hidden.events.map(\.resetsAt), [past, future])
        XCTAssertEqual(hidden.missingAccounts, 1)
        XCTAssertTrue(ResetCalendarModel(accounts: [disabled], readings: [:], history: history, now: now, identity: { $0.name }).events.isEmpty)
        XCTAssertFalse(history.accounts[disabled.id]?.archived.isEmpty ?? true)
    }
}
