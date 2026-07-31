import Foundation

/// Pending refunds awaiting a `.result` / acquirer callback.
final class RefundAttemptRegistry {
    static let shared = RefundAttemptRegistry()

    private struct Pending { let wire: WireRefundRequest; let callback: POSRouterCallback }
    private let lock = NSLock()
    private var attempts: [String: Pending] = [:]

    private func storageKey(_ wire: WireRefundRequest) -> String {
        PaymentAttemptKey(terminalId: wire.terminalId, orderId: wire.orderId, attemptId: wire.attemptId).storageKey()
    }

    func store(_ wire: WireRefundRequest, callback: POSRouterCallback) {
        lock.lock(); attempts[storageKey(wire)] = Pending(wire: wire, callback: callback); lock.unlock()
    }

    func lookup(_ terminalId: String, _ orderId: String, _ attemptId: String) -> WireRefundRequest? {
        let k = PaymentAttemptKey(terminalId: terminalId, orderId: orderId, attemptId: attemptId).storageKey()
        lock.lock(); defer { lock.unlock() }
        return attempts[k]?.wire
    }

    func deliverCallback(_ result: PaymentResult) -> Bool {
        guard let orderId = result.orderId, let attemptId = result.attemptId else { return false }
        let k = PaymentAttemptKey(terminalId: result.terminalId, orderId: orderId, attemptId: attemptId).storageKey()
        lock.lock()
        guard let pending = attempts[k] else { lock.unlock(); return false }
        attempts[k] = nil
        lock.unlock()
        DispatchQueue.main.async { pending.callback.onResult(result) }
        return true
    }

    func close(_ wire: WireRefundRequest) {
        lock.lock(); attempts[storageKey(wire)] = nil; lock.unlock()
    }
}

/// Tracks attempts voided by the initiator; late acquirer callbacks are ignored.
final class VoidedAttemptRegistry {
    static let shared = VoidedAttemptRegistry()
    private let lock = NSLock()
    private var voidedAt: [String: Int64] = [:]
    private let ttlMs: Int64 = 30 * 60 * 1000

    private func key(_ terminalId: String, _ orderId: String, _ attemptId: String) -> String {
        PaymentAttemptKey(terminalId: terminalId, orderId: orderId, attemptId: attemptId).storageKey()
    }

    func mark(_ terminalId: String, _ orderId: String, _ attemptId: String) {
        lock.lock(); pruneLocked(); voidedAt[key(terminalId, orderId, attemptId)] = nowMillis(); lock.unlock()
    }

    func isVoided(_ terminalId: String, _ orderId: String, _ attemptId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return voidedAt[key(terminalId, orderId, attemptId)] != nil
    }

    private func pruneLocked() {
        let now = nowMillis()
        for (k, ts) in voidedAt where now - ts > ttlMs { voidedAt[k] = nil }
    }
}

/// Ensures each attempt receives at most one terminal payment result delivery.
final class PaymentResultLedger {
    static let shared = PaymentResultLedger()
    private let lock = NSLock()
    private var delivered: [String: Int64] = [:]
    private let ttlMs: Int64 = 30 * 60 * 1000

    func deliveryKey(_ result: PaymentResult) -> String? {
        guard let orderId = result.orderId else { return nil }
        let attemptId = result.attemptId ?? PaymentAttemptKey.defaultAttemptId(orderId)
        return "\(result.terminalId):\(orderId):\(attemptId)"
    }

    func markIfFirst(_ result: PaymentResult) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard let key = deliveryKey(result) else { return false }
        if delivered[key] != nil { return false }
        delivered[key] = nowMillis()
        return true
    }

    private func pruneLocked() {
        let now = nowMillis()
        for (k, ts) in delivered where now - ts > ttlMs { delivered[k] = nil }
    }
}

/// Queues `connect` callbacks issued while the Lensing session is still coming up.
final class PendingConnectRegistry {
    static let shared = PendingConnectRegistry()
    private let lock = NSLock()
    private var callbacks: [POSRouterCallback] = []

    func enqueue(_ callback: POSRouterCallback) {
        lock.lock(); callbacks.append(callback); lock.unlock()
        if LensingProtocolEngine.shared.currentState() == .connected { flush() }
    }

    func flush() {
        guard let config = LensingContextHolder.shared.config else { return }
        let result = Self.networkConnectResult(config)
        drain { $0.onResult(result) }
    }

    func failAll(_ error: POSRouterError) {
        drain { $0.onError(error) }
    }

    private func drain(_ deliver: @escaping (POSRouterCallback) -> Void) {
        lock.lock()
        let pending = callbacks
        callbacks.removeAll()
        lock.unlock()
        for callback in pending {
            DispatchQueue.main.async { deliver(callback) }
        }
    }

    static func networkConnectResult(_ config: POSRouterConfig) -> PaymentResult {
        PaymentResult(
            terminalId: config.terminalId, status: .approved, transactionId: nil,
            amount: 0, currency: config.currency, message: "Network track connected",
            localRouteMethod: .network
        )
    }
}
