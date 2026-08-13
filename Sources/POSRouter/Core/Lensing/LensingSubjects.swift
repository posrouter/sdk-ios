import Foundation

/// Fixed 6-token NATS subject namespace: `lensing.{acquirer}.{merchant}.{sub}.{tid}.{verb}`.
struct LensingSubjectScope {
    let acquirerCode: String
    let merchantId: String
    let subMerchantId: String?
    let terminalId: String

    static func fromConfig(_ config: POSRouterConfig) -> LensingSubjectScope {
        LensingSubjectScope(
            acquirerCode: config.acquirerCode,
            merchantId: config.merchantId,
            subMerchantId: config.subMerchantId,
            terminalId: config.terminalId
        )
    }

    static func fromWire(_ wire: WirePaymentRequest) -> LensingSubjectScope {
        LensingSubjectScope(
            acquirerCode: wire.acquirerCode,
            merchantId: wire.merchantId,
            subMerchantId: wire.subMerchantId,
            terminalId: wire.terminalId
        )
    }
}

enum LensingSubjectError: Error, CustomStringConvertible {
    case blankSegment(String), dottedSegment(String), reservedPlaceholder

    var description: String {
        switch self {
        case .blankSegment(let label): return "\(label) must not be blank"
        case .dottedSegment(let label): return "\(label) must not contain '.'"
        case .reservedPlaceholder: return "subMerchantId must not be the reserved placeholder '_'"
        }
    }
}

enum LensingSubjects {
    /// Sentinel when `subMerchantId` is absent; real sub-merchant ids must not use this value.
    static let subMerchantPlaceholder = "_"

    /// Validate a scope's segments up front so callers can reject bad input with a catchable error
    /// instead of tripping an internal `assert` deep in subject construction. Call at the public
    /// boundary (pay/refund/connect) before dispatching.
    static func validate(_ scope: LensingSubjectScope) throws {
        try requireSegment(scope.acquirerCode, "acquirerCode")
        try requireSegment(scope.merchantId, "merchantId")
        try requireSegment(scope.terminalId, "terminalId")
        if let sub = scope.subMerchantId {
            let trimmed = sub.trimmingCharacters(in: .whitespaces)
            if trimmed == subMerchantPlaceholder { throw LensingSubjectError.reservedPlaceholder }
            if !trimmed.isEmpty && trimmed.contains(".") { throw LensingSubjectError.dottedSegment("subMerchantId") }
        }
    }

    private static func requireSegment(_ value: String, _ label: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw LensingSubjectError.blankSegment(label) }
        if value.contains(".") { throw LensingSubjectError.dottedSegment(label) }
    }

    static func paySubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "pay") }
    static func resultSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "result") }
    static func claimedSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "claimed") }
    static func voidSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "void") }
    static func refundSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "refund") }

    /// Subscribe prefix for all verbs on one terminal namespace, e.g. `lensing.SUPY.abc123._.TID001.>`.
    static func terminalWildcard(_ scope: LensingSubjectScope) -> String { "\(namespacePrefix(scope)).>" }

    static func subMerchantSegment(_ subMerchantId: String?) -> String {
        let trimmed = (subMerchantId ?? "").trimmingCharacters(in: .whitespaces)
        // Dev-time signal only; the public boundary already rejects this via `validate(_:)`, so
        // release builds must not abort a live POS here.
        assert(trimmed != subMerchantPlaceholder,
               "subMerchantId must not be the reserved placeholder '\(subMerchantPlaceholder)'")
        return trimmed.isEmpty ? subMerchantPlaceholder : trimmed
    }

    private static func verbSubject(_ scope: LensingSubjectScope, _ verb: String) -> String {
        "\(namespacePrefix(scope)).\(verb)"
    }

    private static func namespacePrefix(_ scope: LensingSubjectScope) -> String {
        [
            "lensing",
            sanitize(scope.acquirerCode.uppercased(), "acquirerCode"),
            sanitize(scope.merchantId, "merchantId"),
            subMerchantSegment(scope.subMerchantId),
            sanitize(scope.terminalId, "terminalId")
        ].joined(separator: ".")
    }

    private static func sanitize(_ value: String, _ label: String) -> String {
        // Dev-time signal only; `validate(_:)` at the public boundary is the real guard, so a
        // release build never aborts here on caller-supplied data.
        assert(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(label) must not be blank")
        assert(!value.contains("."), "\(label) must not contain '.'")
        return value
    }
}
