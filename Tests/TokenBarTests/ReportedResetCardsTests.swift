import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class ReportedResetCardsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func report(provenance: String = "official-web", observed: Date? = nil) -> [String: Any] {
        ["available": 3, "detailsAt": iso(observed ?? now), "provenance": provenance,
         "cards": [["status": "available", "expiresAt": iso(now.addingTimeInterval(3600)),
                    "startsAt": iso(now.addingTimeInterval(-3600)), "grantedAt": iso(now.addingTimeInterval(-7200)),
                    "resetType": "five_hour"]]]
    }

    private func parse(_ report: Any, native: Any? = nil, product: String = "claude") throws -> AccountReading {
        var raw: [String: Any] = ["status": "connected", "product": product,
                                  "lastSuccessAt": iso(now), "sourceCollectedAt": iso(now),
                                  "windows": [["id": "weekly", "remainingPercent": 65]],
                                  "reportedResetCredits": report]
        if let native { raw["resetCredits"] = native }
        return try ProviderClient.parseSnapshot(JSONSerialization.data(withJSONObject: raw), at: now)
    }

    func testReportedObservationRetainsTypeDatesAndNeverBecomesNativeQuota() throws {
        let reading = try parse(report())
        let reported = try XCTUnwrap(reading.reportedResetCards)
        XCTAssertEqual(reported.available, 3)
        XCTAssertEqual(reported.detailsAt, now)
        XCTAssertEqual(reported.provenance, .officialWeb)
        XCTAssertEqual(reported.cards.first?.resetType, "five_hour")
        XCTAssertEqual(reported.cards.first?.displayTitle, "5 小时重置卡")
        XCTAssertEqual(reported.cards.first?.startsAt, now.addingTimeInterval(-3600))
        XCTAssertEqual(reported.cards.first?.grantedAt, now.addingTimeInterval(-7200))
        XCTAssertNil(reading.resetCardsAvailable)
        XCTAssertTrue(reading.resetCards.isEmpty)
        XCTAssertFalse(reading.hasVisibleSupplementalQuota)
        XCTAssertEqual(reading.windows.count, 1)
        XCTAssertEqual(ReportedResetCards.forDisplay(reading: reading), reported)
        let restored = try JSONDecoder().decode(AccountReading.self, from: JSONEncoder().encode(reading))
        XCTAssertEqual(restored.reportedResetCards, reported)
    }

    func testNativeCardsTakePrecedenceEvenWhenNativeAggregateIsZero() throws {
        for count in [0, 2] {
            let reading = try parse(report(), native: ["available": count, "cards": []])
            XCTAssertEqual(reading.resetCardsAvailable, count)
            XCTAssertEqual(reading.reportedResetCards?.available, 3, "Keep the dated observation without displaying it as native data.")
            XCTAssertNil(ReportedResetCards.forDisplay(reading: reading))
        }
    }

    func testOfficialAgeAndOwnerConfirmationUseOnlyTheirOwnObservationTime() throws {
        let fresh = try XCTUnwrap(try parse(report()).reportedResetCards)
        XCTAssertEqual(fresh.observationState(at: now.addingTimeInterval(300)), .officialFresh)
        XCTAssertEqual(fresh.observationState(at: now.addingTimeInterval(301)), .officialHistorical)
        let old = try XCTUnwrap(try parse(report(observed: now.addingTimeInterval(-3600))).reportedResetCards)
        XCTAssertEqual(old.sourceLabel(at: now), "官网上次记录")
        var unknownRaw = report(); unknownRaw.removeValue(forKey: "detailsAt")
        let unknown = try XCTUnwrap(try parse(unknownRaw).reportedResetCards)
        XCTAssertNil(unknown.detailsAt, "Current native timestamps cannot supply a missing report timestamp.")
        XCTAssertEqual(unknown.observationState(at: now), .officialUnknown)
        let future = try XCTUnwrap(try parse(report(observed: now.addingTimeInterval(60))).reportedResetCards)
        XCTAssertEqual(future.observationState(at: now), .officialUnknown)
        let owner = try XCTUnwrap(try parse(report(provenance: "owner-confirmed")).reportedResetCards)
        XCTAssertEqual(owner.observationState(at: now), .ownerConfirmed)
        XCTAssertEqual(owner.observationState(at: now.addingTimeInterval(86_400)), .ownerConfirmed)
        XCTAssertEqual(owner.sourceLabel(at: now), "本人确认 · 待自动核验")
    }

    func testExpiredReportedCardsAreHiddenWithoutRewritingOriginalObservation() throws {
        var raw = report()
        raw["cards"] = [
            ["status": "available", "expiresAt": iso(now), "resetType": "full"],
            ["status": "expired", "expiresAt": NSNull(), "resetType": "weekly"],
            ["status": "unknown", "expiresAt": NSNull()]
        ] as [[String: Any]]
        let report = try XCTUnwrap(try parse(raw).reportedResetCards)
        let display = report.availability(at: now)
        XCTAssertEqual(display.availableCount, 2)
        XCTAssertEqual(display.visibleCards.map(\.index), [2])
        XCTAssertEqual(report.available, 3)
        XCTAssertEqual(report.cards.count, 3)
    }

    func testMalformedOptionalReportDoesNotRejectNativeBalance() throws {
        var variants: [[String: Any]] = []
        for mutation: Any in [true, -1, 1.5, "3", 1_000_001] {
            var raw = report(); raw["available"] = mutation; variants.append(raw)
        }
        var raw = report(); raw["provenance"] = "inferred"; variants.append(raw)
        raw = report(); raw["detailsAt"] = "2026-02-30T10:00:00Z"; variants.append(raw)
        raw = report(); raw["cards"] = Array(repeating: ["status": "available"], count: 101); variants.append(raw)
        for malformedCard: [String: Any] in [
            ["status": "available", "expiresAt": false],
            ["status": "available", "startsAt": "tomorrow"],
            ["status": "available", "grantedAt": 123],
            ["status": "available", "resetType": "everything"],
            ["status": "not-a-card"]
        ] {
            raw = report(); raw["cards"] = [malformedCard]; variants.append(raw)
        }
        for variant in variants {
            let reading = try parse(variant, native: ["available": 4])
            XCTAssertNil(reading.reportedResetCards)
            XCTAssertEqual(reading.resetCardsAvailable, 4)
            XCTAssertEqual(reading.windows[0].remainingPercent, 65)
        }
        XCTAssertNil(try parse(report(), product: "gemini-api").reportedResetCards)
    }

    func testNativeCardMetadataStaysLocalAndOutOfStrictGodSyncSchema() throws {
        let card: [String: Any] = ["status": "available", "expiresAt": iso(now.addingTimeInterval(3600)),
                                   "startsAt": iso(now.addingTimeInterval(600)), "grantedAt": iso(now), "resetType": "weekly"]
        let reading = try parse(report(), native: ["available": 1, "cards": [card]])
        let native = try XCTUnwrap(reading.resetCards.first)
        XCTAssertEqual(native.displayTitle, "每周重置卡")
        XCTAssertEqual(native.startsAt, now.addingTimeInterval(600))
        XCTAssertEqual(ResetCardAvailability(reading: reading, at: now).availableCount, 1,
                       "Do not infer aggregate applicability from a newly available metadata field.")
        let projected = try GodSyncProjection.reading(reading)
        XCTAssertNil(projected["reportedResetCards"])
        let cards = try XCTUnwrap(projected["resetCards"]?.array)
        let object = try XCTUnwrap(cards.first?.object)
        XCTAssertEqual(Set(object.keys), ["status", "expiresAt"])
        XCTAssertNil(object["startsAt"])
        XCTAssertNil(object["grantedAt"])
        XCTAssertNil(object["resetType"])
        XCTAssertEqual(reading.resetCards.first?.resetType, "weekly")
    }

    @MainActor
    func testReportedCardsNeverEnterWidgetOrMenuSelections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-ReportedCards-\(UUID().uuidString)")
        let suite = "TokenBar.ReportedCards." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root, startTimers: false, defaults: defaults)
        let account = AccountConfig(provider: .snapshot, name: "Synthetic", method: .snapshotFile,
                                    location: "/fixture/unused.json", serviceLabel: "Claude Code")
        store.accounts = [account]
        store.readings[account.id] = try parse(report())
        let snapshot = try XCTUnwrap(store.widgetSnapshot(at: now))
        try snapshot.validate()
        XCTAssertNil(snapshot.accounts[0].resetCards)
        XCTAssertNil(snapshot.accounts[0].resetCardExpirations)
        XCTAssertNil(snapshot.accounts[0].resetCardsLabel(at: now))
        XCTAssertEqual(store.availableMenuMetrics.map(\.windowID), ["weekly"])
    }
}
