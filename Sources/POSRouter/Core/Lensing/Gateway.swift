import Foundation

struct GatewayResponse {
    let natsUrl: String
    let natsToken: String
}

struct LensingException: Error {
    let code: String
    let message: String
}

enum GatewayEndpoints {
    static let defaultInitUrl = "https://gateway.posrouter.com/init"

    static func initUrl(_ config: POSRouterConfig) -> String {
        resolveInit(config.gatewayBaseUrl)
    }

    static func matrixUrl(_ config: POSRouterConfig) -> String {
        replaceSuffix(resolveInit(config.gatewayBaseUrl), from: "/init", to: "/matrix")
    }

    static func resolveInit(_ gatewayBaseUrl: String?) -> String {
        guard let raw = gatewayBaseUrl?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return defaultInitUrl
        }
        if raw.lowercased().hasSuffix("/init") { return raw }
        if raw.lowercased().hasSuffix("/matrix") { return replaceSuffix(raw, from: "/matrix", to: "/init") }
        if raw.hasSuffix("/") { return raw + "init" }
        return raw + "/init"
    }

    private static func replaceSuffix(_ value: String, from: String, to: String) -> String {
        if value.lowercased().hasSuffix(from.lowercased()) {
            return String(value.dropLast(from.count)) + to
        }
        return value
    }
}

/// GET `/init` — exchanges participant HMAC creds for a short-lived NATS URL + token.
enum LensingGatewayClient {
    static func fetchNatsCredentials(
        code: String,
        key: String,
        initUrl: String = GatewayEndpoints.defaultInitUrl
    ) async throws -> GatewayResponse {
        let timestamp = String(nowMillis())
        let signature = LensingCrypto.computeSignature(key: key, timestamp: timestamp)
        guard let url = URL(string: "\(initUrl)?code=\(code)") else {
            throw LensingException(code: "INVALID_URL", message: "Invalid gateway URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(timestamp, forHTTPHeaderField: "X-PR-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-PR-Signature")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LensingException(code: "NETWORK_ERROR", message: "Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw LensingException(code: "GATEWAY_ERROR", message: body)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let natsUrl = obj["nats_url"] as? String,
              let natsToken = obj["nats_token"] as? String else {
            throw LensingException(code: "GATEWAY_ERROR", message: "Malformed /init response")
        }
        return GatewayResponse(natsUrl: natsUrl, natsToken: natsToken)
    }
}

/// GET `/matrix` — resolves an acquirer registry code to an iOS URL scheme.
enum LensingDirectoryClient {
    static func fetchRoutingMatrix(
        acquirerCode: String,
        participantCode: String,
        participantKey: String,
        matrixUrl: String
    ) async -> AcquirerRouting? {
        let timestamp = String(nowMillis())
        let signature = LensingCrypto.computeSignature(key: participantKey, timestamp: timestamp)
        guard let url = URL(string: "\(matrixUrl)?code=\(acquirerCode.uppercased())") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(timestamp, forHTTPHeaderField: "X-PR-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-PR-Signature")
        request.setValue(participantCode.uppercased(), forHTTPHeaderField: "X-PR-Caller")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parseMatrix(data, code: acquirerCode.uppercased())
        } catch {
            return nil
        }
    }

    /// iOS routing needs a URL scheme, not an Android package. The matrix carries platform sections;
    /// prefer an explicit `ios.scheme`, else reuse the `android.scheme`, else `<code>://`.
    private static func parseMatrix(_ data: Data, code: String) -> AcquirerRouting? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ios = json["ios"] as? [String: Any]
        let android = json["android"] as? [String: Any]
        let rawScheme = (ios?["scheme"] as? String)
            ?? (android?["scheme"] as? String)
            ?? code.lowercased()
        let scheme = rawScheme.contains("://") ? rawScheme : "\(rawScheme)://"
        // packageName is Android-only; kept for wire symmetry, unused on iOS launch.
        let packageName = (android?["package_name"] as? String) ?? ""
        return AcquirerRouting(code: code, packageName: packageName, scheme: scheme)
    }
}
