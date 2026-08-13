import Foundation

struct PaymentAttemptKey {
    let terminalId: String
    let orderId: String
    let attemptId: String

    func storageKey() -> String { "\(terminalId):\(orderId):\(attemptId)" }

    static func fromWire(_ wire: WirePaymentRequest) -> PaymentAttemptKey {
        PaymentAttemptKey(terminalId: wire.terminalId, orderId: wire.orderId, attemptId: wire.attemptId)
    }

    static func defaultAttemptId(_ orderId: String) -> String { "\(orderId)#1" }
}

/// Auto-numbers pay attempts per order (`orderId#N`) when the caller omits an explicit id.
final class PaymentAttemptIdResolver {
    static let shared = PaymentAttemptIdResolver()
    private let lock = NSLock()
    private var counters: [String: Int] = [:]

    func resolve(orderId: String, explicit: String?) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return explicit
        }
        lock.lock()
        let next = (counters[orderId] ?? 0) + 1
        counters[orderId] = next
        lock.unlock()
        return "\(orderId)#\(next)"
    }
}

enum RefundAttemptIdResolver {
    static func defaultAttemptId(_ orderId: String) -> String { "\(orderId)#refund" }

    static func resolve(orderId: String, attemptId: String?) -> String {
        if let attemptId = attemptId, !attemptId.trimmingCharacters(in: .whitespaces).isEmpty {
            return attemptId
        }
        return defaultAttemptId(orderId)
    }
}
