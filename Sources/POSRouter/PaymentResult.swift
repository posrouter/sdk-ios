import Foundation

public enum PaymentStatus: String, Sendable {
    case approved
    case declined
    case cancelled
    case error
}

public struct PaymentResult: Sendable {
    public let terminalId: String
    public let status: PaymentStatus
    public let transactionId: String?
    public let amount: Int64
    public let currency: String
    public let message: String?
    public let orderId: String?
    public let attemptId: String?
    public let attemptCode: String?
    public let subMerchantId: String?
    public let localRouteMethod: LocalRouteMethod?
    public let metadata: [String: String]

    public init(
        terminalId: String,
        status: PaymentStatus,
        transactionId: String? = nil,
        amount: Int64,
        currency: String,
        message: String? = nil,
        orderId: String? = nil,
        attemptId: String? = nil,
        attemptCode: String? = nil,
        subMerchantId: String? = nil,
        localRouteMethod: LocalRouteMethod? = nil,
        metadata: [String: String] = [:]
    ) {
        self.terminalId = terminalId
        self.status = status
        self.transactionId = transactionId
        self.amount = amount
        self.currency = currency
        self.message = message
        self.orderId = orderId
        self.attemptId = attemptId
        self.attemptCode = attemptCode
        self.subMerchantId = subMerchantId
        self.localRouteMethod = localRouteMethod
        self.metadata = metadata
    }

    func with(terminalId newTerminalId: String) -> PaymentResult {
        PaymentResult(
            terminalId: newTerminalId, status: status, transactionId: transactionId,
            amount: amount, currency: currency, message: message, orderId: orderId,
            attemptId: attemptId, attemptCode: attemptCode, subMerchantId: subMerchantId,
            localRouteMethod: localRouteMethod, metadata: metadata
        )
    }

    func merging(metadata extra: [String: String]) -> PaymentResult {
        PaymentResult(
            terminalId: terminalId, status: status, transactionId: transactionId,
            amount: amount, currency: currency, message: message, orderId: orderId,
            attemptId: attemptId, attemptCode: attemptCode, subMerchantId: subMerchantId,
            localRouteMethod: localRouteMethod, metadata: metadata.merging(extra) { _, new in new }
        )
    }

    func toJsonString() -> String {
        var fields = [
            WireJSON.stringField("terminalId", terminalId),
            WireJSON.stringField("status", status.rawValue),
            "\"amount\":\(amount)",
            WireJSON.stringField("currency", currency)
        ]
        if let orderId = orderId { fields.append(WireJSON.stringField("orderId", orderId)) }
        if let attemptId = attemptId { fields.append(WireJSON.stringField("attemptId", attemptId)) }
        if let attemptCode = attemptCode { fields.append(WireJSON.stringField("attemptCode", attemptCode)) }
        if let subMerchantId = subMerchantId { fields.append(WireJSON.stringField("subMerchantId", subMerchantId)) }
        if let transactionId = transactionId { fields.append(WireJSON.stringField("transactionId", transactionId)) }
        if let message = message { fields.append(WireJSON.stringField("message", message)) }
        if !metadata.isEmpty {
            let inner = metadata.map { WireJSON.stringField($0.key, $0.value) }.joined(separator: ",")
            fields.append("\"metadata\":{\(inner)}")
        }
        return WireJSON.object(fields)
    }

    static func fromJson(_ json: String) -> PaymentResult {
        let statusStr = (WireJSON.extractString(json, "status") ?? "error").lowercased()
        let status: PaymentStatus
        switch statusStr {
        case "approved": status = .approved
        case "declined": status = .declined
        case "cancelled": status = .cancelled
        default: status = .error
        }
        let orderId = WireJSON.extractString(json, "orderId") ?? WireJSON.extractString(json, "orderid")
        let attemptId = WireJSON.extractString(json, "attemptId")
            ?? orderId.map { PaymentAttemptKey.defaultAttemptId($0) }
        return PaymentResult(
            terminalId: WireJSON.extractString(json, "terminalId") ?? "",
            status: status,
            transactionId: WireJSON.extractString(json, "transactionId"),
            amount: WireJSON.extractLong(json, "amount") ?? 0,
            currency: WireJSON.extractString(json, "currency") ?? "",
            message: WireJSON.extractString(json, "message"),
            orderId: orderId,
            attemptId: attemptId,
            attemptCode: WireJSON.extractString(json, "attemptCode"),
            subMerchantId: WireJSON.extractString(json, "subMerchantId"),
            metadata: WireJSON.extractMetadata(json)
        )
    }
}
