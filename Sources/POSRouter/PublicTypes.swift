import Foundation

public struct POSRouterError: Error, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Runtime routing preference for local acquirer launch vs NATS (Lensing).
/// Values are strings so apps, config, and wire formats can pass them directly.
public enum RoutePreference {
    public static let auto = "auto"
    public static let localFirst = "local_first"
    public static let remoteFirst = "remote_first"
    public static let localOnly = "local_only"
    public static let remoteOnly = "remote_only"
    /// Same-device POSRouter Kiosk method picker via `posrouter-kiosk://charge`
    /// (not local acquirer card/QR, not NATS).
    public static let localPosrouterKiosk = "local_posrouter_kiosk"

    private static let known: Set<String> = [
        auto, localFirst, remoteFirst, localOnly, remoteOnly, localPosrouterKiosk
    ]

    /// Blank or unknown values resolve to ``auto``.
    public static func normalize(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return auto }
        let normalized = value.lowercased().replacingOccurrences(of: "-", with: "_")
        return known.contains(normalized) ? normalized : auto
    }
}

/// Values for ``PaymentResult/metadata`` key `cancelReason`.
public enum PaymentCancelReason {
    /// Initiator (A-side) voided the payment request over NATS.
    public static let initiatorVoid = "initiator_void"
    /// User cancelled in the acquirer UI (Ezypos).
    public static let userCancel = "user_cancel"
}

/// How a local connect/pay call reached the acquirer app.
public enum LocalRouteMethod: String, Sendable {
    case explicitIntent
    case deepLink
    case network
}

public enum LensingConnectionState: Sendable {
    case offline
    case discovering
    case connecting
    case connected
    case reconnecting
    case failed
}

/// Canonical RGBA indicator colors for ``LensingConnectionState`` so status dots match
/// across demo, kiosk, and partner apps. Returned as a packed ARGB `UInt32` (same values
/// as the Android SDK) plus SwiftUI/UIKit-friendly component accessors.
public enum LensingConnectionIndicator {
    /// Connected — Lensing / NATS session ready. `#22C55E`.
    public static let colorConnected: UInt32 = 0xFF22C55E
    /// Discovering, connecting, or reconnecting. `#F59E0B`.
    public static let colorConnecting: UInt32 = 0xFFF59E0B
    /// Gateway discovery or session failed. `#EF4444`.
    public static let colorFailed: UInt32 = 0xFFEF4444
    /// Not initialized or idle. `#94A3B8`.
    public static let colorOffline: UInt32 = 0xFF94A3B8

    /// Half-cycle (fade in or fade out) for the connecting-state pulse animation, in seconds.
    public static let pulseHalfCycleSeconds: Double = 5.0
    public static let pulseAlphaMin: Double = 0.45
    public static let pulseAlphaMax: Double = 1.0

    public static func colorArgb(_ state: LensingConnectionState) -> UInt32 {
        switch state {
        case .connected: return colorConnected
        case .discovering, .connecting, .reconnecting: return colorConnecting
        case .failed: return colorFailed
        case .offline: return colorOffline
        }
    }

    /// (red, green, blue, alpha) components in 0...1, ready for `Color`/`UIColor`.
    public static func rgba(_ state: LensingConnectionState) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let argb = colorArgb(state)
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        return (r, g, b, a)
    }
}

public extension LensingConnectionState {
    var indicatorColorArgb: UInt32 { LensingConnectionIndicator.colorArgb(self) }
}
