import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum LocalLaunchMethod {
    /// iOS reaches the acquirer only via its URL scheme; there is no explicit-Intent equivalent.
    case deepLink
    var publicRouteMethod: LocalRouteMethod { .deepLink }
}

struct LocalLaunchResult {
    let success: Bool
    var method: LocalLaunchMethod?
}

enum LocalReachState { case unknown, reachable, unreachable }

/// In-memory reachability per acquirer registry code. On iOS, `canOpenURL` is the reachability
/// probe (requires the target scheme in the host app's `LSApplicationQueriesSchemes`).
final class LocalReachabilityCache {
    static let shared = LocalReachabilityCache()
    private let lock = NSLock()
    private var cache: [String: LocalReachState] = [:]

    func state(_ acquirerCode: String) -> LocalReachState {
        lock.lock(); defer { lock.unlock() }
        return cache[acquirerCode.uppercased()] ?? .unknown
    }

    func shouldTryLocal(_ acquirerCode: String) -> Bool { state(acquirerCode) != .unreachable }

    func markReachable(_ acquirerCode: String) { set(acquirerCode, .reachable) }
    func markUnreachable(_ acquirerCode: String) { set(acquirerCode, .unreachable) }
    func invalidate(_ acquirerCode: String) {
        lock.lock(); cache[acquirerCode.uppercased()] = nil; lock.unlock()
    }

    private func set(_ acquirerCode: String, _ value: LocalReachState) {
        lock.lock(); cache[acquirerCode.uppercased()] = value; lock.unlock()
    }
}

/// Opens the local acquirer via its URL scheme. iOS has no explicit-package launch, so the
/// "chain" is a single deep-link attempt gated on `canOpenURL`.
enum LocalAcquirerLauncher {
    static func launchConnect(_ config: POSRouterConfig, routing: AcquirerRouting) -> LocalLaunchResult {
        launch(routing.code, urlString: LocalDeepLinkUriBuilder.buildConnectUriString(config))
    }

    static func launchPay(_ config: POSRouterConfig, routing: AcquirerRouting, request: WirePaymentRequest) -> LocalLaunchResult {
        launch(routing.code, urlString: LocalDeepLinkUriBuilder.buildPayUriString(request, separator: config.localParamSeparator, config: config))
    }

    static func launchRefund(_ config: POSRouterConfig, routing: AcquirerRouting, request: WireRefundRequest) -> LocalLaunchResult {
        launch(routing.code, urlString: LocalDeepLinkUriBuilder.buildRefundUriString(request, separator: config.localParamSeparator))
    }

    private static func launch(_ acquirerCode: String, urlString: String) -> LocalLaunchResult {
        guard let url = URL(string: urlString) else {
            LocalReachabilityCache.shared.markUnreachable(acquirerCode)
            return LocalLaunchResult(success: false)
        }
        #if canImport(UIKit)
        // `canOpenURL` and `open` are main-thread-only; hop on if the caller is on a background queue.
        let canOpen = onMainSync { UIApplication.shared.canOpenURL(url) }
        guard canOpen else {
            LocalReachabilityCache.shared.markUnreachable(acquirerCode)
            return LocalLaunchResult(success: false)
        }
        DispatchQueue.main.async { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
        LocalReachabilityCache.shared.markReachable(acquirerCode)
        return LocalLaunchResult(success: true, method: .deepLink)
        #else
        // No URL-scheme launch outside UIKit (e.g. macOS test host).
        LocalReachabilityCache.shared.markUnreachable(acquirerCode)
        return LocalLaunchResult(success: false)
        #endif
    }
}

enum RoutePreferencePolicy {
    static func shouldTryLocal(_ preference: String, acquirerCode: String) -> Bool {
        switch RoutePreference.normalize(preference) {
        case RoutePreference.remoteFirst, RoutePreference.remoteOnly, RoutePreference.localPosrouterKiosk:
            return false
        case RoutePreference.localFirst, RoutePreference.localOnly:
            return true
        default:
            return LocalReachabilityCache.shared.shouldTryLocal(acquirerCode)
        }
    }

    static func shouldFallbackToRemote(_ preference: String) -> Bool {
        switch RoutePreference.normalize(preference) {
        case RoutePreference.localOnly, RoutePreference.localPosrouterKiosk: return false
        default: return true
        }
    }

    static func skipsLocalAttempt(_ preference: String) -> Bool {
        switch RoutePreference.normalize(preference) {
        case RoutePreference.remoteFirst, RoutePreference.remoteOnly, RoutePreference.localPosrouterKiosk:
            return true
        default:
            return false
        }
    }

    static func isLocalPosrouterKiosk(_ preference: String) -> Bool {
        RoutePreference.normalize(preference) == RoutePreference.localPosrouterKiosk
    }
}
