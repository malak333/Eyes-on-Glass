import Foundation
import Security

final class KeychainHelper {
    static let standard = KeychainHelper()
    private init() {}

    func save(_ data: Data, service: String, account: String) {
        let query = [
            kSecValueData: data,
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary

        SecItemAdd(query, nil)
    }

    func save(_ string: String, service: String, account: String) {
        guard let data = string.data(using: .utf8) else { return }
        
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary
        
        let status = SecItemCopyMatching(query, nil)
        
        if status == errSecSuccess {
            // Item exists, update it
            let attributesToUpdate = [kSecValueData: data] as CFDictionary
            SecItemUpdate(query, attributesToUpdate)
        } else if status == errSecItemNotFound {
            // Item doesn't exist, insert it
            save(data, service: service, account: account)
        }
    }

    func read(service: String, account: String) -> Data? {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ] as CFDictionary

        var result: AnyObject?
        SecItemCopyMatching(query, &result)
        return (result as? Data)
    }

    func read(service: String, account: String) -> String? {
        let data: Data? = read(service: service, account: account)
        guard let unwrappedData = data else { return nil }
        return String(data: unwrappedData, encoding: .utf8)
    }

    func delete(service: String, account: String) {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary

        SecItemDelete(query)
    }
}
