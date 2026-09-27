import Foundation
import Security

struct OpenRouterTokenStore {
    private let service: String
    private let account: String

    init(service: String = "wisimi.openrouter", account: String = "api-token") {
        self.service = service
        self.account = account
    }

    var isConfigured: Bool {
        (try? load())?.isEmpty == false
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw OpenRouterTokenStoreError.keychain(status)
        }
        return token
    }

    func save(_ token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw OpenRouterTokenStoreError.emptyToken }
        try delete()

        var query = baseQuery
        query[kSecValueData as String] = Data(normalized.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw OpenRouterTokenStoreError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenRouterTokenStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

enum OpenRouterTokenStoreError: LocalizedError {
    case emptyToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyToken: "Token 不能为空"
        case .keychain: "无法访问本机 Keychain"
        }
    }
}

#if DEBUG
enum OpenRouterTokenStoreSelfCheck {
    static func run() {
        let store = OpenRouterTokenStore(service: "wisimi.openrouter.self-check.\(UUID().uuidString)")
        defer { try? store.delete() }
        assert(store.isConfigured == false)
        do {
            try store.save("self-check-first")
            assert(store.isConfigured)
            try store.save("self-check-replaced")
            assert(store.isConfigured)
            try store.delete()
            assert(store.isConfigured == false)
        } catch OpenRouterTokenStoreError.keychain(let status) where status == errSecMissingEntitlement {
            // Unsigned simulator builds do not have an application identifier or
            // Keychain access group. Signed builds still exercise the integration.
            return
        } catch {
            assertionFailure("OpenRouter Keychain self-check failed")
        }
    }
}
#endif
