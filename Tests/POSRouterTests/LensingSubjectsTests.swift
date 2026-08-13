import XCTest
@testable import POSRouter

final class LensingSubjectsTests: XCTestCase {
    private let scope = LensingSubjectScope(
        acquirerCode: "supy", merchantId: "abc123", subMerchantId: nil, terminalId: "TID001"
    )

    func testSixSegmentPaySubjectUppercasesAcquirerAndUsesPlaceholder() {
        XCTAssertEqual(LensingSubjects.paySubject(scope), "lensing.SUPY.abc123._.TID001.pay")
    }

    func testAllVerbs() {
        XCTAssertEqual(LensingSubjects.resultSubject(scope), "lensing.SUPY.abc123._.TID001.result")
        XCTAssertEqual(LensingSubjects.claimedSubject(scope), "lensing.SUPY.abc123._.TID001.claimed")
        XCTAssertEqual(LensingSubjects.voidSubject(scope), "lensing.SUPY.abc123._.TID001.void")
        XCTAssertEqual(LensingSubjects.refundSubject(scope), "lensing.SUPY.abc123._.TID001.refund")
        XCTAssertEqual(LensingSubjects.terminalWildcard(scope), "lensing.SUPY.abc123._.TID001.>")
    }

    func testSubMerchantSegmentUsesRealValue() {
        let s = LensingSubjectScope(acquirerCode: "SUPY", merchantId: "m", subMerchantId: "shop9", terminalId: "T")
        XCTAssertEqual(LensingSubjects.paySubject(s), "lensing.SUPY.m.shop9.T.pay")
    }

    func testBlankSubMerchantFallsBackToPlaceholder() {
        XCTAssertEqual(LensingSubjects.subMerchantSegment("   "), "_")
        XCTAssertEqual(LensingSubjects.subMerchantSegment(nil), "_")
        XCTAssertEqual(LensingSubjects.subMerchantSegment("shopA"), "shopA")
    }
}
