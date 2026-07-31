import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Same-device POSRouter Kiosk method-selection launcher (`{scheme}://charge`). iOS analog of the
/// Android `LocalKioskSelectionLauncher`; probes via `canOpenURL` and opens the charge deep link.
enum LocalKioskLauncher {
    static let defaultScheme = "posrouter-kiosk"
    static let hostCharge = "charge"

    static func resolveScheme(_ config: POSRouterConfig?) -> String {
        if let scheme = config?.localKioskScheme?.trimmingCharacters(in: .whitespaces), !scheme.isEmpty {
            return scheme
        }
        return defaultScheme
    }

    static func isAvailable(_ config: POSRouterConfig?) -> Bool {
        #if canImport(UIKit)
        guard let url = URL(string: "\(resolveScheme(config))://\(hostCharge)") else { return false }
        // `canOpenURL` is main-thread-only; hop on if a background caller invoked us.
        return onMainSync { UIApplication.shared.canOpenURL(url) }
        #else
        return false
        #endif
    }

    static func launchCharge(_ config: POSRouterConfig, wire: WirePaymentRequest) -> Bool {
        guard let callbackUrl = config.callbackUrl?.trimmingCharacters(in: .whitespaces), !callbackUrl.isEmpty else {
            return false
        }
        guard isAvailable(config) else { return false }
        let scheme = resolveScheme(config)
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = hostCharge
        var items = [
            URLQueryItem(name: "amount", value: String(wire.amount)),
            URLQueryItem(name: "currency", value: wire.currency.isEmpty ? config.currency : wire.currency),
            URLQueryItem(name: "orderid", value: wire.orderId),
            URLQueryItem(name: "method", value: PaymentRequest.methodSelection),
            URLQueryItem(name: "callback_url", value: callbackUrl)
        ]
        if let partnerScheme = URL(string: callbackUrl)?.scheme, !partnerScheme.isEmpty {
            items.append(URLQueryItem(name: "partner_scheme", value: partnerScheme))
        }
        if let remark = wire.remark, !remark.isEmpty { items.append(URLQueryItem(name: "remark", value: remark)) }
        if !wire.attemptId.isEmpty { items.append(URLQueryItem(name: "attemptid", value: wire.attemptId)) }
        comps.queryItems = items
        guard let url = comps.url else { return false }
        #if canImport(UIKit)
        DispatchQueue.main.async { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
        return true
        #else
        return false
        #endif
    }
}
