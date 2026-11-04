import Foundation
import XCTest
import TokenBarWidgetShared
@testable import TokenBar

final class AccountOrderingTests: XCTestCase {
    private func account(_ id: String, _ label: String) -> AccountConfig {
        AccountConfig(provider: .snapshot, name: label, method: .snapshotFile,
            location: "/tmp/synthetic.json", sourceAccountID: id, serviceLabel: label)
    }

    func testProviderAndAccountWeightsIgnoreInputOrderAndUUIDs() {
        let accounts = [account("gemini-web-2", "Gemini"), account("today-global", "TodayAI 全球版"),
            account("codex-2", "Codex"), account("grok-bot", "Grok Bot"), account("claude-2", "Claude"),
            account("cursor", "Cursor"), account("gemini-web", "Gemini"), account("claude-1", "Claude"),
            account("grok", "Grok Build"), account("today-cn", "TodayAI 中国版"), account("codex-1", "Codex")]
        let expected = ["codex-1", "codex-2", "claude-1", "claude-2", "grok", "grok-bot", "cursor",
                        "today-cn", "today-global", "gemini-web", "gemini-web-2"]
        for offset in accounts.indices {
            let shuffled = Array(accounts[offset...] + accounts[..<offset])
            XCTAssertEqual(sorted(shuffled).map(\.sourceAccountID), expected)
        }
        XCTAssertEqual(sorted(accounts.reversed()).map(\.sourceAccountID), expected)
    }

    func testCustomProviderWeightMovesWholeGroupAndConflictsFallBack() {
        var first = account("gemini-web", "Gemini"), second = account("gemini-web-2", "Gemini")
        first.displayOrder = .init(providerKey: "google", providerWeight: 50, accountWeight: 20)
        second.displayOrder = .init(providerKey: "google", providerWeight: 50, accountWeight: 10)
        let codex = account("codex-1", "Codex")
        XCTAssertEqual(sorted([codex, first, second]).map(\.sourceAccountID), ["gemini-web-2", "gemini-web", "codex-1"])
        second.displayOrder?.providerWeight = 1000
        XCTAssertEqual(sorted([first, codex, second]).map(\.sourceAccountID), ["codex-1", "gemini-web-2", "gemini-web"])
        first.displayOrder?.providerKey = "openai"
        XCTAssertEqual(first.accountDisplayOrder.providerKey, "google")
    }

    func testParsingRejectsMalformedMetadataWithoutDroppingQuotaOrSourceID() throws {
        let fallback = AccountDisplayOrder.fallback(providerKey: "google", sourceID: "gemini-web-2")
        for bad: [String: Any] in [
            ["version": 2, "providerKey": "google", "providerWeight": 50, "accountWeight": 10],
            ["version": true, "providerKey": "google", "providerWeight": 50, "accountWeight": 10],
            ["version": 1, "providerKey": "google", "providerWeight": -1, "accountWeight": 10],
            ["version": 1, "providerKey": "google", "providerWeight": 50, "accountWeight": 0.5],
            ["version": 1, "providerKey": "xai", "providerWeight": 50, "accountWeight": 10]
        ] { XCTAssertEqual(AccountDisplayOrder.parse(bad, providerKey: "google", sourceID: "gemini-web-2"), fallback) }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "accounts": [[
            "id": "gemini-web-2", "product": "gemini-web", "provider": "Google", "status": "not_configured",
            "windows": [], "displayOrder": ["version": 1, "providerKey": "google", "providerWeight": 50, "accountWeight": 10]
        ]]])
        let entry = try XCTUnwrap(SnapshotCatalog.parse(data, source: "fixture", at: Date()).entries.first)
        XCTAssertEqual(entry.id, "gemini-web-2")
        XCTAssertEqual(entry.displayOrder?.providerWeight, 50)
        XCTAssertEqual(entry.displayOrder?.accountWeight, 10)
    }

    func testLegacyConfigsAndGodPrefixedIDsHaveDeterministicFallback() throws {
        let legacy = account("god:gemini-web-2", "Gemini")
        XCTAssertEqual(legacy.orderingSourceID, "gemini-web-2")
        XCTAssertEqual(legacy.accountDisplayOrder.accountWeight, 200)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "displayOrder")
        let restored = try JSONDecoder().decode(AccountConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.id, legacy.id)
        XCTAssertEqual(restored.accountDisplayOrder, legacy.accountDisplayOrder)
        let left = account("unknown-a", "Unknown"), right = account("unknown-A", "Unknown")
        XCTAssertEqual(sorted([left, right]).map(\.sourceAccountID), ["unknown-A", "unknown-a"])
    }

    func testMultiAccountWidgetOrderIgnoresUrgencyWhileSingleAccountRankingRemainsAvailable() {
        let now = Date()
        func widget(_ key: String, _ weight: Int, _ accountWeight: Int) -> TokenBarWidgetAccount {
            .init(id: UUID(), email: nil, provider: key, plan: nil, status: .unavailable,
                observedAt: nil, freshUntil: nil, metrics: [], displayOrder: .init(providerKey: key, providerWeight: weight, accountWeight: accountWeight))
        }
        let second = widget("google", 600, 200), codex = widget("openai", 100, 100), first = widget("google", 600, 100)
        let snapshot = TokenBarWidgetSnapshot(generatedAt: now, accounts: [second, codex, first])
        XCTAssertEqual(snapshot.displayOrderedAccounts().map(\.id), [codex.id, first.id, second.id])
        XCTAssertEqual(snapshot.rankedAccounts(at: now).map(\.id), [second.id, codex.id, first.id])
    }

    func testGodSyncRecordAndPortableSnapshotKeepOrderingMetadata() throws {
        var account = self.account("gemini-web-2", "Gemini")
        account.displayOrder = .init(providerKey: "google", providerWeight: 50, accountWeight: 10)
        let reading = AccountReading(status: .stale, checkedAt: Date(), lastSuccessAt: nil)
        let record = try GodSyncProjection.record(account: account, key: "god:gemini-web-2", reading: reading)
        XCTAssertEqual(record["displayOrder"]?["providerKey"]?.string, "google")
        let portable = try GodSyncProjection.portableAccount(record)
        XCTAssertEqual(portable["displayOrder"], record["displayOrder"])
    }

    private func sorted<S: Sequence>(_ values: S) -> [AccountConfig] where S.Element == AccountConfig {
        AccountDisplayOrder.sorted(Array(values), order: { $0.accountDisplayOrder }, stableID: { $0.orderingSourceID })
    }
}
