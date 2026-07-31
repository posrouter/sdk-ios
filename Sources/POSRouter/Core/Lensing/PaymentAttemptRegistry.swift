import Foundation

/// Merged in-flight pay session + optional local callback waiter.
final class PaymentAttemptRegistry {
    static let shared = PaymentAttemptRegistry()

    private struct Attempt {
        let wire: WirePaymentRequest
        let callback: POSRouterCallback?
        let startedAt: Int64
    }

    private let lock = NSLock()
    private var attempts: [String: Attempt] = [:]
    private var openByOrder: [String: String] = [:]
    private let ttlMs: Int64 = 30 * 60 * 1000

    private func orderKey(_ terminalId: String, _ orderId: String) -> String { "\(terminalId):\(orderId)" }

    func store(_ wire: WirePaymentRequest, callback: POSRouterCallback?) {
        lock.lock()
        pruneExpiredLocked()
        let key = PaymentAttemptKey.fromWire(wire)
        attempts[key.storageKey()] = Attempt(wire: wire, callback: callback, startedAt: nowMillis())
        openByOrder[orderKey(wire.terminalId, wire.orderId)] = wire.attemptId
        lock.unlock()
    }

    func lookup(_ key: PaymentAttemptKey) -> WirePaymentRequest? {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        return attempts[key.storageKey()]?.wire
    }

    func lookupOpenByOrder(_ terminalId: String, _ orderId: String) -> WirePaymentRequest? {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        guard let attemptId = openByOrder[orderKey(terminalId, orderId)] else { return nil }
        return attempts[PaymentAttemptKey(terminalId: terminalId, orderId: orderId, attemptId: attemptId).storageKey()]?.wire
    }

    /// True when this device initiated pay and is waiting for a remote/local callback.
    func hasInitiatorCallback(_ terminalId: String, _ orderId: String, _ attemptId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        let k = PaymentAttemptKey(terminalId: terminalId, orderId: orderId, attemptId: attemptId).storageKey()
        return attempts[k]?.callback != nil
    }

    func hasInitiatorCallback(_ wire: WirePaymentRequest) -> Bool {
        hasInitiatorCallback(wire.terminalId, wire.orderId, wire.attemptId)
    }

    func deliverCallback(_ result: PaymentResult) -> Bool {
        guard let orderId = result.orderId else { return false }
        lock.lock()
        pruneExpiredLocked()
        let attemptId = result.attemptId ?? openByOrder[orderKey(result.terminalId, orderId)]
        guard let resolvedAttemptId = attemptId else { lock.unlock(); return false }
        let storageKey = PaymentAttemptKey(terminalId: result.terminalId, orderId: orderId, attemptId: resolvedAttemptId).storageKey()
        guard let attempt = attempts[storageKey], let callback = attempt.callback else { lock.unlock(); return false }
        attempts[storageKey] = nil
        if openByOrder[orderKey(result.terminalId, orderId)] == resolvedAttemptId {
            openByOrder[orderKey(result.terminalId, orderId)] = nil
        }
        lock.unlock()
        dispatchCallback(callback, result)
        return true
    }

    func close(_ terminalId: String, _ orderId: String, _ attemptId: String) {
        let storageKey = PaymentAttemptKey(terminalId: terminalId, orderId: orderId, attemptId: attemptId).storageKey()
        lock.lock()
        attempts[storageKey] = nil
        if openByOrder[orderKey(terminalId, orderId)] == attemptId {
            openByOrder[orderKey(terminalId, orderId)] = nil
        }
        lock.unlock()
    }

    func cancel(_ terminalId: String, _ orderId: String, _ attemptId: String) {
        close(terminalId, orderId, attemptId)
    }

    func cancelLatestOpen(_ terminalId: String, _ orderId: String) {
        lock.lock()
        guard let attemptId = openByOrder[orderKey(terminalId, orderId)] else { lock.unlock(); return }
        openByOrder[orderKey(terminalId, orderId)] = nil
        attempts[PaymentAttemptKey(terminalId: terminalId, orderId: orderId, attemptId: attemptId).storageKey()] = nil
        lock.unlock()
    }

    /// Optional typed cancel hooks; always followed by `onResult`. Invoked on the main thread.
    private func dispatchCallback(_ callback: POSRouterCallback, _ result: PaymentResult) {
        DispatchQueue.main.async {
            if result.status == .cancelled {
                switch result.metadata["cancelReason"] {
                case PaymentCancelReason.userCancel: callback.onUserCancelled(result)
                case PaymentCancelReason.initiatorVoid: callback.onInitiatorVoided(result)
                default: break
                }
            }
            callback.onResult(result)
        }
    }

    private func pruneExpiredLocked() {
        let now = nowMillis()
        let expired = attempts.filter { now - $0.value.startedAt > ttlMs }
        for (storageKey, attempt) in expired {
            attempts[storageKey] = nil
            let ok = orderKey(attempt.wire.terminalId, attempt.wire.orderId)
            if openByOrder[ok] == attempt.wire.attemptId { openByOrder[ok] = nil }
        }
    }
}
