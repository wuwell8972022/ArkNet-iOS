import Foundation
import CommonCrypto
import CryptoKit

/// AES-256/ECB/PKCS7Padding — the CommonCrypto counterpart of Android's
/// `Cipher.getInstance("AES/ECB/PKCS5Padding")` used by the BFF content
/// security layer. NOTE: the legacy BFF protocol mandates ECB; do not reuse
/// this primitive outside the signing interceptor.
enum AESCBCCryptor {

    static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        try crypt(plaintext, key: key, encrypt: true)
    }

    static func decrypt(_ ciphertext: Data, key: Data) throws -> Data {
        try crypt(ciphertext, key: key, encrypt: false)
    }

    private static func crypt(_ input: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw CryptoError.aesFailure(-4301) // kCCParamError
        }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            input.withUnsafeBytes { inPtr -> CCCryptorStatus in
                CCCrypt(
                    encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding) | CCOptions(kCCOptionECBMode),
                    [UInt8](key), key.count,
                    nil,
                    inPtr.baseAddress, input.count,
                    outPtr.baseAddress, output.count, &moved
                )
            }
        }
        guard status == kCCSuccess else {
            throw CryptoError.aesFailure(Int(status))
        }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

/// Shared digest helpers (SHA-256 hex, HMAC-SHA256 base64) matching p50.java.
enum Digest {

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256Base64(key: Data, message: Data) -> String {
        let mac = HMAC.sha256(key: key, data: message)
        return Data(mac).base64EncodedString()
    }

    /// SHA-256 hex of the empty string — p50 uses this constant when the
    /// request carries no body.
    static let emptyBodySHA256Hex =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
