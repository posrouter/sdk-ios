import Foundation

public struct PaymentRequest: Codable, Sendable {
    public let terminalId: String
    public let amount: Int64
    public let currency: String
    public let targetScheme: String
    public let metadata: [String: String]

    public init(
        terminalId: String,
        amount: Int64,
        currency: String,
        targetScheme: String,
        metadata: [String: String] = [:]
    ) {
        self.terminalId = terminalId
        self.amount = amount
        self.currency = currency
        self.targetScheme = targetScheme
        self.metadata = metadata
    }

    func toJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
