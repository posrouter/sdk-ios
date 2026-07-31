import Foundation

/// Per-transaction payment payload. Acquirer routing targets come from ``POSRouterConfig/acquirerCode``
/// unless ``attemptCode`` overrides the pipeline for this try.
public struct PaymentRequest: Sendable {
    public let terminalId: String
    public let amount: Int64
    public let orderId: String
    public let remark: String?
    public let method: String?
    public let metadata: [String: String]
    /// Unique id for this pay try; SDK auto-generates `orderId#N` when omitted.
    public let attemptId: String?
    /// Pipeline / provider code for this try, e.g. `EZYPOS`, `SKYZER`. Defaults to config `acquirerCode`.
    public let attemptCode: String?
    /// Platform sub-merchant (e.g. restaurant on an ordering platform).
    public let subMerchantId: String?

    public init(
        terminalId: String,
        amount: Int64,
        orderId: String,
        remark: String? = nil,
        method: String? = nil,
        metadata: [String: String] = [:],
        attemptId: String? = nil,
        attemptCode: String? = nil,
        subMerchantId: String? = nil
    ) {
        self.terminalId = terminalId
        self.amount = amount
        self.orderId = orderId
        self.remark = remark
        self.method = method
        self.metadata = metadata
        self.attemptId = attemptId
        self.attemptCode = attemptCode
        self.subMerchantId = subMerchantId
    }

    public static let methodEmvCard = "emv_card"
    public static let methodShowQrCode = "show_qr_code"
    public static let methodSkyzer = "skyzer"
    public static let methodSelection = "selection"

    public static func requiresTerminalMethodSelection(_ method: String?) -> Bool {
        guard let method = method, !method.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return method.caseInsensitiveCompare(methodSelection) == .orderedSame
    }

    public enum AmountError: Error, CustomStringConvertible {
        case invalidDecimal(String)
        case overflow(String)
        public var description: String {
            switch self {
            case .invalidDecimal(let s): return "amount is not a valid decimal: \"\(s)\""
            case .overflow(let s): return "amount is out of range: \"\(s)\""
            }
        }
    }

    /// Parse a decimal amount string (e.g. `"66.00"`) into smallest currency units (cents).
    /// Throws on unparseable input or values outside `Int64` range instead of silently yielding 0
    /// (a zero-amount payment) or a clamped total. The whole string must be a valid decimal — a
    /// partial parse like `"12,50"` (which `Decimal(string:)` would truncate to `12`) is rejected.
    public static func amountFromDecimal(_ decimal: String) throws -> Int64 {
        let scanner = Scanner(string: decimal)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        guard let value = scanner.scanDecimal(), scanner.isAtEnd,
              NSDecimalNumber(decimal: value) != .notANumber else {
            throw AmountError.invalidDecimal(decimal)
        }
        let cents = NSDecimalNumber(decimal: value)
            .multiplying(by: 100)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0,
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false))
        guard cents.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              cents.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending else {
            throw AmountError.overflow(decimal)
        }
        return cents.int64Value
    }

    func toWire(
        config: POSRouterConfig,
        routing: AcquirerRouting,
        resolvedAttemptId: String
    ) -> WirePaymentRequest {
        WirePaymentRequest(
            terminalId: terminalId,
            amount: amount,
            currency: config.currency,
            targetPackageName: routing.packageName,
            targetScheme: routing.schemeUri,
            acquirerCode: routing.code,
            orderId: orderId,
            attemptId: resolvedAttemptId,
            attemptCode: routing.code,
            merchantId: config.merchantId,
            remark: remark,
            method: method ?? config.defaultPayMethod,
            subMerchantId: subMerchantId,
            metadata: metadata
        )
    }
}

/// Internal on-the-wire pay payload. Field encoding matches the Android `WirePaymentRequest`.
struct WirePaymentRequest {
    let terminalId: String
    let amount: Int64
    let currency: String
    let targetPackageName: String
    let targetScheme: String
    let acquirerCode: String
    let orderId: String
    let attemptId: String
    let attemptCode: String
    let merchantId: String
    var remark: String?
    var method: String?
    var subMerchantId: String?
    var metadata: [String: String] = [:]

    func with(method newMethod: String?) -> WirePaymentRequest {
        var copy = self
        copy.method = newMethod
        return copy
    }

    func toJsonString() -> String {
        var fields = [
            WireJSON.stringField("terminalId", terminalId),
            "\"amount\":\(amount)",
            WireJSON.stringField("currency", currency),
            WireJSON.stringField("targetPackageName", targetPackageName),
            WireJSON.stringField("targetScheme", targetScheme),
            WireJSON.stringField("orderId", orderId),
            WireJSON.stringField("attemptId", attemptId),
            WireJSON.stringField("attemptCode", attemptCode),
            WireJSON.stringField("acquirerCode", acquirerCode),
            WireJSON.stringField("merchantId", merchantId)
        ]
        if let remark = remark { fields.append(WireJSON.stringField("remark", remark)) }
        if let method = method { fields.append(WireJSON.stringField("method", method)) }
        if let subMerchantId = subMerchantId { fields.append(WireJSON.stringField("subMerchantId", subMerchantId)) }
        if metadata.isEmpty {
            fields.append("\"metadata\":{}")
        } else {
            let inner = metadata.map { WireJSON.stringField($0.key, $0.value) }.joined(separator: ",")
            fields.append("\"metadata\":{\(inner)}")
        }
        return WireJSON.object(fields)
    }

    static func fromJson(_ json: String) -> WirePaymentRequest? {
        guard let terminalId = WireJSON.extractString(json, "terminalId"),
              let amount = WireJSON.extractLong(json, "amount"),
              let currency = WireJSON.extractString(json, "currency"),
              let targetPackageName = WireJSON.extractString(json, "targetPackageName"),
              let orderId = WireJSON.extractString(json, "orderid") ?? WireJSON.extractString(json, "orderId"),
              let merchantId = WireJSON.extractString(json, "merchantId")
        else { return nil }

        let targetScheme = WireJSON.extractString(json, "targetScheme") ?? "ezypos://"
        let attemptId = WireJSON.extractString(json, "attemptId") ?? PaymentAttemptKey.defaultAttemptId(orderId)
        let attemptCode = WireJSON.extractString(json, "attemptCode")
            ?? WireJSON.extractString(json, "acquirerCode") ?? ""
        return WirePaymentRequest(
            terminalId: terminalId,
            amount: amount,
            currency: currency,
            targetPackageName: targetPackageName,
            targetScheme: targetScheme,
            acquirerCode: WireJSON.extractString(json, "acquirerCode") ?? attemptCode,
            orderId: orderId,
            attemptId: attemptId,
            attemptCode: attemptCode,
            merchantId: merchantId,
            remark: WireJSON.extractString(json, "remark"),
            method: WireJSON.extractString(json, "method"),
            subMerchantId: WireJSON.extractString(json, "subMerchantId")
        )
    }
}
