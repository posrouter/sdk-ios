import Foundation

struct PaymentClaim {
    let terminalId: String
    let orderId: String
    let attemptId: String
    var claimedAt: Int64 = nowMillis()

    func toJsonString() -> String {
        "{\"terminalId\":\"\(WireJSON.escape(terminalId))\",\"orderId\":\"\(WireJSON.escape(orderId))\",\"attemptId\":\"\(WireJSON.escape(attemptId))\",\"claimedAt\":\(claimedAt)}"
    }

    static func fromJson(_ json: String) -> PaymentClaim? {
        guard let terminalId = WireJSON.extractString(json, "terminalId"),
              let orderId = WireJSON.extractString(json, "orderId") else { return nil }
        let attemptId = WireJSON.extractString(json, "attemptId") ?? PaymentAttemptKey.defaultAttemptId(orderId)
        return PaymentClaim(
            terminalId: terminalId,
            orderId: orderId,
            attemptId: attemptId,
            claimedAt: WireJSON.extractLong(json, "claimedAt") ?? nowMillis()
        )
    }
}

/// In-flight routing guard; stale claims expire so cancelled payments can retry.
final class PaymentClaimRegistry {
    static let shared = PaymentClaimRegistry()
    private let lock = NSLock()
    private var claims: [String: PaymentClaim] = [:]
    private let ttlMs: Int64 = 5 * 60 * 1000

    private func key(_ terminalId: String, _ orderId: String, _ attemptId: String) -> String {
        PaymentAttemptKey(terminalId: terminalId, orderId: orderId, attemptId: attemptId).storageKey()
    }

    private func isExpired(_ claim: PaymentClaim) -> Bool { nowMillis() - claim.claimedAt > ttlMs }

    func isClaimed(_ terminalId: String, _ orderId: String, _ attemptId: String) -> Bool {
        let k = key(terminalId, orderId, attemptId)
        lock.lock(); defer { lock.unlock() }
        if let claim = claims[k], isExpired(claim) { claims[k] = nil }
        return claims[k] != nil
    }

    func markClaimed(_ claim: PaymentClaim) {
        let k = key(claim.terminalId, claim.orderId, claim.attemptId)
        lock.lock(); claims[k] = claim; lock.unlock()
    }

    /// Returns true if this caller acquired the claim (first writer wins locally).
    func tryAcquireClaim(_ terminalId: String, _ orderId: String, _ attemptId: String) -> Bool {
        let k = key(terminalId, orderId, attemptId)
        lock.lock(); defer { lock.unlock() }
        if let claim = claims[k], isExpired(claim) { claims[k] = nil }
        if claims[k] != nil { return false }
        claims[k] = PaymentClaim(terminalId: terminalId, orderId: orderId, attemptId: attemptId)
        return true
    }

    func releaseClaim(_ terminalId: String, _ orderId: String, _ attemptId: String) {
        let k = key(terminalId, orderId, attemptId)
        lock.lock(); claims[k] = nil; lock.unlock()
    }
}
