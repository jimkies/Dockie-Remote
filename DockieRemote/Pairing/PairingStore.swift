import Foundation
import Security

/// Keeps the one saved PC as a single Keychain item.
enum PairingStore {
    private static let service = "dockie.remote.pairing"
    private static let account = "pc"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> SavedPC? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedPC.self, from: data)
    }

    @discardableResult
    static func save(_ pc: SavedPC) -> Bool {
        guard let data = try? JSONEncoder().encode(pc) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func forget() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
