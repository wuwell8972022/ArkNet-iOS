import Foundation
import Security

/// X.509 SubjectPublicKeyInfo (SPKI) PEM loader producing a SecKey usable for
/// RSA/ECB/PKCS1 encryption — the Swift port of the Android client's
/// `assets/security/client-bff-rsa-prod2.public.pem` handling (p50.java).
struct RSAPublicKey {

    /// ASN.1 header of a 2048-bit RSA SPKI (PKCS#1 wrapped in SubjectPublicKeyInfo).
    /// 30 82 01 22  30 0d 06 09 2a 86 48 86 f7 0d 01 01 01 05 00  03 82 01 0f 00
    private static let spki2048Prefix: [UInt8] = [
        0x30, 0x82, 0x01, 0x22,
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
        0x03, 0x82, 0x01, 0x0f, 0x00
    ]

    let secKey: SecKey

    /// - Parameter pem: PEM text with BEGIN/END PUBLIC KEY headers.
    init(pem: String) throws {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .filter { !$0.isNewline }
        guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              der.count > spki2048Prefix.count else {
            throw CryptoError.invalidPEM
        }
        let bytes = [UInt8](der)
        guard bytes.starts(with: spki2048Prefix) else {
            throw CryptoError.unsupportedSPKI
        }
        let pkcs1 = der.dropFirst(spki2048Prefix.count)
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ] as CFDictionary, nil) else {
            throw CryptoError.invalidKey
        }
        self.secKey = key
    }

    /// RSA/ECB/PKCS1Padding encryption, base64-encoded (NO_WRAP) — mirrors
    /// `Cipher.getInstance("RSA/ECB/PKCS1Padding")` on Android.
    func encryptPKCS1(_ plaintext: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(
            secKey,
            SecKeyAlgorithm.rsaEncryptionPKCS1,
            plaintext as CFData,
            &error
        ) else {
            throw CryptoError.rsaEncrypt(error?.takeRetainedValue())
        }
        return cipher as Data
    }

    /// Convenience: encrypt UTF-8 text and return base64 text.
    func encryptBase64(_ text: String) throws -> String {
        try encryptPKCS1(Data(text.utf8)).base64EncodedString()
    }
}

enum CryptoError: Error, LocalizedError {
    case invalidPEM
    case unsupportedSPKI
    case invalidKey
    case rsaEncrypt(Unmanaged<CFError>?)
    case aesFailure(Int)
    case badBase64

    var errorDescription: String? {
        switch self {
        case .invalidPEM: return "BFF 公钥 PEM 解析失败"
        case .unsupportedSPKI: return "BFF 公钥不是 2048-bit RSA SPKI"
        case .invalidKey: return "RSA 公钥创建失败 (SecKeyCreateWithData)"
        case .rsaEncrypt(let err): return "RSA 加密失败: \(err?.takeRetainedValue().localizedDescription ?? "?")"
        case .aesFailure(let status): return "AES-ECB 失败 CCCrypt status=\(status)"
        case .badBase64: return "响应密文 Base64 解码失败"
        }
    }
}
