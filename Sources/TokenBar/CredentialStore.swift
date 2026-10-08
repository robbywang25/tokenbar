import Foundation
import Security
import LocalAuthentication

enum CredentialStore {
    static let serviceName = "wang.robby.tokenbar.credentials"

    static func read(service: String, account: String? = nil) throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Polling must never repeatedly interrupt the user with access prompts.
            kSecUseAuthenticationContext as String: context
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw ProviderError.needsAuth }
        return data
    }

    static func save(_ data: Data, service: String = serviceName, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ProviderError.needsAuth }
        } else if status != errSecSuccess { throw ProviderError.needsAuth }
    }

    static func delete(service: String = serviceName, account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
