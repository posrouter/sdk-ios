import Foundation
import UIKit

/// Outward-facing POSRouter facade. Lensing Protocol internals are isolated
/// behind `LensingProtocolEngine`.
public final class POSRouter {
    public static let shared = POSRouter()
    private init() {}

    public func initialize(code: String, key: String) {
        LensingProtocolEngine.shared.start(code: code, key: key)
    }

    public func pay(
        from viewController: UIViewController,
        request: PaymentRequest,
        completion: @escaping (Result<PaymentResult, POSRouterError>) -> Void
    ) {
        if LocalRouteScanner.checkAcquirerInstalled(scheme: request.targetScheme) {
            LocalRouteExecutor.launchViaScheme(
                from: viewController,
                scheme: request.targetScheme,
                request: request
            )
            completion(.success(PaymentResult(
                terminalId: request.terminalId,
                status: .approved,
                transactionId: nil,
                amount: request.amount,
                currency: request.currency,
                message: "Local track launched"
            )))
        } else {
            LensingProtocolEngine.shared.dispatchTransaction(request: request, completion: completion)
        }
    }
}
