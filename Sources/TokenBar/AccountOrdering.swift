import Foundation
import TokenBarWidgetShared

extension AccountConfig {
    var orderingSourceID: String { AccountDisplayOrder.sourceID(sourceAccountID) }
    var accountDisplayOrder: AccountDisplayOrder {
        let product: String? = provider == .snapshot ? nil : provider.rawValue
        let key = AccountDisplayOrder.providerKey(product: product, provider: displayService, sourceID: orderingSourceID)
        // A validated catalog can identify a provider even when a legacy
        // display label and arbitrary source ID do not name that provider.
        if key == "other", let displayOrder, displayOrder.isValid { return displayOrder }
        return displayOrder?.resolved(providerKey: key, sourceID: orderingSourceID) ??
            AccountDisplayOrder.fallback(providerKey: key, sourceID: orderingSourceID)
    }
}

extension AppStore {
    var orderedAccounts: [AccountConfig] {
        AccountDisplayOrder.sorted(accounts, order: { $0.accountDisplayOrder }, stableID: { $0.orderingSourceID })
    }
}
