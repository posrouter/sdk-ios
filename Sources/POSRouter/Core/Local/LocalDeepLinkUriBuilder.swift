import Foundation

/// Builds acquirer deep-link URL strings (`{scheme}://pay|connect|refund?...`) using the Lens
/// partial-encoding + configured separator. Matches the Android `LocalDeepLinkUriBuilder`.
enum LocalDeepLinkUriBuilder {
    static func buildPayUriString(_ request: WirePaymentRequest, separator: LocalParamSeparator, config: POSRouterConfig?) -> String {
        let scheme = parseScheme(request.targetScheme)
        var pairs = [
            LensLocalEncoder.pair("amount", LensLocalEncoder.formatAmountDecimal(request.amount), separator),
            LensLocalEncoder.pair("currency", request.currency, separator),
            LensLocalEncoder.pair("orderid", request.orderId, separator)
        ]
        if let remark = request.remark { pairs.append(LensLocalEncoder.pair("remark", remark, separator)) }
        if let method = request.method { pairs.append(LensLocalEncoder.pair("method", method, separator)) }
        if let callbackUrl = config?.callbackUrl { pairs.append(LensLocalEncoder.pair("callback_url", callbackUrl, separator)) }
        return "\(scheme)://pay?\(LensLocalEncoder.joinPairs(pairs, separator))"
    }

    static func buildConnectUriString(_ config: POSRouterConfig) -> String {
        let routing = AcquirerRegistry.shared.resolve(config)
        let scheme = parseScheme(routing.schemeUri)
        let separator = config.localParamSeparator
        var pairs = [LensLocalEncoder.pair("merchantid", config.merchantId, separator)]
        if let callbackUrl = config.callbackUrl { pairs.append(LensLocalEncoder.pair("callback_url", callbackUrl, separator)) }
        return "\(scheme)://connect?\(LensLocalEncoder.joinPairs(pairs, separator))"
    }

    static func buildRefundUriString(_ request: WireRefundRequest, separator: LocalParamSeparator) -> String {
        let scheme = parseScheme(request.targetScheme)
        let pairs = [
            LensLocalEncoder.pair("amount", LensLocalEncoder.formatAmountDecimal(request.amount), separator),
            LensLocalEncoder.pair("orderid", request.orderId, separator)
        ]
        return "\(scheme)://refund?\(LensLocalEncoder.joinPairs(pairs, separator))"
    }

    private static func parseScheme(_ targetScheme: String) -> String {
        let normalized = targetScheme.contains("://") ? targetScheme : "\(targetScheme)://"
        let head = normalized.components(separatedBy: "://").first ?? ""
        return head.isEmpty ? "ezypos" : head
    }
}
