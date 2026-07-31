import XCTest
@testable import POSRouter

/// Round-trips + field checks for the Lensing wire format (must stay byte-compatible with Android
/// / demo-website peers).
final class WireFormatTests: XCTestCase {
    private let config = POSRouterConfig(
        participantCode: "GPOS", participantKey: "key", terminalId: "TID001",
        acquirerCode: "SUPY", merchantId: "abc123", subMerchantId: "shop9",
        callbackUrl: "gomenu://pay_result", currency: "NZD"
    )
    private var routing: AcquirerRouting {
        AcquirerRegistry.shared.resolve(config)
    }

    func testPayWireContainsCanonicalFields() {
        let req = PaymentRequest(terminalId: "TID001", amount: 6600, orderId: "ORD1", remark: "Table 5", method: "emv_card")
        let wire = req.toWire(config: config, routing: routing, resolvedAttemptId: "ORD1#1")
        let json = wire.toJsonString()
        XCTAssertTrue(json.contains("\"terminalId\":\"TID001\""))
        XCTAssertTrue(json.contains("\"amount\":6600"))            // number, not string
        XCTAssertTrue(json.contains("\"currency\":\"NZD\""))
        XCTAssertTrue(json.contains("\"orderId\":\"ORD1\""))
        XCTAssertTrue(json.contains("\"attemptId\":\"ORD1#1\""))
        XCTAssertTrue(json.contains("\"acquirerCode\":\"SUPY\""))
        XCTAssertTrue(json.contains("\"merchantId\":\"abc123\""))
        XCTAssertTrue(json.contains("\"targetScheme\":\"ezypos://\""))
        XCTAssertTrue(json.contains("\"method\":\"emv_card\""))
        XCTAssertTrue(json.contains("\"metadata\":{}"))
    }

    func testPayWireRoundTrip() {
        let req = PaymentRequest(terminalId: "TID001", amount: 1250, orderId: "ORD9", remark: "r",
                                 metadata: ["k": "v"], subMerchantId: "shop9")
        let wire = req.toWire(config: config, routing: routing, resolvedAttemptId: "ORD9#1")
        let parsed = WirePaymentRequest.fromJson(wire.toJsonString())
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.orderId, "ORD9")
        XCTAssertEqual(parsed?.amount, 1250)
        XCTAssertEqual(parsed?.acquirerCode, "SUPY")
        XCTAssertEqual(parsed?.subMerchantId, "shop9")
        XCTAssertEqual(parsed?.attemptId, "ORD9#1")
    }

    func testResultRoundTripAndStatusLowercasing() {
        let result = PaymentResult(
            terminalId: "TID001", status: .approved, transactionId: "TX7", amount: 6600,
            currency: "NZD", message: "ok", orderId: "ORD1", attemptId: "ORD1#1",
            metadata: ["cancelReason": "user_cancel"]
        )
        let json = result.toJsonString()
        XCTAssertTrue(json.contains("\"status\":\"approved\""))
        let parsed = PaymentResult.fromJson(json)
        XCTAssertEqual(parsed.status, .approved)
        XCTAssertEqual(parsed.transactionId, "TX7")
        XCTAssertEqual(parsed.orderId, "ORD1")
        XCTAssertEqual(parsed.attemptId, "ORD1#1")
        XCTAssertEqual(parsed.metadata["cancelReason"], "user_cancel")
    }

    func testResultParsesLegacyOrderidKey() {
        let json = "{\"terminalId\":\"T\",\"status\":\"cancelled\",\"amount\":0,\"currency\":\"NZD\",\"orderid\":\"O2\"}"
        let parsed = PaymentResult.fromJson(json)
        XCTAssertEqual(parsed.status, .cancelled)
        XCTAssertEqual(parsed.orderId, "O2")
        XCTAssertEqual(parsed.attemptId, "O2#1")  // default attempt id derived
    }

    func testRefundWireRoundTrip() {
        let req = RefundRequest(terminalId: "TID001", orderId: "ORD1", amount: 500)
        let wire = req.toWire(config: config, routing: routing, resolvedAttemptId: "ORD1#refund")
        let parsed = WireRefundRequest.fromJson(wire.toJsonString())
        XCTAssertEqual(parsed?.orderId, "ORD1")
        XCTAssertEqual(parsed?.amount, 500)
        XCTAssertEqual(parsed?.attemptId, "ORD1#refund")
        XCTAssertEqual(parsed?.subjectScope().terminalId, "TID001")
    }

    func testVoidWireRoundTrip() {
        let v = PaymentVoidRequest(acquirerCode: "SUPY", merchantId: "abc123", subMerchantId: "shop9",
                                   terminalId: "TID001", orderId: "ORD1", attemptId: "ORD1#1")
        let parsed = PaymentVoidRequest.fromJson(v.toJsonString())
        XCTAssertEqual(parsed?.reason, "initiator_void")
        XCTAssertEqual(parsed?.attemptId, "ORD1#1")
        XCTAssertEqual(parsed?.subMerchantId, "shop9")
        XCTAssertTrue(v.toJsonString().contains("\"voidedAt\":"))   // numeric field present
    }

    func testJsonEscaping() {
        let req = PaymentRequest(terminalId: "T\"1", amount: 1, orderId: "O\\1")
        let wire = req.toWire(config: config, routing: routing, resolvedAttemptId: "a")
        let json = wire.toJsonString()
        XCTAssertTrue(json.contains("\"terminalId\":\"T\\\"1\""))
        XCTAssertTrue(json.contains("\"orderId\":\"O\\\\1\""))
    }

    func testAmountFromDecimal() {
        XCTAssertEqual(PaymentRequest.amountFromDecimal("66.00"), 6600)
        XCTAssertEqual(PaymentRequest.amountFromDecimal("12.5"), 1250)
        XCTAssertEqual(PaymentRequest.amountFromDecimal("0.01"), 1)
    }

    func testDeepLinkPayUri() {
        let req = PaymentRequest(terminalId: "TID001", amount: 6600, orderId: "ORD 1", remark: "a=b")
        let wire = req.toWire(config: config, routing: routing, resolvedAttemptId: "ORD1#1")
        let uri = LocalDeepLinkUriBuilder.buildPayUriString(wire, separator: .pipe, config: config)
        XCTAssertTrue(uri.hasPrefix("ezypos://pay?"))
        XCTAssertTrue(uri.contains("amount=66.00"))
        XCTAssertTrue(uri.contains("orderid=ORD%201"))   // space encoded
        XCTAssertTrue(uri.contains("remark=a%3Db"))       // '=' encoded
        XCTAssertTrue(uri.contains("callback_url="))
    }
}
