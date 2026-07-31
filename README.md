# POSRouter iOS SDK

Pure Swift native iOS SDK (Swift Package Manager ready) for the **Lensing Protocol V1.6**.
A-side (initiator / POS) feature-parity with the Android SDK: `connect` / `pay` / `refund` /
`voidPayment`, route preferences, six-segment V1.6 subjects, Gateway `/init` HMAC + `/matrix`
directory, connection-state indicator, and acquirer callback parsing.

> **Scope:** this SDK is the **initiator (A-side)**. The Android SDK also ships a B-side *terminal*
> mode (a foreground service that receives remote pays and drives a local acquirer). iOS cannot host
> a background acquirer terminal, so terminal mode has no iOS equivalent and is intentionally omitted.

## Install

```swift
.package(url: "https://github.com/posrouter/sdk-ios.git", from: "1.6.0")
```

## Usage

```swift
import POSRouter

POSRouter.shared.initialize(config: POSRouterConfig(
    participantCode: "GPOS",              // your identity
    participantKey: "your-participant-key",
    terminalId: "TID001",
    acquirerCode: "SUPY",                 // partner registry code to pay
    merchantId: "abc123",
    callbackUrl: "gomenu://pay_result",   // your app's return URL scheme
    currency: "NZD"
    // gatewayBaseUrl: "https://xxx.vercel.app/init"   // optional staging override
))

final class Handler: POSRouterCallback {
    func onResult(_ result: PaymentResult) { /* approved / declined / cancelled / error */ }
    func onError(_ error: POSRouterError) { }
    func onInitiatorVoided(_ result: PaymentResult) { }   // optional
}

POSRouter.shared.pay(
    request: PaymentRequest(terminalId: "TID001", amount: 1250, orderId: "ORDER-9"),
    callback: Handler()
)
```

Prefer a closure? Use `POSRouterResultCallback`:

```swift
POSRouter.shared.pay(request: req, callback: POSRouterResultCallback { result in
    switch result {
    case .success(let r): print(r.status)
    case .failure(let e): print(e.code, e.message)
    }
})
```

### Acquirer callback

Forward the acquirer's return URL from your `AppDelegate` / `SceneDelegate` / SwiftUI `onOpenURL`:

```swift
func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
    POSRouter.shared.deliverAcquirerCallback(url) != nil
}
```

Add the acquirer scheme(s) you launch to `Info.plist` `LSApplicationQueriesSchemes` (e.g. `ezypos`)
so `canOpenURL` can probe the local acquirer.

### Routing

Default is `auto` (optimistic local launch → NATS on failure). Override per session or per call:

| Value | Behaviour |
|-------|-----------|
| `auto` | local when reachable → NATS fallback (default) |
| `local_first` | always try local first → NATS fallback |
| `remote_first` | skip local; NATS only |
| `local_only` | local only; error on failure |
| `remote_only` | NATS only; never launch local acquirer |
| `local_posrouter_kiosk` | same-device POSRouter Kiosk method picker (`posrouter-kiosk://charge`) |

```swift
POSRouter.shared.setRoutePreference(RoutePreference.remoteFirst)
POSRouter.shared.pay(request: req, callback: cb, routePreference: RoutePreference.remoteOnly)
```

### Refund & void

```swift
POSRouter.shared.refund(request: RefundRequest(terminalId: "TID001", orderId: "ORDER-9", amount: 500), callback: cb)
POSRouter.shared.voidPayment(orderId: "ORDER-9")   // soft void; callback resolves cancelled when the terminal acks
```

### Connection status

```swift
POSRouter.shared.setTerminalListener(listener)                 // onLensingStateChanged / onPaymentCompleted
let state = POSRouter.shared.currentLensingState()             // .connected / .connecting / ...
let argb  = POSRouter.shared.lensingIndicatorColor()           // packed ARGB, same palette as Android
let (r, g, b, a) = LensingConnectionIndicator.rgba(state)      // SwiftUI/UIKit components
```

| State | Indicator |
|---|---|
| `connected` | Green `#22C55E` |
| `discovering` / `connecting` / `reconnecting` | Amber `#F59E0B` |
| `failed` | Red `#EF4444` |
| `offline` | Slate `#94A3B8` |

Call `POSRouter.shared.refreshLensingConnection(backgroundMs:)` when returning from background, and
`reconnectLensing()` to force a fresh Gateway discovery + NATS session.

## Wire compatibility

Subjects, HMAC, and the pay/result/refund/void/claim JSON payloads are byte-compatible with the
Android SDK and the `demo-website` bridge (six-segment `lensing.{ACQ}.{merchant}.{sub|_}.{tid}.{verb}`,
`HMAC-SHA256(key, key+timestamp)` hex).

**Version scheme:** SDK `1.6.x` implements Lensing Protocol **V1.6**.

## Build & test

```bash
swift build      # host (macOS) build
swift test       # 36 unit tests (subjects, wire round-trips, crypto golden, routing, callbacks, dedup)
xcodebuild -scheme POSRouter -destination 'generic/platform=iOS Simulator' build   # iOS build
```

> The end-to-end connected path (Gateway discovery → NATS → pay → result) requires a live broker and
> a `GPOS` participant key; it is exercised via the demo apps. Unit tests cover every deterministic,
> platform-independent unit. The NATS session is fully encapsulated behind an internal
> `LensingTransport`, so the engine is testable with a fake transport (see `EngineOfflineTests`).
