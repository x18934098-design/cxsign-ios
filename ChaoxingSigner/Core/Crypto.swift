import Foundation
import CommonCrypto

/// Chaoxing 登录口令加密。
///
/// 与原版 APK 完全一致（`Lmd0;.b`）：
///   Cipher = AES/CBC/PKCS5Padding
///   SecretKey = IV = "u2oh6Vu^HWe4_AES" (UTF-8, 16 bytes => AES-128)
///   输出   = Base64.getEncoder().encodeToString(cipher.doFinal(plain.getBytes()))
enum ChaoxingCrypto {
    static let aesKey = "u2oh6Vu^HWe4_AES"

    enum CryptoFailure: LocalizedError {
        case cccrypt(Int32)
        var errorDescription: String? {
            switch self {
            case .cccrypt(let s): return "AES 加密失败 (CCCrypt status \(s))"
            }
        }
    }

    static func aesEncryptBase64(_ plaintext: String) throws -> String {
        let keyData = Data(aesKey.utf8)
        let input = Data(plaintext.utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved: size_t = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            guard let outPtr = outBuf.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
            return input.withUnsafeBytes { inBuf -> CCCryptorStatus in
                keyData.withUnsafeBytes { keyBuf -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, keyData.count,
                            keyBuf.baseAddress,           // IV == key
                            inBuf.baseAddress, input.count,
                            outPtr, outBuf.count,
                            &moved)
                }
            }
        }

        guard status == kCCSuccess else { throw CryptoFailure.cccrypt(Int32(status)) }
        return output.prefix(moved).base64EncodedString()
    }

    /// 仅用于自检：把密文解回来，确认与服务端约定一致。
    static func aesDecryptBase64(_ cipherBase64: String) throws -> String {
        guard let cipher = Data(base64Encoded: cipherBase64) else { return "" }
        let keyData = Data(aesKey.utf8)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        var moved: size_t = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            guard let outPtr = outBuf.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
            return cipher.withUnsafeBytes { inBuf -> CCCryptorStatus in
                keyData.withUnsafeBytes { keyBuf -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, keyData.count,
                            keyBuf.baseAddress,
                            inBuf.baseAddress, cipher.count,
                            outPtr, outBuf.count,
                            &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoFailure.cccrypt(Int32(status)) }
        return String(data: output.prefix(moved), encoding: .utf8) ?? ""
    }
}