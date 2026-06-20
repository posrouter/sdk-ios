import Foundation

enum LensingState {
    case idle
    case discovering
    case connecting
    case connected
    case reconnecting
    case failed
}

enum LensingSubjects {
    static func paySubject(terminalId: String) -> String {
        "lensing.terminal.\(terminalId).pay"
    }

    static func resultSubject(terminalId: String) -> String {
        "lensing.terminal.\(terminalId).result"
    }
}
