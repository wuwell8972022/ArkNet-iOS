import Foundation

/// In-app auth session — LoginInfo counterpart. The Bearer token lives in the
/// app group defaults so the tunnel extension can read the disconnect
/// fallback token even after token loss/eviction.
final class UserSession: ObservableObject {

    static let shared = UserSession()

    @Published private(set) var token: String
    @Published private(set) var userId: String
    @Published private(set) var username: String
    @Published private(set) var email: String

    private enum Key {
        static let token = "auth.token"
        static let userId = "auth.userId"
        static let username = "auth.username"
        static let email = "auth.email"
        static let refreshToken = "auth.refreshToken"
    }

    private init() {
        let d = SharedStore.defaults
        token = d.string(forKey: Key.token) ?? ""
        userId = d.string(forKey: Key.userId) ?? ""
        username = d.string(forKey: Key.username) ?? ""
        email = d.string(forKey: Key.email) ?? ""
    }

    var isLoggedIn: Bool { !token.isEmpty }

    func applyLogin(_ data: LoginData) {
        token = data.token
        userId = data.userId ?? ""
        username = data.username ?? ""
        email = data.email ?? ""
        let d = SharedStore.defaults
        d.set(data.token, forKey: Key.token)
        d.set(data.userId ?? "", forKey: Key.userId)
        d.set(data.username ?? "", forKey: Key.username)
        d.set(data.email ?? "", forKey: Key.email)
        // Disconnect fallback token: the tunnel extension uses this when the
        // app's Bearer token is invalid/evicted (Android dn3.w behaviour).
        SharedStore.disconnectToken = data.token
        objectWillChange.send()
    }

    /// X-Renewed-Token silent rotation (op3 interceptor port).
    func applyRenewedToken(_ renewed: String) {
        guard renewed != token else { return }
        token = renewed
        SharedStore.defaults.set(renewed, forKey: Key.token)
        objectWillChange.send()
    }

    func logout() {
        token = ""
        userId = ""
        username = ""
        email = ""
        let d = SharedStore.defaults
        [Key.token, Key.userId, Key.username, Key.email].forEach { d.removeObject(forKey: $0) }
        SharedStore.disconnectToken = nil
        objectWillChange.send()
    }
}
