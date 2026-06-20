import XCTest
@testable import POSRouter

final class LensingSubjectsTests: XCTestCase {
    func testPaySubjectFormat() {
        XCTAssertEqual(LensingSubjects.paySubject(terminalId: "TID001"), "lensing.terminal.TID001.pay")
    }

    func testResultSubjectFormat() {
        XCTAssertEqual(LensingSubjects.resultSubject(terminalId: "TID001"), "lensing.terminal.TID001.result")
    }
}
