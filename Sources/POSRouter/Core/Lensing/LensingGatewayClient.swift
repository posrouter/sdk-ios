import Foundation

struct GatewayResponse: Decodable {
    let natsUrl: String
    let natsToken: String

    enum CodingKeys: String, CodingKey {
        case natsUrl = "nats_url"
        case natsToken = "nats_token"
    }
}

enum LensingGatewayClient {
    private static let gatewayBaseURL = "https://lensing.starrie.org/init"

    static func fetchNatsCredentials(code: String, key: String) async throws -> GatewayResponse {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let signature = LensingCrypto.computeSignature(key: key, timestamp: timestamp)

        guard let url = URL(string: "\(gatewayBaseURL)?code=\(code)") else {
            throw POSRouterError(code: "INVALID_URL", message: "Invalid gateway URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(timestamp, forHTTPHeaderField: "X-PR-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-PR-Signature")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw POSRouterError(code: "NETWORK_ERROR", message: "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw POSRouterError(code: "GATEWAY_ERROR", message: body)
        }

        return try JSONDecoder().decode(GatewayResponse.self, from: data)
    }
}
