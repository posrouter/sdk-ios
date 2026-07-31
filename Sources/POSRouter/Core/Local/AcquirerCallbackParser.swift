import Foundation

/// Parses acquirer reverse-callback URLs (`{scheme}://pay_result?...`). Level 1: host and query are
/// normative; scheme varies by terminal app. Mirrors the Android `AcquirerCallbackParser`.
enum AcquirerCallbackParser {
    private static let payResultHost = "pay_result"

    static func isPayResultCallback(_ url: URL) -> Bool {
        (url.host ?? "").caseInsensitiveCompare(payResultHost) == .orderedSame
    }

    static func parsePayCallback(_ url: URL, config: POSRouterConfig, session: WirePaymentRequest?) -> PaymentResult? {
        guard isPayResultCallback(url) else { return nil }
        let q = queryItems(url)

        let type = (q["type"] ?? "").uppercased()
        if !type.isEmpty && !isPayCallbackType(type) { return nil }

        guard let orderId = q["orderid"] ?? q["orderId"] else { return nil }
        let statusRaw = q["status"] ?? ""
        let transactionId = q["transactionid"] ?? q["transactionId"] ?? q["trxid"]
        let attemptId = q["attemptid"] ?? q["attemptId"] ?? session?.attemptId
        let message = q["message"] ?? (statusRaw.isEmpty ? nil : statusRaw)
        let cancelReasonRaw = q["cancel_reason"] ?? q["cancelReason"]

        var metadata: [String: String] = [:]
        if let reason = cancelReasonRaw?.trimmingCharacters(in: .whitespaces), !reason.isEmpty {
            metadata["cancelReason"] = reason
        }
        let status = resolvePayStatus(statusRaw, cancelReasonRaw, message)

        return PaymentResult(
            terminalId: session?.terminalId ?? config.terminalId,
            status: status,
            transactionId: transactionId,
            amount: session?.amount ?? 0,
            currency: session?.currency ?? config.currency,
            message: message,
            orderId: orderId,
            attemptId: attemptId,
            attemptCode: session?.attemptCode,
            subMerchantId: session?.subMerchantId,
            metadata: metadata
        )
    }

    static func parseRefundCallback(_ url: URL, config: POSRouterConfig) -> PaymentResult? {
        guard isPayResultCallback(url) else { return nil }
        let q = queryItems(url)
        guard (q["type"] ?? "").uppercased() == "REFUND" else { return nil }
        guard let orderId = q["orderid"] ?? q["orderId"] else { return nil }

        let statusRaw = q["status"] ?? ""
        let transactionId = q["transactionid"] ?? q["transactionId"] ?? q["trxid"]
        let attemptId = q["attemptid"] ?? q["attemptId"] ?? RefundAttemptIdResolver.defaultAttemptId(orderId)
        let pending = RefundAttemptRegistry.shared.lookup(config.terminalId, orderId, attemptId)

        return PaymentResult(
            terminalId: pending?.terminalId ?? config.terminalId,
            status: mapStatus(statusRaw),
            transactionId: transactionId,
            amount: pending?.amount ?? 0,
            currency: pending?.currency ?? config.currency,
            message: q["message"] ?? (statusRaw.isEmpty ? nil : statusRaw),
            orderId: orderId,
            attemptId: attemptId,
            attemptCode: pending?.attemptCode,
            subMerchantId: pending?.subMerchantId,
            metadata: ["operation": "refund"]
        )
    }

    private static func queryItems(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items where item.value != nil {
            out[item.name] = item.value
        }
        return out
    }

    private static func isPayCallbackType(_ type: String) -> Bool {
        switch type {
        case "PAY", "CANCEL", "CANCELED", "CANCELLED": return true
        default: return false
        }
    }

    private static func mapStatus(_ raw: String) -> PaymentStatus {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "SUCCESS", "APPROVED", "OK": return .approved
        case "DECLINED", "FAILED", "FAILURE", "FAIL": return .declined
        case "CANCELLED", "CANCELED", "CANCEL", "USER_CANCEL", "USERCANCEL": return .cancelled
        default: return .error
        }
    }

    private static func resolvePayStatus(_ statusRaw: String, _ cancelReasonRaw: String?, _ message: String?) -> PaymentStatus {
        let reason = (cancelReasonRaw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if reason == PaymentCancelReason.userCancel || reason == PaymentCancelReason.initiatorVoid {
            return .cancelled
        }
        let mapped = mapStatus(statusRaw)
        if mapped == .cancelled { return .cancelled }
        if mapped != .approved && messageIndicatesUserCancel(message) { return .cancelled }
        return mapped
    }

    static func messageIndicatesUserCancel(_ message: String?) -> Bool {
        let normalized = (message ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.isEmpty { return false }
        return cancelMessageKeywords.contains { normalized.contains($0) }
    }

    private static let cancelMessageKeywords = [
        "cancel", "cancelled", "canceled", "user abort", "aborted", "trans cancel",
        "transaction cancel", "user cancel", "payment cancel", "操作取消", "用户取消", "交易取消"
    ]
}
