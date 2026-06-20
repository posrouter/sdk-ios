import Foundation
import UIKit

enum LocalRouteExecutor {
    static func launchViaScheme(
        from viewController: UIViewController,
        scheme: String,
        request: PaymentRequest
    ) {
        let urlString = "\(scheme)pay?terminalId=\(request.terminalId)&amount=\(request.amount)&currency=\(request.currency)"
        guard let url = URL(string: urlString) else { return }

        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
