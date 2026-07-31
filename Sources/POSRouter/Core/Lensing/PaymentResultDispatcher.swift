import Foundation

enum PaymentResultSource {
    /// Parsed from acquirer deeplink/callback URL on this device.
    case localCallback
    /// Received on the NATS result subject.
    case natsInbound
    /// Caller invoked ``POSRouter/publishPaymentResult(_:)``.
    case manualPublish
    /// Terminal ack after initiator void (soft void, no acquirer deeplink).
    case voidAck
}

/// Single choke point that dedupes a result, delivers it to any waiting `pay`/`refund` callback,
/// releases the routing claim, optionally re-publishes to NATS, and notifies the terminal listener.
enum PaymentResultDispatcher {
    @discardableResult
    static func deliver(
        _ result: PaymentResult,
        source: PaymentResultSource,
        publishNats: Bool? = nil,
        dispatchTerminal: Bool = true
    ) -> Bool {
        let shouldPublish = publishNats ?? (source != .natsInbound)

        guard PaymentResultLedger.shared.markIfFirst(result) else { return false }

        let deliveredLocally = RefundAttemptRegistry.shared.deliverCallback(result)
            || PaymentAttemptRegistry.shared.deliverCallback(result)

        if let orderId = result.orderId, let attemptId = result.attemptId {
            if !deliveredLocally {
                PaymentAttemptRegistry.shared.close(result.terminalId, orderId, attemptId)
            }
            PaymentClaimRegistry.shared.releaseClaim(result.terminalId, orderId, attemptId)
        }

        if shouldPublish {
            LensingProtocolEngine.shared.publishPaymentResult(result)
        }
        if dispatchTerminal {
            TerminalEventDispatcher.shared.dispatchPaymentCompleted(result)
        }
        return true
    }
}
