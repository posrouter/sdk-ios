import Foundation

/// Parameter delimiter for local deep-link query strings.
/// Legacy acquirers (e.g. current Ezypos builds) use ``ampersand``; Lens Protocol v2 uses ``pipe``.
public enum LocalParamSeparator: Sendable {
    case pipe
    case ampersand

    var delimiter: Character {
        switch self {
        case .pipe: return "|"
        case .ampersand: return "&"
        }
    }
}

/// Immutable initiator (A-side) configuration. Mirrors the Android `POSRouterConfig`
/// A-side surface; B-side terminal-mode fields have no iOS equivalent and are omitted.
public struct POSRouterConfig: Sendable, Equatable {
    /// Caller identity, e.g. `GPOS`.
    public let participantCode: String
    public let participantKey: String
    public let terminalId: String
    /// Partner registry code to pay, e.g. `SUPY`.
    public let acquirerCode: String
    public let merchantId: String
    /// Platform sub-merchant; omitted on the NATS subject as `_`. Must not equal `_`.
    public let subMerchantId: String?
    /// Return URL scheme the acquirer calls back on, e.g. `gomenu://pay_result`.
    public let callbackUrl: String?
    public let currency: String
    /// Optional overrides when the Gateway matrix is unavailable.
    public let acquirerPackageOverride: String?
    public let acquirerSchemeOverride: String?
    /// Local deep-link parameter delimiter; default is Lens Protocol v2 pipe.
    public let localParamSeparator: LocalParamSeparator
    /// Applied when ``PaymentRequest/method`` is omitted, e.g. `emv_card` for Ezypos card-present.
    public let defaultPayMethod: String?
    /// Optional Gateway origin or `/init` URL for `/init` and `/matrix`.
    /// When `nil`, uses the production default `https://gateway.posrouter.com/init`.
    public let gatewayBaseUrl: String?
    /// Deep-link scheme for ``RoutePreference/localPosrouterKiosk`` charges
    /// (default `posrouter-kiosk` → `posrouter-kiosk://charge`).
    public let localKioskScheme: String?

    public init(
        participantCode: String,
        participantKey: String,
        terminalId: String,
        acquirerCode: String,
        merchantId: String,
        subMerchantId: String? = nil,
        callbackUrl: String? = nil,
        currency: String = "NZD",
        acquirerPackageOverride: String? = nil,
        acquirerSchemeOverride: String? = nil,
        localParamSeparator: LocalParamSeparator = .pipe,
        defaultPayMethod: String? = nil,
        gatewayBaseUrl: String? = nil,
        localKioskScheme: String? = nil
    ) {
        self.participantCode = participantCode
        self.participantKey = participantKey
        self.terminalId = terminalId
        self.acquirerCode = acquirerCode
        self.merchantId = merchantId
        self.subMerchantId = subMerchantId
        self.callbackUrl = callbackUrl
        self.currency = currency
        self.acquirerPackageOverride = acquirerPackageOverride
        self.acquirerSchemeOverride = acquirerSchemeOverride
        self.localParamSeparator = localParamSeparator
        self.defaultPayMethod = defaultPayMethod
        self.gatewayBaseUrl = gatewayBaseUrl
        self.localKioskScheme = localKioskScheme
    }
}
