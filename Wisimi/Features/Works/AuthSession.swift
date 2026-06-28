import Foundation
import Combine
import Security

@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var auth: AuthResponse?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    var isLoggedIn: Bool { auth?.token.isEmpty == false }
    var username: String? { auth?.user?.name }
    var token: String? { auth?.token }
    var recommenderUuid: String? { auth?.user?.recommenderUuid }

    private let client: ASMRClient
    private let store = KeychainStore(service: "wisimi.auth", account: "auth")

    init(client: ASMRClient) {
        self.client = client
        auth = try? store.load(AuthResponse.self)
    }

    func login(name: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let auth = try await client.login(name: name, password: password)
            self.auth = auth
            try store.save(auth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        auth = nil
        errorMessage = nil
        try? store.delete()
    }
}

struct AuthResponse: Codable {
    let user: AuthUser?
    let token: String
}

struct AuthUser: Codable {
    let loggedIn: Bool?
    let name: String?
    let group: String?
    let email: String?
    let recommenderUuid: String?
}

private struct KeychainStore {
    let service: String
    let account: String

    func load<T: Decodable>(_ type: T.Type) throws -> T? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ASMRClientError.badResponse
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try delete()

        var query = baseQuery
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ASMRClientError.badResponse }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ASMRClientError.badResponse
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

#if DEBUG
enum AuthSelfCheck {
    static func run() {
        let json = #"{"token":"abc","user":{"name":"demo","loggedIn":true,"recommenderUuid":"uuid"}}"#
        let auth = try? JSONDecoder().decode(AuthResponse.self, from: Data(json.utf8))
        assert(auth?.token == "abc")
        assert(auth?.user?.recommenderUuid == "uuid")
    }
}
#endif
