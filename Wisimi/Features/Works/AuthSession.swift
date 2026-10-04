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
    private let store = KeychainItem(service: "wisimi.auth", account: "auth")

    init(client: ASMRClient) {
        self.client = client
        auth = (try? store.load()).flatMap { try? JSONDecoder().decode(AuthResponse.self, from: $0) }
    }

    func login(name: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let auth = try await client.login(name: name, password: password)
            try store.save(JSONEncoder().encode(auth))
            self.auth = auth
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
