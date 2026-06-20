import Foundation

public enum PaymentStatus: String, Codable, Sendable {
    case approved
    case declined
    case cancelled
    case error
}

public struct PaymentResult: Codable, Sendable {
    public let terminalId: String
    public let status: PaymentStatus
    public let transactionId: String?
    public let amount: Int64
    public let currency: String
    public let message: String?

    public init(
        terminalId: String,
        status: PaymentStatus,
        transactionId: String? = nil,
        amount: Int64,
        currency: String,
        message: String? = nil
    ) {
        self.terminalId = terminalId
        self.status = status
        self.transactionId = transactionId
        self.amount = amount
        self.currency = currency
        self.message = message
    }

    static func fromJSON(_ json: String) -> PaymentResult? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PaymentResult.self, from: data)
    }
}

public struct POSRouterError: Error, Sendable {
    public let code: String
    public let message: String
}
