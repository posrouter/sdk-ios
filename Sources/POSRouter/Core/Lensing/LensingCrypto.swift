import Foundation
import CryptoKit

enum LensingCrypto {
    static func computeSignature(key: String, timestamp: String) -> String {
        let message = key + timestamp
        let keyData = SymmetricKey(data: Data(key.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: keyData)
        return signature.map { String(format: "%02x", $0) }.joined()
    }
}
