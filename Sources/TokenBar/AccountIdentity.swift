import Foundation
import CryptoKit

enum AccountEmail {
    static func validated(_ value: String?) -> String? {
        guard let value, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let email = value.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, email.count <= 254,
              email.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,63}$", options: .regularExpression) != nil else { return nil }
        return email
    }

    static func sourceSignature(_ account: AccountConfig) -> String {
        let fields = [account.provider.rawValue, account.method.rawValue, account.location,
                      account.sourceAccountID, account.sshHost ?? "", account.sshUseSudo == true ? "sudo" : "user"]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Display metadata only. A saved email does not make an old balance current.
struct RememberedAccountEmail: Codable, Equatable {
    var email: String
    var sourceSignature: String
    var identityKey: String?
}
