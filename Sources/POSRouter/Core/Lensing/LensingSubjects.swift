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

enum LensingSubjectError: Error { case blankSegment(String), dottedSegment(String), reservedPlaceholder }

enum LensingSubjects {
    /// Sentinel when `subMerchantId` is absent; real sub-merchant ids must not use this value.
    static let subMerchantPlaceholder = "_"

    static func paySubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "pay") }
    static func resultSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "result") }
    static func claimedSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "claimed") }
    static func voidSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "void") }
    static func refundSubject(_ scope: LensingSubjectScope) -> String { verbSubject(scope, "refund") }

    /// Subscribe prefix for all verbs on one terminal namespace, e.g. `lensing.SUPY.abc123._.TID001.>`.
    static func terminalWildcard(_ scope: LensingSubjectScope) -> String { "\(namespacePrefix(scope)).>" }

    static func subMerchantSegment(_ subMerchantId: String?) -> String {
        let trimmed = (subMerchantId ?? "").trimmingCharacters(in: .whitespaces)
        precondition(trimmed != subMerchantPlaceholder,
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
        precondition(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(label) must not be blank")
        precondition(!value.contains("."), "\(label) must not contain '.'")
        return value
    }
}
