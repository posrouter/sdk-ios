import XCTest
@testable import POSRouter

final class LensingCryptoTests: XCTestCase {
    private let key = "GPOS_TEST_SECRET_KEY"
    private let timestamp = "1718800000000"

    func testComputeSignatureIsDeterministic() {
        let sig1 = LensingCrypto.computeSignature(key: key, timestamp: timestamp)
        let sig2 = LensingCrypto.computeSignature(key: key, timestamp: timestamp)
        XCTAssertEqual(sig1, sig2)
        XCTAssertTrue(sig1.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }

    func testComputeSignatureDiffersForDifferentKeys() {
        let sig1 = LensingCrypto.computeSignature(key: key, timestamp: timestamp)
        let sig2 = LensingCrypto.computeSignature(key: "OTHER_KEY", timestamp: timestamp)
        XCTAssertNotEqual(sig1, sig2)
    }

    func testGoldenSignatureMatchesGatewayReference() {
        let expected = "f4635e7c3db0a72a87b69be7000023ae9fe3e4b7ec87e83047b7a90e17fb876a"
        let actual = LensingCrypto.computeSignature(key: key, timestamp: timestamp)
        XCTAssertEqual(expected, actual)
    }
