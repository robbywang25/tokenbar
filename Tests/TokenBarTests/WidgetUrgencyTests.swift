import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class WidgetUrgencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_763_200)

    func testNewFiveHourQuotaIsNormalDespiteLargeDailyPercentage() throws {
        let window = QuotaUrgencyWindow(label: "5 小时", remainingPercent: 100, startsAt: now, resetsAt: now.addingTimeInterval(18_000))
        let value = try XCTUnwrap(QuotaUrgency.evaluate(window: window, at: now, isFresh: true))
        XCTAssertEqual(value.requiredDailyPercent, 480, accuracy: 0.000001)
        XCTAssertEqual(value.normalDailyPercent, 480, accuracy: 0.000001)
        XCTAssertEqual(value.paceRatio, 1, accuracy: 0.000001)
        XCTAssertEqual(value.level, .normal)
    }

    func testLevelsDescribeRequiredUsagePaceRatherThanNearExhaustion() throws {
        let priority = try XCTUnwrap(evaluate(percent: 75, daysLeft: 3))
        XCTAssertEqual(priority.requiredDailyPercent, 25, accuracy: 0.000001)
        XCTAssertEqual(priority.normalDailyPercent, 100.0 / 7, accuracy: 0.000001)
        XCTAssertEqual(priority.paceRatio, 1.75, accuracy: 0.000001)
        XCTAssertEqual(priority.level.title, "优先")
        let urgent = try XCTUnwrap(evaluate(percent: 80, daysLeft: 2))
        XCTAssertEqual(urgent.requiredDailyPercent, 40, accuracy: 0.000001)
        XCTAssertEqual(urgent.paceRatio, 2.8, accuracy: 0.000001)
        XCTAssertEqual(urgent.level.title, "紧急")
        XCTAssertEqual(evaluate(percent: 75, daysLeft: 3.5)?.level, .priority)
        XCTAssertEqual(evaluate(percent: 100, daysLeft: 3.5)?.level, .urgent)
        XCTAssertEqual(evaluate(percent: 74.99, daysLeft: 3.5)?.level, .normal)
        XCTAssertEqual(evaluate(percent: 5, daysLeft: 2)?.level, .normal)
    }

    func testInvalidZeroStaleFutureAndExpiredInputsDoNotProduceLiveUrgency() {
        let valid = weekly(percent: 80, daysLeft: 2)
        XCTAssertNil(QuotaUrgency.evaluate(window: valid, at: now, isFresh: false))
        for percent in [0, -1, 101, Double.nan, Double.infinity] {
            var window = valid; window.remainingPercent = percent
            XCTAssertNil(QuotaUrgency.evaluate(window: window, at: now, isFresh: true))
        }
        var window = valid; window.startsAt = now.addingTimeInterval(1)
        XCTAssertNil(QuotaUrgency.evaluate(window: window, at: now, isFresh: true))
        window = valid; window.resetsAt = now
        XCTAssertNil(QuotaUrgency.evaluate(window: window, at: now, isFresh: true))
        window = valid; window.startsAt = window.resetsAt
        XCTAssertNil(QuotaUrgency.evaluate(window: window, at: now, isFresh: true))
        window = valid; window.startsAt = window.resetsAt.addingTimeInterval(-(366 * 86_400 + 1))
        XCTAssertNil(QuotaUrgency.evaluate(window: window, at: now, isFresh: true))
        window = QuotaUrgencyWindow(label: "short", remainingPercent: 100, startsAt: now, resetsAt: now.addingTimeInterval(0.5))
        XCTAssertNil(QuotaUrgency.evaluate(window: window, at: now, isFresh: true))
        window.resetsAt = now.addingTimeInterval(1)
        XCTAssertEqual(QuotaUrgency.evaluate(window: window, at: now, isFresh: true)?.level, .normal)
        window = valid; window.resetsAt = now.addingTimeInterval(0.000001)
        let nearBoundary = QuotaUrgency.evaluate(window: window, at: now, isFresh: true)
        XCTAssertTrue(nearBoundary?.requiredDailyPercent.isFinite == true)
        XCTAssertTrue(nearBoundary?.paceRatio.isFinite == true)
    }

    func testPrimaryCyclePrefersLongestIncludingZeroInsteadOfFallingBackToFiveHours() throws {
        let short = QuotaUrgencyWindow(label: "5 小时", remainingPercent: 100, startsAt: now.addingTimeInterval(-14_400), resetsAt: now.addingTimeInterval(3600))
        let long = weekly(percent: 0, daysLeft: 2)
        let selected = try XCTUnwrap(QuotaUrgency.primaryWindow(from: [short, long], at: now, isFresh: true))
        XCTAssertEqual(selected, long)
        XCTAssertNil(QuotaUrgency.evaluate(window: selected, at: now, isFresh: true))
        XCTAssertNil(QuotaUrgency.primaryWindow(from: [short, long], at: now, isFresh: false))
        var invalidLong = long; invalidLong.startsAt = now.addingTimeInterval(1)
        XCTAssertEqual(QuotaUrgency.primaryWindow(from: [invalidLong, short], at: now, isFresh: true), short)
    }

    func testPrimaryCycleTiesUseSeverityDailyRateResetThenSourceOrder() throws {
        var priority = weekly(percent: 50, daysLeft: 2); priority.label = "priority"
        var urgent = weekly(percent: 40, daysLeft: 1); urgent.label = "urgent"
        XCTAssertEqual(QuotaUrgency.primaryWindow(from: [priority, urgent], at: now, isFresh: true), urgent)
        var later = weekly(percent: 80, daysLeft: 2); later.label = "later"
        var earlier = weekly(percent: 60, daysLeft: 1.5); earlier.label = "earlier"
        XCTAssertEqual(QuotaUrgency.primaryWindow(from: [later, earlier], at: now, isFresh: true), earlier)
        var same = earlier; same.label = "same"
        XCTAssertEqual(QuotaUrgency.primaryWindow(from: [same, earlier], at: now, isFresh: true), same)
    }

    func testAccountRankingUsesSeverityDailyRateResetAndStableExistingOrder() {
        let unknown = row(label: "unknown", window: nil)
        let normal = row(label: "normal", window: weekly(percent: 5, daysLeft: 2))
        let priority = row(label: "priority", window: weekly(percent: 75, daysLeft: 3))
        let urgent = row(label: "urgent", window: weekly(percent: 80, daysLeft: 2))
        let earlier = row(label: "earlier", window: weekly(percent: 60, daysLeft: 1.5))
        let tied = row(label: "tied", window: weekly(percent: 60, daysLeft: 1.5))
        var stale = row(label: "stale", window: weekly(percent: 100, daysLeft: 0.5))
        stale.status = .stale; stale.observedAt = now.addingTimeInterval(-3_601); stale.freshUntil = nil
        let snapshot = TokenBarWidgetSnapshot(generatedAt: now, accounts: [unknown, normal, priority, urgent, tied, earlier, stale])
        XCTAssertEqual(snapshot.rankedAccounts(at: now).map(\.id), [tied.id, earlier.id, urgent.id, priority.id, normal.id, unknown.id, stale.id])
        XCTAssertEqual(snapshot.accounts.map(\.id), [unknown.id, normal.id, priority.id, urgent.id, tied.id, earlier.id, stale.id])
        XCTAssertEqual(snapshot.rankedAccounts(at: now.addingTimeInterval(120)).map(\.id), [tied.id, earlier.id, urgent.id, priority.id, normal.id, unknown.id, stale.id])
        XCTAssertEqual(snapshot.rankedAccounts(at: now.addingTimeInterval(3_600)).map(\.id), snapshot.accounts.map(\.id))
    }

    func testThresholdTimelineBoundariesAreWithinFreshLifetimeAndRecomputeLevels() throws {
        let window = QuotaUrgencyWindow(label: "短周期", remainingPercent: 100, startsAt: now.addingTimeInterval(-20), resetsAt: now.addingTimeInterval(100))
        var account = row(label: "Fixture", window: window)
        account.freshUntil = now.addingTimeInterval(100)
        var snapshot = TokenBarWidgetSnapshot(generatedAt: now, accounts: [account])
        let dates = snapshot.urgencyBoundaryDates(after: now, before: now.addingTimeInterval(900))
        XCTAssertEqual(dates.count, 3)
        for (date, seconds) in zip(dates, [20.0, 40, 100]) { XCTAssertEqual(date.timeIntervalSince(now), seconds, accuracy: 0.000001) }
        XCTAssertEqual(account.urgency(at: dates[0])?.level, .priority)
        XCTAssertEqual(account.urgency(at: dates[1])?.level, .urgent)
        XCTAssertNil(account.urgency(at: dates[2]))
        snapshot.accounts[0].freshUntil = now.addingTimeInterval(30)
        XCTAssertEqual(snapshot.urgencyBoundaryDates(after: now, before: now.addingTimeInterval(900)).count, 1)
        XCTAssertTrue(snapshot.urgencyBoundaryDates(after: now.addingTimeInterval(30), before: now.addingTimeInterval(900)).isEmpty)
    }

    func testLegacySharedJSONAndOptionalWindowValidation() throws {
        let legacy = TokenBarWidgetSnapshot(generatedAt: now, accounts: [row(label: "Fixture", window: nil)])
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)!.contains("urgencyWindow"))
        let decoded = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: encoded)
        try decoded.validate()
        XCTAssertNil(decoded.accounts[0].urgencyWindow)
        XCTAssertNil(decoded.accounts[0].urgency(at: now))
        var snapshot = TokenBarWidgetSnapshot(generatedAt: now, accounts: [row(label: "Fixture", window: weekly(percent: 0, daysLeft: 2))])
        XCTAssertNoThrow(try snapshot.validate())
        snapshot.accounts[0].urgencyWindow?.remainingPercent = 101
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.accounts[0].urgencyWindow = weekly(percent: 80, daysLeft: 2)
        snapshot.accounts[0].urgencyWindow?.label = "/private/source"
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.accounts[0].urgencyWindow = weekly(percent: 80, daysLeft: 2)
        snapshot.accounts[0].status = .unavailable
        snapshot.accounts[0].observedAt = nil
        snapshot.accounts[0].freshUntil = nil
        XCTAssertThrowsError(try snapshot.validate())
    }

    @MainActor
    func testProjectionUsesOnlyDefaultDeclaredCycleIndependentOfMetricTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-Urgency-\(UUID().uuidString)")
        let suite = "TokenBar.UrgencyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root, startTimers: false, defaults: defaults)
        let config = AccountConfig(provider: .snapshot, name: "Never displayed", method: .snapshotFile, location: "/fixture/unused.json")
        store.accounts = [config]
        var windows = (0..<3).map { index in
            QuotaWindow(id: "short-\(index)", label: "5 小时", remainingPercent: 100,
                        resetsAt: now.addingTimeInterval(18_000), startsAt: now)
        }
        windows += [
            QuotaWindow(id: "weekly", label: "每周", remainingPercent: 80, resetsAt: now.addingTimeInterval(172_800), startsAt: now.addingTimeInterval(-432_000)),
            QuotaWindow(id: "reserve", label: "Reserve", remainingPercent: 100, resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-2_588_400), group: "reserve"),
            QuotaWindow(id: "review", label: "代码审查", remainingPercent: 100, resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-2_588_400), group: "code-review"),
            QuotaWindow(id: "unlimited", label: "Unlimited", remainingPercent: 100, resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-2_588_400), unlimited: true)
        ]
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: windows, credits: 25)
        var snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        XCTAssertEqual(snapshot.accounts[0].urgencyWindow?.label, "每周")
        XCTAssertEqual(snapshot.accounts[0].urgency(at: now)?.level, .urgent)
        XCTAssertFalse(snapshot.accounts[0].metrics.contains(where: { $0.label == "每周" }))
        store.readings[config.id]?.windows[3].remainingPercent = 0
        snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        XCTAssertEqual(snapshot.accounts[0].urgencyWindow?.label, "每周")
        XCTAssertNil(snapshot.accounts[0].urgency(at: now))
        store.readings[config.id]?.status = .needsAuth
        let historical = try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0]
        XCTAssertEqual(historical.urgencyWindow?.label, "每周")
        XCTAssertNil(historical.urgency(at: now))
        XCTAssertEqual(historical.status, .needsAuth)
        store.readings[config.id]?.status = .connected
        store.readings[config.id]?.windows = [QuotaWindow(id: "no-start", label: "每周", remainingPercent: 80, resetsAt: now.addingTimeInterval(3600))]
        XCTAssertNil(try XCTUnwrap(store.widgetSnapshot(at: now)).accounts[0].urgencyWindow)
    }

    private func weekly(percent: Double, daysLeft: Double) -> QuotaUrgencyWindow {
        let reset = now.addingTimeInterval(daysLeft * 86_400)
        return QuotaUrgencyWindow(label: "每周", remainingPercent: percent, startsAt: reset.addingTimeInterval(-604_800), resetsAt: reset)
    }

    private func evaluate(percent: Double, daysLeft: Double) -> QuotaUrgencyAssessment? {
        QuotaUrgency.evaluate(window: weekly(percent: percent, daysLeft: daysLeft), at: now, isFresh: true)
    }

    private func row(label: String, window: QuotaUrgencyWindow?) -> TokenBarWidgetAccount {
        TokenBarWidgetAccount(id: UUID(), email: nil, provider: label, plan: nil, status: .connected,
                              observedAt: now, freshUntil: now.addingTimeInterval(120), metrics: [], urgencyWindow: window)
    }
}
