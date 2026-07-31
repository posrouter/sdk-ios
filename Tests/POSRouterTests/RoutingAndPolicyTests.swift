import XCTest
@testable import POSRouter

final class RoutePreferenceTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(RoutePreference.normalize(nil), "auto")
        XCTAssertEqual(RoutePreference.normalize("   "), "auto")
        XCTAssertEqual(RoutePreference.normalize("REMOTE-FIRST"), "remote_first")
        XCTAssertEqual(RoutePreference.normalize("local_first"), "local_first")
        XCTAssertEqual(RoutePreference.normalize("bogus"), "auto")
        XCTAssertEqual(RoutePreference.normalize("local_posrouter_kiosk"), "local_posrouter_kiosk")
    }

    func testPolicySkipsAndFallback() {
        XCTAssertTrue(RoutePreferencePolicy.skipsLocalAttempt(RoutePreference.remoteOnly))
        XCTAssertTrue(RoutePreferencePolicy.skipsLocalAttempt(RoutePreference.remoteFirst))
        XCTAssertFalse(RoutePreferencePolicy.skipsLocalAttempt(RoutePreference.auto))

        XCTAssertFalse(RoutePreferencePolicy.shouldFallbackToRemote(RoutePreference.localOnly))
        XCTAssertTrue(RoutePreferencePolicy.shouldFallbackToRemote(RoutePreference.auto))

        XCTAssertTrue(RoutePreferencePolicy.shouldTryLocal(RoutePreference.localFirst, acquirerCode: "SUPY"))
        XCTAssertFalse(RoutePreferencePolicy.shouldTryLocal(RoutePreference.remoteOnly, acquirerCode: "SUPY"))
    }
}

final class GatewayEndpointsTests: XCTestCase {
    private func cfg(_ base: String?) -> POSRouterConfig {
        POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "T",
                        acquirerCode: "SUPY", merchantId: "m", gatewayBaseUrl: base)
    }

    func testDefaults() {
        XCTAssertEqual(GatewayEndpoints.initUrl(cfg(nil)), "https://gateway.posrouter.com/init")
        XCTAssertEqual(GatewayEndpoints.matrixUrl(cfg(nil)), "https://gateway.posrouter.com/matrix")
    }

    func testOverrides() {
        XCTAssertEqual(GatewayEndpoints.initUrl(cfg("https://x.vercel.app")), "https://x.vercel.app/init")
        XCTAssertEqual(GatewayEndpoints.initUrl(cfg("https://x.vercel.app/")), "https://x.vercel.app/init")
        XCTAssertEqual(GatewayEndpoints.initUrl(cfg("https://x.vercel.app/init")), "https://x.vercel.app/init")
        XCTAssertEqual(GatewayEndpoints.initUrl(cfg("https://x.vercel.app/matrix")), "https://x.vercel.app/init")
        XCTAssertEqual(GatewayEndpoints.matrixUrl(cfg("https://x.vercel.app")), "https://x.vercel.app/matrix")
    }
}

final class AcquirerRegistryTests: XCTestCase {
    func testBakedDefaultForSupy() {
        let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "T",
                                     acquirerCode: "SUPY", merchantId: "m")
        let routing = AcquirerRegistry.shared.resolve(config)
        XCTAssertEqual(routing.code, "SUPY")
        XCTAssertEqual(routing.packageName, "ezypay.com.globe.cardpos")
        XCTAssertEqual(routing.schemeUri, "ezypos://")
    }

    func testOverrideHonoredOnPrimary() {
        let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "T",
                                     acquirerCode: "SUPY", merchantId: "m",
                                     acquirerPackageOverride: "com.x", acquirerSchemeOverride: "xpay://")
        let routing = AcquirerRegistry.shared.resolve(config)
        XCTAssertEqual(routing.packageName, "com.x")
        XCTAssertEqual(routing.schemeUri, "xpay://")
    }
}
