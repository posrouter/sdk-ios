import Foundation

struct PaymentVoidRequest {
    let acquirerCode: String
    let merchantId: String
    let subMerchantId: String?
    let terminalId: String
    let orderId: String
    let attemptId: String
    var reason: String = reasonInitiatorVoid
    var voidedAt: Int64 = nowMillis()

    static let reasonInitiatorVoid = "initiator_void"

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
            WireJSON.stringField("acquirerCode", acquirerCode),
            WireJSON.stringField("merchantId", merchantId),
            WireJSON.stringField("terminalId", terminalId),
            WireJSON.stringField("orderId", orderId),
            WireJSON.stringField("attemptId", attemptId),
            WireJSON.stringField("reason", reason),
            "\"voidedAt\":\(voidedAt)"
        ]
        if let subMerchantId = subMerchantId { fields.append(WireJSON.stringField("subMerchantId", subMerchantId)) }
        return WireJSON.object(fields)
    }

    static func fromJson(_ json: String) -> PaymentVoidRequest? {
        guard let terminalId = WireJSON.extractString(json, "terminalId"),
              let orderId = WireJSON.extractString(json, "orderId") ?? WireJSON.extractString(json, "orderid"),
              let acquirerCode = WireJSON.extractString(json, "acquirerCode"),
              let merchantId = WireJSON.extractString(json, "merchantId")
        else { return nil }
        let attemptId = WireJSON.extractString(json, "attemptId") ?? PaymentAttemptKey.defaultAttemptId(orderId)
        return PaymentVoidRequest(
            acquirerCode: acquirerCode,
            merchantId: merchantId,
            subMerchantId: WireJSON.extractString(json, "subMerchantId"),
            terminalId: terminalId,
            orderId: orderId,
            attemptId: attemptId,
            reason: WireJSON.extractString(json, "reason") ?? reasonInitiatorVoid,
            voidedAt: WireJSON.extractLong(json, "voidedAt") ?? nowMillis()
        )
    }
}
