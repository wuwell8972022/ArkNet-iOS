import Foundation
import CryptoKit

/// BFF HTTP client — the Swift counterpart of the Android `ik3`/`t92` engine:
///
/// * endpoint fallback across zz1..zz3 + dynamically discovered
///   communication domains (v10 race/health logic)
/// * `Authorization: Bearer` injection + `X-Renewed-Token` silent rotation
/// * content-security signing/encryption via ContentSecuritySigner with a
///   per-request random AES key
/// * 403 + body "9010" → clock re-sync from `Date` header → single re-sign
///   retry (p50)
/// * anti-downgrade: signed request receiving plaintext 2xx body fails hard
final class BFFClient {

    enum BFFError: Error, LocalizedError {
        case noEndpoint
        case http(Int, String)
        case plaintextDowngrade
        case decryptFailed(Int)
        case badEnvelope

        var errorDescription: String? {
            switch self {
            case .noEndpoint: return "无可用 BFF 端点"
            case .http(let code, let msg): return "BFF \(code): \(msg)"
            case .plaintextDowngrade: return "密文请求收到明文成功体（反降级硬断）"
            case .decryptFailed(let code): return "响应解密失败 http=\(code)"
            case .badEnvelope: return "X-Content-Security 构造失败"
            }
        }
    }

    struct AuthProvider {
        var token: () -> String?
        var onRenewedToken: (String) -> Void
    }

    static let shared = try? BFFClient()

    /// Paths that bypass content-security signing (p50.a contract).
    private static let unsignedPaths: Set<String> = [
        "/api/v1/app/initialization"
    ]

    private var signer: ContentSecuritySigner
    private let session: URLSession
    private let auth: AuthProvider

    init(auth: AuthProvider? = nil) throws {
        let pem = try Self.loadBundledPEM()
        self.signer = try ContentSecuritySigner(publicKeyPEM: pem)
        if let stored = SharedStore.defaults.object(forKey: "bff.clockOffsetMs") as? Int64 {
            self.signer.setClockOffset(stored)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.auth = auth ?? AuthProvider(
            token: { UserSession.shared.token },
            onRenewedToken: { UserSession.shared.applyRenewedToken($0) }
        )
    }

    // MARK: - Public request API

    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String]? = nil,
        body: Encodable? = nil,
        signed: Bool? = nil,
        authorize: Bool = true,
        race: Bool = false
    ) async throws -> T {
        let response: (Data, HTTPURLResponse) = try await rawRequest(
            method, path, query: query, body: body,
            signed: signed ?? !Self.unsignedPaths.contains(path),
            authorize: authorize, race: race
        )
        let (data, http) = response
        guard (200..<300).contains(http.statusCode) else {
            throw BFFError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ApiResponse<T>.self, from: data)
        guard decoded.isOK, let payload = decoded.data else {
            throw BFFError.http(http.statusCode, decoded.message ?? "unknown")
        }
        return payload
    }

    /// Returns the raw `data` payload as JSON dictionary for loosely-typed
    /// endpoints (billing policy etc.).
    func requestObject(
        _ method: String,
        _ path: String,
        query: [String: String]? = nil,
        body: Encodable? = nil
    ) async throws -> [String: Any] {
        let (data, http) = try await rawRequest(
            method, path, query: query, body: body, signed: true, authorize: true, race: false
        )
        guard (200..<300).contains(http.statusCode) else {
            throw BFFError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ApiResponse<[String: AnyDecodable]>.self, from: data)
        guard decoded.isOK, let payload = decoded.data else {
            throw BFFError.http(http.statusCode, decoded.message ?? "unknown")
        }
        return payload.mapValues { $0.value }
    }

    // MARK: - Core transport

    private func rawRequest(
        _ method: String,
        _ path: String,
        query: [String: String]?,
        body: Encodable?,
        signed: Bool,
        authorize: Bool,
        race: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var bodyData: Data?
        if let body {
            let encoder = JSONEncoder()
            bodyData = try encoder.encode(AnyEncodable(body))
        }

        // Endpoint list: primary + static fallbacks + dynamic communication domains.
        let endpoints = Self.raceCandidates(primaryFirst: true)

        var lastError: Error = BFFError.noEndpoint
        for endpoint in endpoints {
            guard let url = Self.buildURL(base: endpoint, path: path, query: query) else {
                continue
            }
            do {
                return try await perform(
                    method: method, url: url,
                    bodyData: bodyData,
                    signed: signed, authorize: authorize
                )
            } catch let error as BFFError {
                // Transport-level failures move to the next endpoint; protocol
                // failures (plaintext downgrade, decrypt) do not.
                switch error {
                case .plaintextDowngrade, .decryptFailed, .badEnvelope:
                    throw error
                default:
                    lastError = error
                    continue
                }
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func perform(
        method: String,
        url: URL,
        bodyData: Data?,
        signed: Bool,
        authorize: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        // ---- first attempt -------------------------------------------------
        var attempt = try buildURLRequest(
            method: method, url: url, bodyData: bodyData,
            signed: signed, authorize: authorize
        )
        var (data, http) = try await execute(attempt)

        // ---- 403 / 9010: clock sync + one re-sign retry (p50) --------------
        if signed, http.statusCode == 403,
           let text = String(data: data, encoding: .utf8), text.contains("9010"),
           let serverDate = Self.parseHTTPDate(http.value(forHTTPHeaderField: "Date")) {
            var refreshedSigner = signer
            refreshedSigner.applyClockSync(
                serverEpochMilliseconds: Int64(serverDate.timeIntervalSince1970 * 1000)
            )
            // Persist on the instance + defaults so later requests reuse it.
            self.signer = refreshedSigner
            SharedStore.defaults.set(
                refreshedSigner.clockOffsetMilliseconds, forKey: "bff.clockOffsetMs"
            )
            attempt = try buildURLRequest(
                method: method, url: url, bodyData: bodyData,
                signed: signed, authorize: authorize
            )
            (data, http) = try await execute(attempt)
        }

        // ---- token rotation -------------------------------------------------
        if let renewed = http.value(forHTTPHeaderField: "X-Renewed-Token"), !renewed.isEmpty {
            auth.onRenewedToken(renewed)
        }

        // ---- decrypt ---------------------------------------------------------
        if signed, let key = Self.takeRequestKey(attempt) {
            switch signer.decryptResponse(data, key: key) {
            case .decrypted(let plain):
                return (plain, http)
            case .plaintext:
                if (200..<300).contains(http.statusCode) {
                    throw BFFError.plaintextDowngrade
                }
                return (data, http)
            case .nonProtocolBody:
                if (200..<300).contains(http.statusCode) {
                    throw BFFError.decryptFailed(http.statusCode)
                }
                return (data, http)
            }
        }
        return (data, http)
    }

    // MARK: - Request building

    private func buildURLRequest(
        method: String,
        url: URL,
        bodyData: Data?,
        signed: Bool,
        authorize: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("ArkNet-iOS/1.0.1", forHTTPHeaderField: "User-Agent")
        request.setValue(SessionStore.deviceID, forHTTPHeaderField: "device-id")
        request.setValue("ios", forHTTPHeaderField: "platform")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "timezone")

        if signed {
            let key = Self.generateRandomKey()          // retained for response decrypt
            let signedRequest = try signer.sign(
                method: method, url: url, body: bodyData, randomKey: key
            )
            if let newBody = signedRequest.body {
                request.httpBody = newBody
                request.setValue(signedRequest.contentType, forHTTPHeaderField: "Content-Type")
            }
            request.setValue(signedRequest.xContentSecurity, forHTTPHeaderField: "X-Content-Security")
            Self.rememberRequestKey(request, key: key)
        } else if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        if authorize, let token = auth.token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BFFError.noEndpoint
        }
        return (data, http)
    }

    // MARK: - Per-request AES key retention

    /// Task-local AES keys — keyed by URLRequest identity (p50 uses the same
    /// key for request encryption and response decryption).
    private static let keyRegistry = NSMapTable<NSString, NSData>.keyValueStrongReferences()
    private static let keyLock = NSLock()

    private static func generateRandomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private static func rememberRequestKey(_ request: URLRequest, key: Data) {
        keyLock.lock()
        defer { keyLock.unlock() }
        keyRegistry.setObject(Data(key), forKey: requestIdentity(request) as NSString)
    }

    private static func takeRequestKey(_ request: URLRequest) -> Data? {
        keyLock.lock()
        defer { keyLock.unlock() }
        let key = keyRegistry.object(forKey: requestIdentity(request) as NSString) as Data?
        keyRegistry.removeObject(forKey: requestIdentity(request) as NSString)
        return key
    }

    private static func requestIdentity(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "")|\(request.url?.absoluteString ?? "")"
    }

    // MARK: - Endpoint racing

    /// Communication domains fetched during initialization are appended after
    /// the static zz1..zz3 list; hosts deduped, order preserved.
    static func raceCandidates(primaryFirst: Bool) -> [String] {
        var all = SessionStore.bffEndpoints
        if primaryFirst, let primary = all.first {
            all.removeFirst()
            all.insert(primary, at: 0)
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    // MARK: - Helpers

    static func buildURL(base: String, path: String, query: [String: String]?) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.path = (components.path.isEmpty ? "" : components.path) + path
        if let query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    static func parseHTTPDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    private static func loadBundledPEM() throws -> String {
        guard let url = Bundle.main.url(
            forResource: "client-bff-rsa-prod2", withExtension: "public.pem"
        ), let pem = try? String(contentsOf: url, encoding: .utf8) else {
            throw CryptoError.invalidPEM
        }
        return pem
    }
}

// MARK: - Type-erasure helpers

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        encodeFunc = wrapped.encode(to:)
    }
    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}

struct AnyDecodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int64.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([String].self) { value = v }
        else if let v = try? container.decode([String: AnyDecodable].self) {
            value = v.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}
