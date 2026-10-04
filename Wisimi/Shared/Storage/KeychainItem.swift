import Foundation
import Security

/// Byte storage only; callers own encoding and credential validation.
struct KeychainItem {
    let service: String
    let account: String
    var accessibility: CFString? = nil
    var synchronizable: Bool? = nil
    var operations = KeychainOperations.live

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw KeychainError(status: status) }
        return data
    }

    func save(_ data: Data) throws {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let accessibility { attributes[kSecAttrAccessible as String] = accessibility }
        let status = operations.update(baseQuery, attributes)
        if status == errSecItemNotFound {
            let added = operations.add(baseQuery.merging(attributes) { _, new in new })
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let synchronizable { query[kSecAttrSynchronizable as String] = synchronizable }
        return query
    }
}

/// Internal seam for Security calls, including errors that depend on signing and device state.
struct KeychainOperations {
    var read: ([String: Any]) -> (OSStatus, Data?)
    var update: ([String: Any], [String: Any]) -> OSStatus
    var add: ([String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static let live = Self(
        read: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法访问本机 Keychain" }
}
