import Foundation
import Security

struct OpenRouterTokenStore {
    private let item: KeychainItem

    init(service: String = "wisimi.openrouter", account: String = "api-token", operations: KeychainOperations = .live) {
        item = KeychainItem(service: service, account: account,
                            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, synchronizable: false,
                            operations: operations)
    }

    var isConfigured: Bool { (try? load())?.isEmpty == false }

    func load() throws -> String? {
        guard let data = try mapped({ try item.load() }) else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw OpenRouterTokenStoreError.keychain(errSecDecode)
        }
        return token
    }

    func prepareForBackgroundAccess() throws {
        // Update the existing item while unlocked, without asking for the token again.
        try mapped {
            if let data = try item.load() { try item.save(data) }
        }
    }

    func save(_ token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw OpenRouterTokenStoreError.emptyToken }
        try mapped { try item.save(Data(normalized.utf8)) }
    }

    func delete() throws { try mapped { try item.delete() } }

    private func mapped<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as KeychainError { throw OpenRouterTokenStoreError.keychain(error.status) }
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


