import Foundation

enum LensingState {
    case idle
    case discovering
    case connecting
    case connected
    case reconnecting
    case failed

    var publicState: LensingConnectionState {
        switch self {
        case .idle: return .offline
        case .discovering: return .discovering
        case .connecting: return .connecting
        case .connected: return .connected
        case .reconnecting: return .reconnecting
        case .failed: return .failed
        }
    }
}
