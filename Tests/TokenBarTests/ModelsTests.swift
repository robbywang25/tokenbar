import XCTest
@testable import TokenBar

final class ModelsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testMenuAgentPrefixUsesProductLabelsAndBoundsSafeCustomNames() {
        for (provider, expected): (ProviderKind, String) in [(.codex, "Codex"), (.claude, "Claude"), (.grok, "Grok")] {
            let account = AccountConfig(provider: provider, name: "Legacy Personal Name", method: .localFile, location: "", serviceLabel: "person@example.com")
            XCTAssertEqual(account.menuAgentPrefix, expected)
        }
        let mappings = ["OpenAI": "OpenAI", "ChatGPT": "ChatGPT", "OpenAI Codex": "Codex", " cOdEx ": "Codex", "Claude Code": "Claude", "ANTHROPIC": "Anthropic",
                        "Grok Build": "Grok", "x.AI": "xAI", "grok-bot": "GrokBot", "  CURSOR ": "Cursor",
                        "  QA   Agent  ": "QA Agent", "abcdefghijkl": "abcdefgh…", "开发智能助手工具平台": "开发智能助手工具…",
                        "E\u{301}quipeAI": "ÉquipeAI"]
        for (label, expected) in mappings {
            let account = AccountConfig(provider: .snapshot, name: "Legacy Personal Name", method: .snapshotFile, location: "", serviceLabel: label)
            XCTAssertEqual(account.menuAgentPrefix, expected)
        }
        for label: String? in [nil, "", "   ", "person@example.com", "https://example.com", "Agent\nOther", "Agent\tOther", "Agent\u{0}Other"] {
            let account = AccountConfig(provider: .snapshot, name: "Never Use Legacy Name", method: .snapshotFile, location: "", serviceLabel: label)
            XCTAssertEqual(account.menuAgentPrefix, "JSON")
        }
    }

    func testLegacyCachedReadingDecodesWithoutNewContractFields() throws {
        let legacy: [String: Any] = ["status": "connected", "checkedAt": now.timeIntervalSinceReferenceDate,
                                    "lastSuccessAt": now.timeIntervalSinceReferenceDate, "windows": [],
                                    "unlimitedCredits": false, "resetCards": [], "detail": ""]
        let reading = try JSONDecoder().decode(AccountReading.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(reading.planName)
        XCTAssertNil(reading.sourceCollectedAt)
        XCTAssertNil(reading.sourceCollectedAtPresent)
        XCTAssertNil(reading.reason)
        XCTAssertNil(reading.retryAt)
        XCTAssertTrue(reading.isFresh(at: now))
    }

    func testSourceFreshnessSurvivesCacheRoundTripAndCannotBeOverriddenByRecentSuccess() throws {
        var reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now)
        reading.sourceCollectedAtPresent = true
        XCTAssertFalse(reading.isFresh(at: now))
        for source in [now.addingTimeInterval(-121), now.addingTimeInterval(61)] {
            reading.sourceCollectedAt = source
            XCTAssertFalse(reading.isFresh(at: now))
        }
        reading.sourceCollectedAt = now
        XCTAssertTrue(reading.isFresh(at: now))
        reading.sourceCollectedAt = nil
        let restored = try JSONDecoder().decode(AccountReading.self, from: JSONEncoder().encode(reading))
        XCTAssertEqual(restored.sourceCollectedAtPresent, true)
        XCTAssertFalse(restored.isFresh(at: now))
        XCTAssertEqual(restored.displayStatus(at: now), .stale)
    }

    func testLegacyMenuMetricPreferencesDecodeAndCreditsCannotCollideWithWindows() throws {
        let accountID = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["accountID": accountID.uuidString, "windowID": "credits", "accountName": "Personal", "windowLabel": "每周", "group": "default"])
        let legacy = try JSONDecoder().decode(MenuQuotaMetric.self, from: data)
        XCTAssertNil(legacy.kind)
        XCTAssertEqual(legacy.id, accountID.uuidString + "/credits")
        let credits = MenuQuotaMetric(accountID: accountID, windowID: "", accountName: "Personal", windowLabel: "剩余点数", group: "credits", kind: .credits)
        XCTAssertNotEqual(credits.id, legacy.id)
        XCTAssertNotEqual(credits.id, MenuQuotaMetric.selectionID(accountID: accountID, windowID: "#credits"))
        XCTAssertEqual(try JSONDecoder().decode(MenuQuotaMetric.self, from: JSONEncoder().encode(credits)), credits)
    }

    func testFreshnessNeverPromotesExpiredOrFutureReadings() {
        var reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now)
        XCTAssertTrue(reading.isFresh(at: now))
        reading.lastSuccessAt = now.addingTimeInterval(-121)
        XCTAssertFalse(reading.isFresh(at: now))
        XCTAssertEqual(reading.displayStatus(at: now), .stale)
        reading.lastSuccessAt = now.addingTimeInterval(61)
        XCTAssertFalse(reading.isFresh(at: now))
        reading.lastSuccessAt = now
        reading.windows = [QuotaWindow(id: "w", label: "每周", remainingPercent: 50, resetsAt: now)]
        XCTAssertFalse(reading.isFresh(at: now))
        reading.windows = []; reading.status = .needsAuth
        XCTAssertFalse(reading.isFresh(at: now))
        XCTAssertEqual(reading.displayStatus(at: now), .needsAuth)
    }

    func testReserveIsHiddenWithoutChangingRawWindowsCreditsCardsOrEncoding() throws {
        let windows = [
            QuotaWindow(id: "default", label: "每周", remainingPercent: 35),
            QuotaWindow(id: "reserve", label: "每周", remainingPercent: 100, group: "reserve", model: "Luna"),
            QuotaWindow(id: "review", label: "每周", remainingPercent: 75, group: "code-review"),
            QuotaWindow(id: "extra", label: "5 小时", remainingPercent: 90, group: "additional")
        ]
        var reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: windows,
            credits: 123.5, resetCardsAvailable: 0, resetCards: [ResetCard(status: "available", expiresAt: now.addingTimeInterval(3600))])
        XCTAssertEqual(reading.visibleWindows.map(\.id), ["default", "review", "extra"])
        XCTAssertEqual(reading.windows, windows)
        XCTAssertEqual(try JSONDecoder().decode(AccountReading.self, from: JSONEncoder().encode(reading)), reading)
        reading.windows = [windows[1]]
        XCTAssertTrue(reading.visibleWindows.isEmpty)
        XCTAssertTrue(reading.hasVisibleSupplementalQuota)
        XCTAssertTrue(reading.hasVisibleQuota)
        XCTAssertEqual(reading.credits, 123.5)
        XCTAssertEqual(reading.resetCardsAvailable, 0)
        reading.credits = nil; reading.resetCardsAvailable = nil
        XCTAssertFalse(reading.hasVisibleQuota)
        reading.unlimitedCredits = true
        XCTAssertTrue(reading.hasVisibleQuota)
    }

    func testExpiredReserveDoesNotExpireVisibleQuotasOrChangeExplicitSourceStatus() {
        let primary = QuotaWindow(id: "weekly", label: "每周", remainingPercent: 42, resetsAt: now.addingTimeInterval(3600))
        let reserve = QuotaWindow(id: "reserve", label: "每周", remainingPercent: 100, resetsAt: now, group: "reserve")
        var reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [primary, reserve], credits: 100)
        XCTAssertTrue(reading.isFresh(at: now))
        XCTAssertEqual(reading.displayStatus(at: now), .connected)
        XCTAssertEqual(reading.windows[1].resetsAt, now)
        reading.windows[0].resetsAt = now
        XCTAssertFalse(reading.isFresh(at: now))
        reading.windows = [reserve]
        XCTAssertTrue(reading.isFresh(at: now))
        for status: ReadingStatus in [.stale, .needsAuth, .unavailable, .notConfigured, .unsupported] {
            reading.status = status
            XCTAssertFalse(reading.isFresh(at: now))
            XCTAssertEqual(reading.displayStatus(at: now), status)
        }
        reading.status = .connected; reading.lastSuccessAt = now.addingTimeInterval(-121)
        XCTAssertFalse(reading.isFresh(at: now))
    }

    func testReserveCannotProducePacingOrResetAlert() {
        let reserve = QuotaWindow(id: "reserve", label: "每周", remainingPercent: 94,
            resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-601200), group: "reserve")
        XCTAssertNil(reserve.alert(at: now))
        var primary = reserve; primary.group = "default"
        XCTAssertEqual(primary.alert(at: now), "即将重置")
    }

    func testUnknownAndZeroAreDistinct() {
        let unknown = QuotaWindow(id: "a", label: "额度", remainingPercent: nil)
        let zero = QuotaWindow(id: "b", label: "额度", remainingPercent: 0)
        XCTAssertEqual(unknown.displayValue, "未提供")
        XCTAssertEqual(zero.displayValue, "0%")
    }

    func testPacingOnlyAppliesToDefinedLongWindows() {
        var window = QuotaWindow(id: "w", label: "每周", remainingPercent: 94,
            resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-601200))
        XCTAssertEqual(window.alert(at: now), "即将重置")
        window.resetsAt = now.addingTimeInterval(172800)
        XCTAssertEqual(window.alert(at: now), "使用偏慢")
        window.startsAt = nil
        XCTAssertNil(window.alert(at: now))
        window.startsAt = now.addingTimeInterval(-14400); window.resetsAt = now.addingTimeInterval(3600)
        XCTAssertNil(window.alert(at: now))
    }

    @MainActor func testDemoDoesNotWriteAccountsOrCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TokenBarModelsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "showsAgentPrefix.v1")
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(directory: directory, startTimers: false, defaults: defaults)
        store.loadDemo()
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertEqual(store.menuTitle, "32%")
        let metric = try XCTUnwrap(store.availableMenuMetrics.last)
        store.setMenuQuota(accountID: metric.accountID, windowID: metric.windowID, enabled: true)
        XCTAssertEqual(store.menuTitle, "32% · 94%")
        XCTAssertNil(defaults.object(forKey: "menuQuotaSelection.v1"))
        XCTAssertNil(defaults.object(forKey: "menuQuotaMetrics.v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        store.exitDemo()
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertEqual(store.menuTitle, "—")
    }
}
