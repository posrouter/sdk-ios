import Foundation

/// Refund payload for a prior approved payment. Cross-device delivery uses NATS `.refund`;
/// same-device uses `ezypos://refund`.
public struct RefundRequest: Sendable {
    public let terminalId: String
    /// Original pay ``orderId``.
    public let orderId: String
    public let amount: Int64
    public let attemptId: String?
    public let attemptCode: String?
    public let subMerchantId: String?

    public init(
        terminalId: String,
        orderId: String,
        amount: Int64,
        attemptId: String? = nil,
        attemptCode: String? = nil,
        subMerchantId: String? = nil
    ) {
        self.terminalId = terminalId
        self.orderId = orderId
        self.amount = amount
        self.attemptId = attemptId
        self.attemptCode = attemptCode
        self.subMerchantId = subMerchantId
    }

    public static func amountFromDecimal(_ decimal: String) -> Int64 {
        PaymentRequest.amountFromDecimal(decimal)
    }

    func toWire(
        config: POSRouterConfig,
        routing: AcquirerRouting,
        resolvedAttemptId: String
    ) -> WireRefundRequest {
        WireRefundRequest(
            terminalId: terminalId,
            orderId: orderId,
            amount: amount,
            currency: config.currency,
            targetPackageName: routing.packageName,
            targetScheme: routing.schemeUri,
            acquirerCode: routing.code,
            merchantId: config.merchantId,
            attemptId: resolvedAttemptId,
            attemptCode: routing.code,
            subMerchantId: subMerchantId
        )
    }
}

struct WireRefundRequest {
    let terminalId: String
    let orderId: String
    let amount: Int64
    let currency: String
    let targetPackageName: String
    let targetScheme: String
    let acquirerCode: String
    let merchantId: String
    let attemptId: String
    let attemptCode: String
    var subMerchantId: String?

    func subjectScope() -> LensingSubjectScope {
        LensingSubjectScope(
            acquirerCode: acquirerCode,
            merchantId: merchantId,
            subMerchantId: subMerchantId,
            terminalId: terminalId
        )
    }

    func toJsonString() -> String {
        var fields = [
            WireJSON.stringField("terminalId", terminalId),
            WireJSON.stringField("orderId", orderId),
            "\"amount\":\(amount)",
            WireJSON.stringField("currency", currency),
            WireJSON.stringField("targetPackageName", targetPackageName),
            WireJSON.stringField("targetScheme", targetScheme),
            WireJSON.stringField("attemptId", attemptId),
            WireJSON.stringField("attemptCode", attemptCode),
            WireJSON.stringField("acquirerCode", acquirerCode),
            WireJSON.stringField("merchantId", merchantId)
        ]
        if let subMerchantId = subMerchantId { fields.append(WireJSON.stringField("subMerchantId", subMerchantId)) }
        return WireJSON.object(fields)
    }

    static func fromJson(_ json: String) -> WireRefundRequest? {
        guard let terminalId = WireJSON.extractString(json, "terminalId"),
              let orderId = WireJSON.extractString(json, "orderid") ?? WireJSON.extractString(json, "orderId"),
              let amount = WireJSON.extractLong(json, "amount"),
              let currency = WireJSON.extractString(json, "currency"),
              let targetPackageName = WireJSON.extractString(json, "targetPackageName"),
              let merchantId = WireJSON.extractString(json, "merchantId")
        else { return nil }
        let targetScheme = WireJSON.extractString(json, "targetScheme") ?? "ezypos://"
        let attemptCode = WireJSON.extractString(json, "attemptCode")
            ?? WireJSON.extractString(json, "acquirerCode") ?? ""
        let attemptId = WireJSON.extractString(json, "attemptId") ?? RefundAttemptIdResolver.defaultAttemptId(orderId)
        return WireRefundRequest(
            terminalId: terminalId,
            orderId: orderId,
            amount: amount,
            currency: currency,
            targetPackageName: targetPackageName,
            targetScheme: targetScheme,
            acquirerCode: WireJSON.extractString(json, "acquirerCode") ?? attemptCode,
            merchantId: merchantId,
            attemptId: attemptId,
            attemptCode: attemptCode,
            subMerchantId: WireJSON.extractString(json, "subMerchantId")
        )
    }
}
