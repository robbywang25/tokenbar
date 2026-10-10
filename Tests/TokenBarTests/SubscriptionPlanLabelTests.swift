import XCTest
@testable import TokenBar

final class SubscriptionPlanLabelTests: XCTestCase {
    func testObservedTierCompatibleMultipliersMatchTokensCardLabels() {
        for (tier, multiplier) in [(100, 5), (100, 10), (200, 10), (200, 20), (500, 25)] {
            XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro \(tier)", multiplier: multiplier, isCodex: true), "Pro \(multiplier)x")
        }
    }

    func testMissingAndConflictingMultipliersUseOnlyConfirmedFallback() {
        for multiplier: Int? in [nil, 20, 25, 50, 0, -1] {
            XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro 100", multiplier: multiplier, isCodex: true), "Pro 100")
        }
        for multiplier: Int? in [nil, 5, 25, 50, 0, -1] {
            XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro 200", multiplier: multiplier, isCodex: true), "Pro 200")
        }
        for multiplier: Int? in [nil, 5, 10, 20, 25, 50, 0, -1] {
            XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro 500", multiplier: multiplier, isCodex: true), "Pro 25x")
        }
    }

    func testOtherProductsAndPriceLikeTextDoNotAcquireCodexMultiplier() {
        for name in ["ChatGPT Pro 500", "ChatGPT Pro 200", "Claude Pro", "SuperGrok Heavy", "Cursor Pro"] {
            XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: name, multiplier: 20, isCodex: false), name)
        }
        for name in ["USD 500/month", "Pro 500", "Unknown 200"] {
            XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: name, multiplier: 25, isCodex: true), name)
        }
        XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro 999", multiplier: 20, isCodex: true), "Pro 999")
        XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro", multiplier: 20, isCodex: true), "Pro")
    }

    func testAlreadyFormattedNamesAndExactPlanMatchingRemainStable() {
        XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro 25x", multiplier: 50, isCodex: true), "Pro 25x")
        XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "Pro 20x", multiplier: 25, isCodex: true), "Pro 20x")
        XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "ChatGPT Pro 200 ", multiplier: 20, isCodex: true), "Pro 200 ")
        XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: "chatgpt pro 500", multiplier: 25, isCodex: true), "chatgpt pro 500")
    }

    func testMissingAndBlankPlanNamesAreSafe() {
        for name: String? in [nil, "", "   ", "\n\t"] {
            for isCodex in [true, false] {
                XCTAssertNil(SubscriptionPlanLabel.displayName(planName: name, multiplier: 25, isCodex: isCodex))
            }
        }
    }

    func testLegacyCachedReadingDecodesAndRawPlanSurvivesFormatting() throws {
        let now = Date(timeIntervalSince1970: 1_791_633_600)
        let legacy: [String: Any] = ["status": "connected", "checkedAt": now.timeIntervalSinceReferenceDate,
                                    "lastSuccessAt": now.timeIntervalSinceReferenceDate, "windows": [],
                                    "unlimitedCredits": false, "resetCards": [], "detail": "", "planName": "ChatGPT Pro 200"]
        var reading = try JSONDecoder().decode(AccountReading.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(reading.planMultiplier)
        XCTAssertEqual(reading.planName, "ChatGPT Pro 200")
        reading.planMultiplier = 20
        XCTAssertEqual(SubscriptionPlanLabel.displayName(planName: reading.planName, multiplier: reading.planMultiplier, isCodex: true), "Pro 20x")
        XCTAssertEqual(reading.planName, "ChatGPT Pro 200")
        XCTAssertEqual(try JSONDecoder().decode(AccountReading.self, from: JSONEncoder().encode(reading)), reading)
    }
}
