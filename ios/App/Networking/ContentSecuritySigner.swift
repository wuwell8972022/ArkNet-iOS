import Foundation
import CryptoKit

/// Swift port of Android's `p50` content-security interceptor:
///
///  Request  (POST /api/*, except initialization & race-init):
///   1. random 32-byte AES key per request
///   2. body → AES/ECB/PKCS7(key) → Base64 text (becomes the new body)
///   3. timestamp = (serverClockOffset + now) / 1000
///   4. sign string = "ts\nMETHOD\n/path?query\nsha256hex(bodyBase64 or empty)"
///   5. hmac = Base64(HMAC-SHA256(signString, key))
///   6. envelope = "version=v1; type=1; key=<b64(key)>; time=<ts>"
///      → RSA/PKCS1(BFF public key) → Base64
///   7. header: X-Content-Security: key=<keyId>; secret=<envelope>; signature=<hmac>
///
///  Response: Base64 body (not starting with '{'/'[') → AES/ECB decrypt with
///  the same key. Signed request receiving plaintext 2xx body is a hard error
///  (anti-downgrade, "禁回退明文").
struct ContentSecuritySigner {

    static let keyId = "client-rsa-prod2-v1"
    static let encryptedContentType = "application/json; charset=utf-8"

    /// Server clock offset (milliseconds), corrected from 403/9010 responses
    /// via the `Date` header — Android `f53`.
    private(set) var clockOffsetMilliseconds: Int64 = 0

    /// BFF RSA public key, loaded once from the bundled PEM.
    private let publicKey: RSAPublicKey

    /// Records a clock correction. `serverEpochMillis` is parsed from the
    /// response `Date` header of a 403/9010 reply.
    mutating func applyClockSync(serverEpochMilliseconds: Int64) {
        let localNow = Int64(Date().timeIntervalSince1970 * 1000)
        clockOffsetMilliseconds = serverEpochMilliseconds - localNow
    }

    /// Direct offset assignment (persisted-offset restore across launches).
    mutating func setClockOffset(_ offsetMilliseconds: Int64) {
        clockOffsetMilliseconds = offsetMilliseconds
    }

    init(publicKeyPEM: String) throws {
        self.publicKey = try RSAPublicKey(pem: publicKeyPEM)
    }

    struct SignedRequest {
        let body: Data?
        let contentType: String?
        let xContentSecurity: String
    }

    /// Signs (and encrypts) an outgoing request. `timestampSeconds` is derived
    /// internally using the recorded server clock offset.
    func sign(
        method: String,
        url: URL,
        body: Data?,
        randomKey: Data
    ) throws -> SignedRequest {
        // 1-2. encrypt body
        var encryptedBodyText: String?
        if let body, !body.isEmpty {
            let cipher = try AESCBCCryptor.encrypt(body, key: randomKey)
            encryptedBodyText = cipher.base64EncodedString()
        }

        // 3. timestamp with server-offset correction
        let tsSeconds = (Int64(Date().timeIntervalSince1970 * 1000) + clockOffsetMilliseconds) / 1000
        let timestamp = String(tsSeconds)

        // 4. signing string
        let path = "/" + url.pathSegments.joined(separator: "/")
        let query = url.query ?? ""
        let pathWithQuery = query.isEmpty ? path : path + "?" + query
        let bodyHash: String
        if let encryptedBodyText {
            bodyHash = Digest.sha256Hex(Data(encryptedBodyText.utf8))
        } else {
            bodyHash = Digest.emptyBodySHA256Hex
        }
        let signString = [timestamp, method.uppercased(), pathWithQuery, bodyHash]
            .joined(separator: "\n")

        // 5. HMAC signature
        let hmac = Digest.hmacSHA256Base64(key: randomKey, message: Data(signString.utf8))

        // 6. RSA envelope
        let envelope =
            "version=v1; type=1; key=\(randomKey.base64EncodedString()); time=\(timestamp)"
        let secret = try publicKey.encryptBase64(envelope)

        // 7. header + new body
        let header = "key=\(Self.keyId); secret=\(secret); signature=\(hmac)"
        let newBody = encryptedBodyText.map { Data($0.utf8) }
        return SignedRequest(
            body: newBody,
            contentType: newBody != nil ? Self.encryptedContentType : nil,
            xContentSecurity: header
        )
    }

    /// Decrypts a Base64/AES-ECB response body with the request's AES key.
    /// Returns the plaintext body, or nil when the body is not protocol
    /// ciphertext (see `ResponseKind`).
    enum ResponseKind {
        /// Plaintext JSON (starts with `{` or `[`).
        case plaintext
        /// Successfully decrypted ciphertext.
        case decrypted(Data)
        /// Non-protocol body (cannot be decrypted) — callers decide.
        case nonProtocolBody(Data)
    }

    func decryptResponse(_ body: Data, key: Data) -> ResponseKind {
        guard !body.isEmpty else { return .plaintext }
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return .plaintext
        }
        // strip base64 noise like the Android decoder
        var trimmed = text
        while let last = trimmed.last,
              last == "=" || last == "\n" || last == "\r" || last == " " || last == "\t" {
            trimmed.removeLast()
        }
        guard let cipher = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
              !cipher.isEmpty, cipher.count % 16 == 0,
              let plain = try? AESCBCCryptor.decrypt(cipher, key: key) else {
            return .nonProtocolBody(body)
        }
        return .decrypted(plain)
    }
}

private extension URL {
    /// Path segments without the leading slash (mirrors HttpUrl.pathSegments()).
    var pathSegments: [String] {
        (path as NSString).pathComponents.filter { $0 != "/" }
    }
}
