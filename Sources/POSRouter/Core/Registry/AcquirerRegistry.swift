import Foundation

struct AcquirerRouting {
    let code: String
    let packageName: String
    let scheme: String

    var schemeUri: String {
        scheme.contains("://") ? scheme : "\(scheme)://"
    }
}

/// Registry-driven acquirer resolution with a baked default and a cache populated by the
/// Gateway `/matrix` directory. Mirrors the Android `AcquirerRegistry`.
final class AcquirerRegistry {
    static let shared = AcquirerRegistry()

    private let lock = NSLock()
    private var routingCache: [String: AcquirerRouting] = [:]

    private let bakedDefaults: [String: AcquirerRouting] = [
        "SUPY": AcquirerRouting(code: "SUPY", packageName: "ezypay.com.globe.cardpos", scheme: "ezypos://")
    ]

    func resolve(_ config: POSRouterConfig, attemptCode: String? = nil) -> AcquirerRouting {
        let code = (attemptCode ?? config.acquirerCode).uppercased()
        let overridePackage = config.acquirerPackageOverride
        // The override targets the PRIMARY acquirer: honor it on the first try or when the
        // attemptCode still names the configured acquirer. A genuine cross-acquirer retry bypasses it.
        if let overridePackage = overridePackage, !overridePackage.isEmpty,
           attemptCode == nil || attemptCode?.caseInsensitiveCompare(config.acquirerCode) == .orderedSame {
            return AcquirerRouting(
                code: code,
                packageName: overridePackage,
                scheme: config.acquirerSchemeOverride ?? "ezypos://"
            )
        }
        lock.lock()
        let cached = routingCache[code]
        lock.unlock()
        return cached
            ?? bakedDefaults[code]
            ?? AcquirerRouting(code: code, packageName: "", scheme: "\(code.lowercased())://")
    }

    func prefetch(_ config: POSRouterConfig) async {
        guard let routing = await LensingDirectoryClient.fetchRoutingMatrix(
            acquirerCode: config.acquirerCode,
            participantCode: config.participantCode,
            participantKey: config.participantKey,
            matrixUrl: GatewayEndpoints.matrixUrl(config)
        ) else { return }
        lock.lock()
        routingCache[config.acquirerCode.uppercased()] = routing
        lock.unlock()
    }
}
