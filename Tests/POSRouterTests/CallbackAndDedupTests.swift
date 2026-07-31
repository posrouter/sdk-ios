import XCTest
@testable import POSRouter

final class AcquirerCallbackParserTests: XCTestCase {
    private let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "TID001",
                                         acquirerCode: "SUPY", merchantId: "m", currency: "NZD")

    func testParsePaySuccess() {
        let url = URL(string: "gomenu://pay_result?type=PAY&status=SUCCESS&orderid=ORD1&transactionid=TX9")!
        let result = AcquirerCallbackParser.parsePayCallback(url, config: config, session: nil)
        XCTAssertEqual(result?.status, .approved)
        XCTAssertEqual(result?.orderId, "ORD1")
        XCTAssertEqual(result?.transactionId, "TX9")
    }

    func testParseUserCancelByReason() {
        let url = URL(string: "posrouter-kiosk://pay_result?status=FAILED&orderid=ORD1&cancel_reason=user_cancel")!
        let result = AcquirerCallbackParser.parsePayCallback(url, config: config, session: nil)
        XCTAssertEqual(result?.status, .cancelled)
        XCTAssertEqual(result?.metadata["cancelReason"], "user_cancel")
    }

    func testCancelInferredFromMessageKeyword() {
        let url = URL(string: "gomenu://pay_result?status=FAILED&orderid=ORD1&message=Transaction%20cancelled%20by%20user")!
        let result = AcquirerCallbackParser.parsePayCallback(url, config: config, session: nil)
        XCTAssertEqual(result?.status, .cancelled)
    }

    func testNonPayResultHostIgnored() {
        let url = URL(string: "gomenu://something?orderid=ORD1")!
        XCTAssertNil(AcquirerCallbackParser.parsePayCallback(url, config: config, session: nil))
    }

    func testRefundCallback() {
        let url = URL(string: "gomenu://pay_result?type=REFUND&status=SUCCESS&orderid=ORD1")!
        let result = AcquirerCallbackParser.parseRefundCallback(url, config: config)
        XCTAssertEqual(result?.status, .approved)
        XCTAssertEqual(result?.metadata["operation"], "refund")
    }
}

final class DedupAndRegistryTests: XCTestCase {
    func testResultLedgerDedupes() {
        let ledger = PaymentResultLedger()
        let r = PaymentResult(terminalId: "T\(UUID().uuidString)", status: .approved, amount: 1, currency: "NZD",
                              orderId: "O", attemptId: "O#1")
        XCTAssertTrue(ledger.markIfFirst(r))
        XCTAssertFalse(ledger.markIfFirst(r))
    }

    func testClaimFirstWriterWins() {
        let reg = PaymentClaimRegistry()
        let tid = "T\(UUID().uuidString)"
        XCTAssertTrue(reg.tryAcquireClaim(tid, "O", "O#1"))
        XCTAssertFalse(reg.tryAcquireClaim(tid, "O", "O#1"))
        reg.releaseClaim(tid, "O", "O#1")
        XCTAssertTrue(reg.tryAcquireClaim(tid, "O", "O#1"))
    }

    func testAttemptIdResolverAutoNumbers() {
        let resolver = PaymentAttemptIdResolver()
        XCTAssertEqual(resolver.resolve(orderId: "O", explicit: "custom"), "custom")
        XCTAssertEqual(resolver.resolve(orderId: "O", explicit: nil), "O#1")
        XCTAssertEqual(resolver.resolve(orderId: "O", explicit: nil), "O#2")
    }

    func testRefundAttemptIdDefault() {
        XCTAssertEqual(RefundAttemptIdResolver.defaultAttemptId("O"), "O#refund")
        XCTAssertEqual(RefundAttemptIdResolver.resolve(orderId: "O", attemptId: nil), "O#refund")
        XCTAssertEqual(RefundAttemptIdResolver.resolve(orderId: "O", attemptId: "X"), "X")
    }

    func testAttemptRegistryDeliversCallbackOnce() {
        let reg = PaymentAttemptRegistry()
        let tid = "T\(UUID().uuidString)"
        let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: tid,
                                     acquirerCode: "SUPY", merchantId: "m")
        let wire = PaymentRequest(terminalId: tid, amount: 1, orderId: "O")
            .toWire(config: config, routing: AcquirerRegistry.shared.resolve(config), resolvedAttemptId: "O#1")

        let exp = expectation(description: "callback")
        final class CB: POSRouterCallback {
            let onDone: (PaymentResult) -> Void
            init(_ f: @escaping (PaymentResult) -> Void) { onDone = f }
            func onResult(_ result: PaymentResult) { onDone(result) }
            func onError(_ error: POSRouterError) {}
        }
        let cb = CB { r in
            XCTAssertEqual(r.orderId, "O")
            exp.fulfill()
        }
        reg.store(wire, callback: cb)
        let result = PaymentResult(terminalId: tid, status: .approved, amount: 1, currency: "NZD",
                                   orderId: "O", attemptId: "O#1")
        XCTAssertTrue(reg.deliverCallback(result))
        XCTAssertFalse(reg.deliverCallback(result))  // already removed
        waitForExpectations(timeout: 2)
    }
}

final class IndicatorColorTests: XCTestCase {
    func testColors() {
        XCTAssertEqual(LensingConnectionIndicator.colorArgb(.connected), 0xFF22C55E)
        XCTAssertEqual(LensingConnectionIndicator.colorArgb(.connecting), 0xFFF59E0B)
        XCTAssertEqual(LensingConnectionIndicator.colorArgb(.reconnecting), 0xFFF59E0B)
        XCTAssertEqual(LensingConnectionIndicator.colorArgb(.failed), 0xFFEF4444)
        XCTAssertEqual(LensingConnectionIndicator.colorArgb(.offline), 0xFF94A3B8)
    }

    func testRgbaComponents() {
        let (r, g, b, a) = LensingConnectionIndicator.rgba(.connected)
        XCTAssertEqual(a, 1.0, accuracy: 0.001)
        XCTAssertEqual(r, Double(0x22) / 255.0, accuracy: 0.001)
        XCTAssertEqual(g, Double(0xC5) / 255.0, accuracy: 0.001)
        XCTAssertEqual(b, Double(0x5E) / 255.0, accuracy: 0.001)
    }
}
