import XCTest
@testable import POSRouter

final class PaymentRequestTests: XCTestCase {
    func testJSONContainsLensingFields() {
        let request = PaymentRequest(
            terminalId: "TID001",
            amount: 1250,
            currency: "USD",
            targetScheme: "ezypos://"
        )
        let json = request.toJSONString()
        XCTAssertTrue(json.contains("TID001"))
        XCTAssertTrue(json.contains("1250"))
        XCTAssertTrue(json.contains("USD"))
        XCTAssertTrue(json.contains("ezypos://"))
    }
}
