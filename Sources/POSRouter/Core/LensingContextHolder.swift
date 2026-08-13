import Foundation

/// Process-wide holder for the active config and route preference (iOS analog of the Android
/// `LensingContextHolder`, minus the Android `Context`).
final class LensingContextHolder {
    static let shared = LensingContextHolder()
    private let lock = NSLock()

    private var _config: POSRouterConfig?
    private var _routePreference: String = RoutePreference.auto

    var config: POSRouterConfig? {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }

    var routePreference: String {
        get { lock.lock(); defer { lock.unlock() }; return _routePreference }
        set { lock.lock(); _routePreference = newValue; lock.unlock() }
    }
}
