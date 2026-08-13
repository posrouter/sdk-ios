import Foundation

/// Result waiter for ``POSRouter/connect(callback:routePreference:)``,
/// ``POSRouter/pay(request:callback:routePreference:)`` and
/// ``POSRouter/refund(request:callback:routePreference:)``.
///
/// Invoked on the main thread. `onUserCancelled` / `onInitiatorVoided` are optional typed
/// hooks; each is always followed by `onResult` with the same result for backward compatibility.
public protocol POSRouterCallback: AnyObject {
    func onResult(_ result: PaymentResult)
    func onError(_ error: POSRouterError)
    /// Terminal / acquirer user cancelled the in-flight pay (`status=cancelled`, `cancelReason=user_cancel`).
    func onUserCancelled(_ result: PaymentResult)
    /// A-side ``POSRouter/voidPayment(orderId:attemptId:)`` was acked by the terminal
    /// (`status=cancelled`, `cancelReason=initiator_void`).
    func onInitiatorVoided(_ result: PaymentResult)
}

public extension POSRouterCallback {
    func onUserCancelled(_ result: PaymentResult) {}
    func onInitiatorVoided(_ result: PaymentResult) {}
}

/// Closure-based ``POSRouterCallback`` for call sites that prefer a `Result` handler.
public final class POSRouterResultCallback: POSRouterCallback {
    private let handler: (Result<PaymentResult, POSRouterError>) -> Void

    public init(_ handler: @escaping (Result<PaymentResult, POSRouterError>) -> Void) {
        self.handler = handler
    }

    public func onResult(_ result: PaymentResult) { handler(.success(result)) }
    public func onError(_ error: POSRouterError) { handler(.failure(error)) }
}

/// Optional callbacks for A-side connection status and completed payments.
/// (Android's B-side terminal callbacks — remote pay received / launch failed — have no iOS
/// equivalent since iOS cannot host a background acquirer terminal; they are surfaced but
/// only ever fire on a device acting as a terminal, which iOS is not.)
public protocol POSRouterTerminalListener: AnyObject {
    func onLensingStateChanged(_ state: LensingConnectionState)
    /// Acquirer callback processed (local device completed or cancelled the payment UI).
    func onPaymentCompleted(_ result: PaymentResult)
    func onRemotePaymentVoided(orderId: String, attemptId: String, message: String?)
}

public extension POSRouterTerminalListener {
    func onLensingStateChanged(_ state: LensingConnectionState) {}
    func onPaymentCompleted(_ result: PaymentResult) {}
    func onRemotePaymentVoided(orderId: String, attemptId: String, message: String?) {}
}
