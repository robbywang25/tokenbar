import Foundation
import XCTest
@testable import TokenBar

final class AppStoreTests: XCTestCase {
    @MainActor
    func testAgentPrefixesDefaultOnGroupOnlySameAccountAndPersistOffWithoutChangingSelections() async throws {
        let fixture = try StoreFixture(showsAgentPrefix: nil)
        defer { fixture.remove() }
        var first = try fixture.snapshot(name: "Legacy Personal Name", accountID: "one", windows: [["id": "weekly", "remainingPercent": 63]], credits: ["remaining": 25_800])
        first.serviceLabel = "codex"
        var second = try fixture.snapshot(name: "Another Personal Name", accountID: "two", windows: [["id": "weekly", "remainingPercent": 12]])
        second.serviceLabel = "CODEX"
        var third = try fixture.snapshot(name: "Third Personal Name", accountID: "three", windows: [["id": "weekly", "remainingPercent": 98]])
        third.serviceLabel = "Grok Build"
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertTrue(store.showsAgentPrefix)
        try await store.connect(first)
        try await store.connect(second)
        try await store.connect(third)
        XCTAssertEqual(store.menuTitle, "Codex 63%")
        let credits = try XCTUnwrap(store.availableMenuMetrics.first(where: { $0.kind == .credits }))
        store.setMenuMetric(credits, enabled: true)
        store.setMenuQuota(accountID: second.id, windowID: "weekly", enabled: true)
        store.setMenuQuota(accountID: third.id, windowID: "weekly", enabled: true)
        store.readings[first.id]?.email = "fixture@example.com"
        XCTAssertEqual(store.menuTitle, "Codex 63% · 25.8k · Codex 12% · Grok 98%")
        XCTAssertFalse(store.menuTitle.contains("fixture@example.com"))
        XCTAssertFalse(store.menuTitle.contains("Personal Name"))
        let selection = store.menuQuotaSelection
        let tooltip = store.menuTooltip
        store.setShowsAgentPrefix(false)
        XCTAssertEqual(store.menuTitle, "63% · 25.8k · 12% · 98%")
        XCTAssertEqual(store.menuQuotaSelection, selection)
        XCTAssertEqual(store.menuTooltip, tooltip)
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertFalse(restored.showsAgentPrefix)
        XCTAssertEqual(restored.menuTitle, "63% · 25.8k · 12% · 98%")
        XCTAssertEqual(restored.menuQuotaSelection, selection)
        restored.setShowsAgentPrefix(true)
        XCTAssertTrue(AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults).showsAgentPrefix)
        restored.now = Date().addingTimeInterval(121)
        XCTAssertEqual(restored.menuTitle, "Codex — · — · Codex — · Grok —")
        for metric in restored.availableMenuMetrics { restored.setMenuMetric(metric, enabled: false) }
        XCTAssertEqual(restored.menuTitle, "—")
    }

    @MainActor
    func testAgentPrefixDemoChangesNeverPersistAndExitRestoresPreference() throws {
        let fixture = try StoreFixture(showsAgentPrefix: nil)
        defer { fixture.remove() }
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        store.loadDemo()
        XCTAssertEqual(store.menuTitle, "Codex 32%")
        store.setShowsAgentPrefix(false)
        XCTAssertEqual(store.menuTitle, "32%")
        XCTAssertNil(fixture.defaults.object(forKey: "showsAgentPrefix.v1"))
        store.exitDemo()
        XCTAssertTrue(store.showsAgentPrefix)
        store.setShowsAgentPrefix(false)
        store.loadDemo()
        store.setShowsAgentPrefix(true)
        XCTAssertFalse(fixture.defaults.bool(forKey: "showsAgentPrefix.v1"))
        store.exitDemo()
        XCTAssertFalse(store.showsAgentPrefix)
        XCTAssertEqual(store.menuTitle, "—")
    }

    @MainActor
    func testExpiryNoticesRequireFreshAuthenticatedNearResetSlowPaceWithSubstantialRemaining() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let now = Date()
        let account = AccountConfig(provider: .codex, name: "Fixture", method: .localFile, location: "/fixture/unused.json")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        store.accounts = [account]
        let window = QuotaWindow(id: "weekly", label: "每周", remainingPercent: 94, resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-601_200))
        let reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [window])
        var variants: [AccountReading] = []
        var stale = reading; stale.lastSuccessAt = now.addingTimeInterval(-121); variants.append(stale)
        var unauthenticated = reading; unauthenticated.status = .needsAuth; variants.append(unauthenticated)
        var little = reading; little.windows[0].remainingPercent = 19; variants.append(little)
        var unknown = reading; unknown.windows[0].remainingPercent = nil; variants.append(unknown)
        var distant = reading; distant.windows[0].resetsAt = now.addingTimeInterval(172_800); variants.append(distant)
        var normalPace = reading
        normalPace.windows[0].remainingPercent = 50
        normalPace.windows[0].startsAt = now.addingTimeInterval(-86_400)
        normalPace.windows[0].resetsAt = now.addingTimeInterval(82_800)
        variants.append(normalPace)
        for variant in variants {
            store.readings[account.id] = variant
            XCTAssertNil(store.takeNextExpiryNotice(at: now))
        }
        store.readings[account.id] = reading
        store.accounts[0].enabled = false
        XCTAssertNil(store.takeNextExpiryNotice(at: now))
        store.accounts[0].enabled = true
        store.isRefreshing = true
        XCTAssertNil(store.takeNextExpiryNotice(at: now))
        store.isRefreshing = false
        XCTAssertNil(fixture.defaults.object(forKey: "expiryNoticeReceipts.v1"))
        XCTAssertNotNil(store.takeNextExpiryNotice(at: now))
    }

    @MainActor
    func testExpiryNoticeOncePerCycleAcrossRestartDisabledAndUnselectedQuotas() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        var account = try fixture.snapshot(name: "Private Fixture Name", accountID: "account-one", windows: [[
            "id": "weekly", "label": "每周", "remainingPercent": 94,
            "startsAt": reset.addingTimeInterval(-604_800).timeIntervalSince1970, "resetsAt": reset.timeIntervalSince1970
        ]])
        account.serviceLabel = "Codex"
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(account)
        XCTAssertTrue(store.expiryAlertsEnabled)
        store.setMenuQuota(accountID: account.id, windowID: "weekly", enabled: false)
        XCTAssertEqual(store.menuTitle, "—")
        let first = try XCTUnwrap(store.takeNextExpiryNotice(at: now))
        XCTAssertEqual(first.accountName, "邮箱待确认")
        XCTAssertEqual(first.serviceLabel, "Codex")
        XCTAssertEqual(first.windowLabel, "每周")
        XCTAssertEqual(first.remainingPercent, 94)
        XCTAssertEqual(first.resetsAt.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertNil(store.takeNextExpiryNotice(at: now))
        let data = try XCTUnwrap(fixture.defaults.data(forKey: "expiryNoticeReceipts.v1"))
        let receipts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(Set(receipts[0].keys), ["id", "resetsAt"])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("Private Fixture Name"))

        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertNil(restored.takeNextExpiryNotice(at: now))
        restored.setExpiryAlertsEnabled(false)
        let disabled = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertFalse(disabled.expiryAlertsEnabled)
        let nextCycle = now.addingTimeInterval(604_800)
        restored.readings[account.id]?.lastSuccessAt = nextCycle
        restored.readings[account.id]?.windows[0].startsAt = nextCycle.addingTimeInterval(-601_200)
        restored.readings[account.id]?.windows[0].resetsAt = nextCycle.addingTimeInterval(3600)
        XCTAssertNil(restored.takeNextExpiryNotice(at: nextCycle))
        restored.setExpiryAlertsEnabled(true)
        let second = try XCTUnwrap(restored.takeNextExpiryNotice(at: nextCycle))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNil(restored.takeNextExpiryNotice(at: nextCycle))
        let newData = try XCTUnwrap(fixture.defaults.data(forKey: "expiryNoticeReceipts.v1"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: newData) as? [[String: Any]])?.count, 1)
    }

    @MainActor
    func testExpiryNoticePrioritizesEarliestResetAndDemoDoesNotConsumeNotice() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let now = Date()
        let account = AccountConfig(provider: .codex, name: "Fixture", method: .localFile, location: "/fixture/unused.json")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        store.loadDemo()
        XCTAssertNil(store.takeNextExpiryNotice(at: now))
        XCTAssertNil(fixture.defaults.object(forKey: "expiryNoticeReceipts.v1"))
        store.exitDemo()
        store.accounts = [account]
        let later = QuotaWindow(id: "later", label: "较晚", remainingPercent: 94, resetsAt: now.addingTimeInterval(7200), startsAt: now.addingTimeInterval(-597_600))
        let earlier = QuotaWindow(id: "earlier", label: "较早", remainingPercent: 94, resetsAt: now.addingTimeInterval(1800), startsAt: now.addingTimeInterval(-603_000))
        store.readings[account.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [later, earlier])
        XCTAssertEqual(store.takeNextExpiryNotice(at: now)?.windowLabel, "较早")
        XCTAssertEqual(store.takeNextExpiryNotice(at: now)?.windowLabel, "较晚")
        XCTAssertNil(store.takeNextExpiryNotice(at: now))
    }

    @MainActor
    func testCreditsMenuDefaultsOffPreservesWindowSelectionAndShowsExactTooltip() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let account = try fixture.snapshot(name: "Personal", accountID: "account-one", credits: ["remaining": 44_681.125])
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(account)
        let creditMetric = try XCTUnwrap(store.availableMenuMetrics.first(where: { $0.kind == .credits }))
        XCTAssertEqual(creditMetric.windowLabel, "剩余点数")
        XCTAssertFalse(store.menuMetricSelected(creditMetric))
        XCTAssertEqual(store.menuTitle, "37%")
        store.setMenuMetric(creditMetric, enabled: true)
        XCTAssertTrue(store.menuQuotaSelected(accountID: account.id, windowID: "weekly"))
        XCTAssertEqual(store.menuTitle, "37% · 44.7k")
        XCTAssertTrue(store.menuTooltip.contains("剩余点数：44681.125 点"))
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertTrue(restored.menuMetricSelected(creditMetric))
        XCTAssertEqual(restored.menuTitle, "37% · 44.7k")
        restored.readings[account.id]?.credits = 0
        XCTAssertEqual(restored.menuTitle, "37% · 0")
        XCTAssertTrue(restored.menuTooltip.contains("剩余点数：0 点"))
        restored.readings[account.id]?.unlimitedCredits = true
        XCTAssertEqual(restored.menuTitle, "37% · ∞")
        XCTAssertTrue(restored.menuTooltip.contains("剩余点数：不限量"))
        restored.now = Date().addingTimeInterval(121)
        XCTAssertEqual(restored.menuTitle, "— · —")
        XCTAssertTrue(restored.menuTooltip.contains("剩余点数：当前未知"))
        restored.remove(account)
        XCTAssertEqual(restored.menuQuotaSelection, [])
        XCTAssertTrue(restored.availableMenuMetrics.isEmpty)
        let removed = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(removed.menuQuotaSelection, [])
        XCTAssertEqual(removed.menuTitle, "—")
    }

    @MainActor
    func testCreditsOnlyMenuRequiresExplicitSelectionAndSurvivesFailedRead() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let account = try fixture.snapshot(name: "Credits", accountID: "account-one", windows: [], credits: ["remaining": 0])
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(account)
        let metric = try XCTUnwrap(store.availableMenuMetrics.first)
        XCTAssertEqual(metric.kind, .credits)
        XCTAssertFalse(store.menuMetricSelected(metric))
        XCTAssertEqual(store.menuTitle, "—")
        store.setMenuMetric(metric, enabled: true)
        XCTAssertEqual(store.menuTitle, "0")
        try Data("invalid JSON fixture".utf8).write(to: URL(fileURLWithPath: account.location))
        await store.refresh()
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertTrue(store.menuMetricSelected(metric))
        XCTAssertEqual(store.availableMenuMetrics, [metric])
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertTrue(restored.menuMetricSelected(metric))
        XCTAssertEqual(restored.availableMenuMetrics, [metric])
        XCTAssertEqual(restored.menuTitle, "—")
    }

    @MainActor
    func testMenuPercentSelectionsPreserveOrderPersistenceAndExplicitEmptyChoice() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let first = try fixture.snapshot(name: "Personal", accountID: "account-one", windows: [
            ["id": "weekly", "label": "每周", "remainingPercent": 0],
            ["id": "reserve", "label": "每周", "remainingPercent": 100, "quotaGroup": "reserve", "model": "example-model"]
        ])
        let second = try fixture.snapshot(name: "Work", accountID: "account-two", windows: [["id": "weekly", "remainingPercent": 94]])
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(first)
        try await store.connect(second)
        XCTAssertNil(store.menuQuotaSelection)
        XCTAssertEqual(store.menuTitle, "0%")
        XCTAssertEqual(store.availableMenuMetrics.count, 2)
        XCTAssertTrue(store.menuQuotaSelected(accountID: first.id, windowID: "weekly"))
        store.setMenuQuota(accountID: second.id, windowID: "weekly", enabled: true)
        store.setMenuQuota(accountID: first.id, windowID: "reserve", enabled: true)
        XCTAssertEqual(store.menuTitle, "0% · 94%")
        XCTAssertFalse(store.menuTooltip.contains("Reserve"))
        XCTAssertFalse(store.menuQuotaSelected(accountID: first.id, windowID: "reserve"))
        XCTAssertEqual(store.readings[first.id]?.windows.map(\.group), ["default", "reserve"])
        XCTAssertFalse(store.menuTooltip.contains("Work"))
        XCTAssertTrue(store.menuTooltip.contains("邮箱待确认"))
        XCTAssertFalse(store.menuTitle.contains("TokenBar"))
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.menuTitle, store.menuTitle)
        XCTAssertEqual(restored.menuQuotaSelection, store.menuQuotaSelection)

        for metric in restored.availableMenuMetrics {
            restored.setMenuQuota(accountID: metric.accountID, windowID: metric.windowID, enabled: false)
        }
        XCTAssertEqual(restored.menuTitle, "—")
        XCTAssertEqual(restored.menuQuotaSelection, [])
        let emptyRestored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(emptyRestored.menuQuotaSelection, [])
        XCTAssertEqual(emptyRestored.menuTitle, "—")
    }

    @MainActor
    func testLegacyReserveSelectionStaysSavedButHiddenAcrossRestartFailureAndVisibleEdits() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let account = try fixture.snapshot(name: "Personal", accountID: "one", windows: [
            ["id": "weekly", "remainingPercent": 42],
            ["id": "reserve", "remainingPercent": 100, "quotaGroup": "reserve"]
        ], credits: ["remaining": 123.5])
        let original = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await original.connect(account)
        let reserveID = MenuQuotaMetric.selectionID(accountID: account.id, windowID: "reserve")
        fixture.defaults.set([reserveID], forKey: "menuQuotaSelection.v1")
        // Simulates a selection saved by a version which exposed Reserve.
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.accounts, [account])
        XCTAssertEqual(restored.menuQuotaSelection, [reserveID])
        XCTAssertEqual(restored.menuTitle, "—")
        XCTAssertEqual(restored.menuTooltip, "未选择菜单栏额度")
        XCTAssertFalse(restored.availableMenuMetrics.contains { $0.group == "reserve" })
        XCTAssertTrue(restored.rememberedMenuMetrics.contains { $0.id == reserveID && $0.group == "reserve" })
        restored.setMenuQuota(accountID: account.id, windowID: "weekly", enabled: true)
        XCTAssertEqual(restored.menuTitle, "42%")
        XCTAssertTrue(restored.menuQuotaSelection?.contains(reserveID) == true)
        let credit = try XCTUnwrap(restored.availableMenuMetrics.first { $0.kind == .credits })
        restored.setMenuMetric(credit, enabled: true)
        XCTAssertEqual(restored.menuTitle, "42% · 123.5")
        let selected = try XCTUnwrap(restored.menuQuotaSelection)
        try Data("invalid fixture".utf8).write(to: URL(fileURLWithPath: account.location))
        await restored.refresh()
        XCTAssertEqual(restored.menuTitle, "— · —")
        XCTAssertFalse(restored.menuTooltip.contains("Reserve"))
        XCTAssertEqual(restored.menuQuotaSelection, selected)
        let afterFailure = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(afterFailure.accounts.map(\.id), [account.id])
        XCTAssertEqual(afterFailure.menuQuotaSelection, selected)
        XCTAssertEqual(afterFailure.menuTitle, "— · —")
        XCTAssertFalse(afterFailure.availableMenuMetrics.contains { $0.group == "reserve" })
        XCTAssertTrue(afterFailure.rememberedMenuMetrics.contains { $0.id == reserveID && $0.group == "reserve" })
        XCTAssertEqual(Set(fixture.defaults.stringArray(forKey: "menuQuotaSelection.v1") ?? []), selected)
    }

    @MainActor
    func testSameWindowChangingToReserveCannotReviveItsRememberedDefaultLabel() async throws {
        for hasPercentage in [true, false] {
            let fixture = try StoreFixture()
            defer { fixture.remove() }
            let account = try fixture.snapshot(name: "Personal", accountID: "one", windows: [["id": "stable-window", "remainingPercent": 37]])
            let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
            try await store.connect(account)
            store.setMenuQuota(accountID: account.id, windowID: "stable-window", enabled: true)
            let selection = store.menuQuotaSelection
            var window: [String: Any] = ["id": "stable-window", "label": "每周", "quotaGroup": "reserve"]
            if hasPercentage { window["remainingPercent"] = 100 }
            else { window["remaining"] = 20; window["unit"] = "tokens" }
            let file = URL(fileURLWithPath: account.location)
            var source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            source["windows"] = [window]
            try JSONSerialization.data(withJSONObject: source).write(to: file)
            await store.refresh()
            XCTAssertEqual(store.readings[account.id]?.windows.first?.group, "reserve")
            XCTAssertTrue(store.availableMenuMetrics.isEmpty)
            XCTAssertEqual(store.menuTitle, "—")
            XCTAssertEqual(store.menuQuotaSelection, selection)
            XCTAssertEqual(store.rememberedMenuMetrics.first?.group, "reserve")
            let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
            XCTAssertEqual(restored.accounts.map(\.id), [account.id])
            XCTAssertEqual(restored.menuQuotaSelection, selection)
            XCTAssertTrue(restored.availableMenuMetrics.isEmpty)
            try Data("invalid fixture".utf8).write(to: file)
            await restored.refresh()
            XCTAssertTrue(restored.availableMenuMetrics.isEmpty)
            XCTAssertEqual(restored.rememberedMenuMetrics.first?.group, "reserve")
            XCTAssertEqual(restored.menuTooltip, "未选择菜单栏额度")
        }
    }

    @MainActor
    func testHiddenReserveDoesNotBecomeDefaultOrUndoExplicitEmptySelection() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let account = try fixture.snapshot(name: "Reserve only", accountID: "one", windows: [["id": "reserve", "remainingPercent": 100, "quotaGroup": "reserve"]])
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(account)
        XCTAssertNil(store.menuQuotaSelection)
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertTrue(store.availableMenuMetrics.isEmpty)
        fixture.defaults.set([String](), forKey: "menuQuotaSelection.v1")
        let empty = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        let other = try fixture.snapshot(name: "Visible", accountID: "two")
        try await empty.connect(other)
        XCTAssertEqual(empty.menuQuotaSelection, [])
        XCTAssertEqual(empty.menuTitle, "—")
        XCTAssertEqual(empty.accounts.map(\.id), [account.id, other.id])
    }

    @MainActor
    func testExpiredReserveCannotBlankWeeklyAndCreditsMenuValues() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let now = Date()
        let account = try fixture.snapshot(name: "Personal", accountID: "one", windows: [
            ["id": "weekly", "remainingPercent": 42, "resetsAt": now.addingTimeInterval(3600).timeIntervalSince1970],
            ["id": "reserve", "remainingPercent": 100, "quotaGroup": "reserve", "resetsAt": now.addingTimeInterval(-1).timeIntervalSince1970]
        ], credits: ["remaining": 56_000])
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(account)
        store.setMenuMetric(try XCTUnwrap(store.availableMenuMetrics.first { $0.kind == .credits }), enabled: true)
        XCTAssertEqual(store.menuTitle, "42% · 56k")
        XCTAssertTrue(store.menuTooltip.contains("56000 点"))
        XCTAssertEqual(store.readings[account.id]?.windows.count, 2)
        store.readings[account.id]?.status = .stale
        XCTAssertEqual(store.menuTitle, "— · —")
    }

    @MainActor
    func testReserveCannotConsumeOrPrioritizeExpiryNotice() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let now = Date()
        let account = AccountConfig(provider: .codex, name: "Fixture", method: .localFile, location: "/fixture/unused.json")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        store.accounts = [account]
        let reserve = QuotaWindow(id: "reserve", label: "每周", remainingPercent: 100,
            resetsAt: now.addingTimeInterval(60), startsAt: now.addingTimeInterval(-604_740), group: "reserve")
        store.readings[account.id] = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [reserve])
        XCTAssertNil(store.takeNextExpiryNotice(at: now))
        XCTAssertNil(fixture.defaults.object(forKey: "expiryNoticeReceipts.v1"))
        let weekly = QuotaWindow(id: "weekly", label: "每周", remainingPercent: 94,
            resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-601_200))
        store.readings[account.id]?.windows.append(weekly)
        let notice = try XCTUnwrap(store.takeNextExpiryNotice(at: now))
        XCTAssertTrue(notice.id.contains("/weekly@"))
        XCTAssertEqual(notice.remainingPercent, 94)
        XCTAssertNil(store.takeNextExpiryNotice(at: now))
        XCTAssertEqual(store.readings[account.id]?.windows.map(\.group), ["reserve", "default"])
    }

    @MainActor
    func testMenuChoicesSurviveStaleFailedReadsAndRemovalCleansPreferences() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let account = try fixture.snapshot(name: "Personal", accountID: "account-one")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(account)
        store.setMenuQuota(accountID: account.id, windowID: "weekly", enabled: true)
        let choices = store.availableMenuMetrics
        XCTAssertEqual(store.menuTitle, "37%")
        store.now = Date().addingTimeInterval(121)
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertTrue(store.menuTooltip.contains("当前未知"))
        try Data("invalid JSON fixture".utf8).write(to: URL(fileURLWithPath: account.location))
        await store.refresh()
        XCTAssertEqual(store.menuTitle, "—")
        XCTAssertEqual(store.availableMenuMetrics, choices)
        XCTAssertTrue(store.menuQuotaSelected(accountID: account.id, windowID: "weekly"))
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.availableMenuMetrics, choices)
        XCTAssertEqual(restored.menuTitle, "—")
        restored.remove(account)
        XCTAssertTrue(restored.availableMenuMetrics.isEmpty)
        XCTAssertEqual(restored.menuQuotaSelection, [])
        XCTAssertEqual(restored.menuTitle, "—")
        let removedRestored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertTrue(removedRestored.availableMenuMetrics.isEmpty)
        XCTAssertEqual(removedRestored.menuQuotaSelection, [])
    }

    @MainActor
    func testConnectPersistsPrivateFilesAndReloadsOnlyConfiguredAccounts() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(config)
        XCTAssertEqual(store.accounts, [config])
        XCTAssertEqual(store.readings[config.id]?.windows.first?.remainingPercent, 37)
        for file in ["accounts.json", "readings.json"] {
            let values = try FileManager.default.attributesOfItem(atPath: fixture.state.appendingPathComponent(file).path)
            XCTAssertEqual((values[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let directoryValues = try FileManager.default.attributesOfItem(atPath: fixture.state.path)
        XCTAssertEqual((directoryValues[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        var cache = store.readings
        let orphanID = UUID()
        cache[orphanID] = AccountReading(status: .connected, checkedAt: Date(), lastSuccessAt: Date())
        try JSONEncoder().encode(cache).write(to: fixture.state.appendingPathComponent("readings.json"))
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.accounts, [config])
        XCTAssertEqual(restored.readings[config.id], store.readings[config.id])
        XCTAssertNil(restored.readings[orphanID])
    }

    @MainActor
    func testDifferentSnapshotAliasesCannotDuplicateOneProviderIdentity() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let first = try fixture.snapshot(name: "First", accountID: "same-account")
        let second = try fixture.snapshot(name: "Alias", accountID: "same-account")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(first)
        do { try await store.connect(second); XCTFail("Expected duplicate identity rejection") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }
        XCTAssertEqual(store.accounts, [first])
        XCTAssertEqual(store.readings.count, 1)
        let restored = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        XCTAssertEqual(restored.accounts, [first])
    }

    @MainActor
    func testDifferentSSHHostsCanConnectSamePathAndSourceAccountID() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let document = try JSONSerialization.data(withJSONObject: ["id": "quota", "status": "connected", "lastSuccessAt": Date().timeIntervalSince1970, "windows": [["remainingPercent": 37]]])
        let client = ProviderClient(sshReader: { _ in document })
        let store = AppStore(directory: fixture.state, client: client, startTimers: false, defaults: fixture.defaults)
        let suffix = UUID().uuidString
        let first = AccountConfig(provider: .snapshot, name: "Host A", method: .snapshotSSH, location: "/srv/quota.json", sourceAccountID: "quota", sshHost: "fixture-a-" + suffix)
        let second = AccountConfig(provider: .snapshot, name: "Host B", method: .snapshotSSH, location: "/srv/quota.json", sourceAccountID: "quota", sshHost: "fixture-b-" + suffix)
        try await store.connect(first)
        try await store.connect(second)
        XCTAssertEqual(store.accounts, [first, second])
        XCTAssertNotEqual(store.readings[first.id]?.identityKey, store.readings[second.id]?.identityKey)
        var duplicate = first
        duplicate.id = UUID()
        do { try await store.connect(duplicate); XCTFail("Same SSH source must remain deduplicated") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }
    }

    @MainActor
    func testOneHTTPSEndpointCanDistinguishAccountsByBearerAndStableIdentity() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove(); StoreURLProtocol.handler = nil }
        let first = AccountConfig(provider: .snapshot, name: "Personal", method: .snapshotURL, location: "https://quota.example.test/usage")
        let second = AccountConfig(provider: .snapshot, name: "Work", method: .snapshotURL, location: first.location)
        let duplicate = AccountConfig(provider: .snapshot, name: "Duplicate", method: .snapshotURL, location: first.location)
        let tokens = [first.id.uuidString: "fixture-personal", second.id.uuidString: "fixture-work", duplicate.id.uuidString: "fixture-personal"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreURLProtocol.self]
        let client = ProviderClient(sessionConfiguration: configuration, credentialReader: { _, account in
            guard let token = tokens[account ?? ""] else { throw ProviderError.needsAuth }
            return Data(token.utf8)
        })
        let base: [String: Any] = ["id": "quota", "status": "connected", "lastSuccessAt": Date().timeIntervalSince1970, "windows": [["remainingPercent": 37]]]
        var bodies: [String: Data] = [:]
        for token in ["fixture-personal", "fixture-work"] {
            var object = base
            object["identity"] = ["provider": "example", "accountID": token]
            bodies["Bearer " + token] = try JSONSerialization.data(withJSONObject: object)
        }
        StoreURLProtocol.handler = { proto in
            proto.complete(data: bodies[proto.request.value(forHTTPHeaderField: "Authorization") ?? ""]!)
        }
        let store = AppStore(directory: fixture.state, client: client, startTimers: false, defaults: fixture.defaults)
        try await store.connect(first)
        try await store.connect(second)
        XCTAssertEqual(store.accounts, [first, second])
        do { try await store.connect(duplicate); XCTFail("A matching provider identity must still be rejected") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }

        // Without a distinguishable identity, different Bearers must not imply
        // separate balances at a shared endpoint/account ID.
        let fallbackData = try JSONSerialization.data(withJSONObject: base)
        StoreURLProtocol.handler = { $0.complete(data: fallbackData) }
        let fallbackStore = AppStore(directory: fixture.directory.appendingPathComponent("fallback-state"), client: client, startTimers: false, defaults: fixture.defaults)
        try await fallbackStore.connect(first)
        do { try await fallbackStore.connect(second); XCTFail("Ambiguous source identity must stay deduplicated") }
        catch { XCTAssertEqual(error as? ProviderError, .duplicate) }
        XCTAssertEqual(fallbackStore.accounts, [first])
    }

    @MainActor
    func testFailedConfigurationSaveDoesNotPartiallyConnectAccount() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        // A regular file at the storage directory blocks creation without
        // changing filesystem permissions or any production configuration.
        try Data("fixture".utf8).write(to: fixture.state)
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        do { try await store.connect(config); XCTFail("Expected save failure") }
        catch { /* The observable state must remain transactional on any storage error. */ }
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.state), "fixture")
    }

    @MainActor
    func testRefreshFailureDoesNotReplayPreviousPositiveBalance() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let config = try fixture.snapshot(name: "Primary", accountID: "account-one")
        let store = AppStore(directory: fixture.state, startTimers: false, defaults: fixture.defaults)
        try await store.connect(config)
        try Data("invalid JSON fixture".utf8).write(to: URL(fileURLWithPath: config.location))
        await store.refresh()
        XCTAssertEqual(store.readings[config.id]?.status, .unavailable)
        XCTAssertNil(store.readings[config.id]?.lastSuccessAt)
        XCTAssertTrue(store.readings[config.id]?.windows.isEmpty == true)
        XCTAssertNil(store.readings[config.id]?.identityKey)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.lastRefresh)
    }

    @MainActor
    func testInFlightRefreshCannotOverwriteNewDemoRevision() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove(); StoreURLProtocol.handler = nil }
        let requestStarted = expectation(description: "Fixture request started")
        var pending: StoreURLProtocol?
        StoreURLProtocol.handler = { proto in pending = proto; requestStarted.fulfill() }
        let config = try fixture.codex()
        let store = AppStore(directory: fixture.state, client: mockClient(), startTimers: false, defaults: fixture.defaults)
        store.accounts = [config]
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [requestStarted], timeout: 5)
        store.loadDemo()
        let demoIDs = store.accounts.map(\.id)
        pending?.complete()
        await refresh.value
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.accounts.map(\.id), demoIDs)
        XCTAssertEqual(Set(store.readings.keys), Set(demoIDs))
        XCTAssertNil(store.readings[config.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testOverlappingRefreshesShareOneProviderRequest() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove(); StoreURLProtocol.handler = nil }
        let requestStarted = expectation(description: "Fixture request started")
        var pending: StoreURLProtocol?
        var requests = 0
        StoreURLProtocol.handler = { proto in requests += 1; pending = proto; requestStarted.fulfill() }
        let config = try fixture.codex()
        let store = AppStore(directory: fixture.state, client: mockClient(), startTimers: false, defaults: fixture.defaults)
        store.accounts = [config]
        let old = Date().addingTimeInterval(-600)
        store.now = old
        store.readings[config.id] = AccountReading(status: .connected, checkedAt: old, lastSuccessAt: old, windows: [QuotaWindow(id: "quota", label: "额度", remainingPercent: 70)])
        let first = Task { await store.refresh() }
        await fulfillment(of: [requestStarted], timeout: 5)
        XCTAssertGreaterThan(store.now, old.addingTimeInterval(590))
        XCTAssertEqual(store.readings[config.id]?.displayStatus(at: store.now), .stale)
        XCTAssertEqual(store.menuTitle, "—")
        store.now = old
        await store.refresh()
        XCTAssertGreaterThan(store.now, old.addingTimeInterval(590))
        XCTAssertEqual(requests, 1)
        pending?.complete()
        await first.value
        XCTAssertEqual(store.readings[config.id]?.status, .connected)
        XCTAssertFalse(store.isRefreshing)
    }

    private func mockClient() -> ProviderClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreURLProtocol.self]
        return ProviderClient(sessionConfiguration: configuration, credentialReader: { _, _ in throw ProviderError.needsAuth })
    }
}

private struct StoreFixture {
    let directory: URL
    let defaults: UserDefaults
    private let defaultsSuite: String
    var state: URL { directory.appendingPathComponent("state") }

    init(showsAgentPrefix: Bool? = false) throws {
        defaultsSuite = "TokenBarTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsSuite)!
        if let showsAgentPrefix { defaults.set(showsAgentPrefix, forKey: "showsAgentPrefix.v1") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-AppStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    func remove() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
    func snapshot(name: String, accountID: String, windows: [[String: Any]] = [["id": "weekly", "remainingPercent": 37]], credits: [String: Any]? = nil) throws -> AccountConfig {
        let file = directory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        var object: [String: Any] = ["id": name, "status": "connected", "lastSuccessAt": Date().timeIntervalSince1970,
                                    "identity": ["provider": "codex", "accountID": accountID], "windows": windows]
        if let credits { object["credits"] = credits }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return AccountConfig(provider: .snapshot, name: name, method: .snapshotFile, location: file.path)
    }
    func codex() throws -> AccountConfig {
        let file = directory.appendingPathComponent("credential-fixture.json")
        try Data(#"{"tokens":{"access_token":"fake-fixture-credential","account_id":"test-account"}}"#.utf8).write(to: file)
        return AccountConfig(provider: .codex, name: "Fixture", method: .localFile, location: file.path)
    }
}

private final class StoreURLProtocol: URLProtocol {
    static var handler: ((StoreURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func complete(data: Data = Data(#"{"account_id":"test-account","rate_limit":{"primary_window":{"used_percent":30}}}"#.utf8)) {
        guard let client, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }
}
