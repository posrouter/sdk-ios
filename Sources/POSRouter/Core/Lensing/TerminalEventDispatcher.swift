import Foundation

/// Fans Lensing state + completed-payment events out to a registered ``POSRouterTerminalListener``,
/// and drives ``PendingConnectRegistry`` on CONNECTED / FAILED transitions. Callbacks run on main.
final class TerminalEventDispatcher {
    static let shared = TerminalEventDispatcher()
    private let lock = NSLock()
    weak var listener: POSRouterTerminalListener?
    private var lastDispatchedPublicState: LensingConnectionState?

    func dispatchLensingState(_ state: LensingState) {
        let publicState = state.publicState
        lock.lock()
        if publicState == lastDispatchedPublicState { lock.unlock(); return }
        lastDispatchedPublicState = publicState
        let listener = self.listener
        lock.unlock()

        switch state {
        case .connected: PendingConnectRegistry.shared.flush()
        case .failed:
            PendingConnectRegistry.shared.failAll(POSRouterError(code: "CONNECT_FAILED", message: "Lensing engine connection failed"))
        default: break
        }
        if let listener = listener {
            DispatchQueue.main.async { listener.onLensingStateChanged(publicState) }
        }
    }

    func dispatchPaymentCompleted(_ result: PaymentResult) {
        guard let listener = listener else { return }
        DispatchQueue.main.async { listener.onPaymentCompleted(result) }
    }

    func dispatchRemotePaymentVoided(orderId: String, attemptId: String, message: String?) {
        guard let listener = listener else { return }
        DispatchQueue.main.async { listener.onRemotePaymentVoided(orderId: orderId, attemptId: attemptId, message: message) }
    }
}
