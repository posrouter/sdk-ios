# POSRouter iOS SDK — Integration Guide

This guide is for developers integrating the **POSRouter iOS SDK** into an iOS app to
take card payments through a POSRouter terminal.

Your app is the **initiator (A-side)**: it starts a payment and receives the result.
The **terminal** (a separate POSRouter device) performs the actual card transaction.
Your app never touches card data or payment hardware.

---

## 1. What you receive from us

Before you start, we (POSRouter) issue you the following. Keep the key secret — it
authenticates your app to the payment network.

| Value | Example | Notes |
|---|---|---|
| `participantCode` | `GPOS` | Your caller identity. |
| `participantKey` | *(secret)* | HMAC secret for the Gateway handshake. **Never commit it or ship it in plaintext where it can be extracted.** |
| `acquirerCode` | `SUPY` | The acquirer "rail" your payments run on. |
| `terminalId` / `merchantId` | `TID001` / `M-1001` | Identify the lane (which terminal + merchant) you transact against. |
| `currency` | `NZD` | ISO-4217 code. |
| `gatewayBaseUrl` | `https://gateway.posrouter.com` | Usually the default; we tell you if you need a different one. |
| SDK version / tag | `1.6.x` | Pin to the exact version we give you. |

---

## 2. Requirements

- iOS 14+ (Swift Package Manager).
- Swift 5.9+ / Xcode 15+.

## 3. Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter the repo URL, or add to your
`Package.swift`:

```swift
.package(url: "https://github.com/posrouter/sdk-ios.git", from: "1.6.0")
```

> Pin to the exact version/tag we provide. Then add `POSRouter` to your target's
> dependencies.

```swift
import POSRouter
```

---

## 4. Initialize (once, at app start)

```swift
POSRouter.shared.initialize(config: POSRouterConfig(
    participantCode: "GPOS",              // from us
    participantKey:  "<your-secret-key>", // from us — keep secret
    terminalId:      "TID001",
    acquirerCode:    "SUPY",              // from us
    merchantId:      "M-1001",
    callbackUrl:     "yourapp://pay_result", // your app's URL scheme (for the local track)
    currency:        "NZD"
    // gatewayBaseUrl: "https://gateway.posrouter.com"   // only if we tell you to override
))
```

`initialize` starts the connection in the background. Call it once (e.g. in your app
delegate / `App` init). Calling it again with a new config re-initializes.

## 5. Connect a lane (optional but recommended)

`connect` confirms the terminal + merchant lane is reachable before you take a payment.

```swift
POSRouter.shared.connect(callback: POSRouterResultCallback { result in
    switch result {
    case .success:      // lane ready
        break
    case .failure(let e):
        print("connect failed:", e.code, e.message)
    }
})
```

## 6. Take a payment

Amounts are **integer minor units** (cents): `$12.50` → `1250`.

```swift
final class PayHandler: POSRouterCallback {
    func onResult(_ result: PaymentResult) {
        switch result.status {
        case .approved:  // payment succeeded — result.transactionId, result.amount
            break
        case .declined:  break
        case .cancelled: break
        case .error:     break
        }
    }
    func onError(_ error: POSRouterError) {
        // Could not send the request (see Error codes below)
        print(error.code, error.message)
    }
}

POSRouter.shared.pay(
    request: PaymentRequest(
        terminalId: "TID001",
        amount: 1250,           // $12.50
        orderId: "ORDER-9",     // your unique order id — must not be blank
        remark: "Table 4"       // optional
    ),
    callback: PayHandler()
)
```

Prefer a closure? Use `POSRouterResultCallback { result in ... }` (a `Result<PaymentResult, POSRouterError>`).

### Amount helper

If you have a decimal string, convert it safely — it **throws** on bad input instead of
silently becoming `0` or a rounded value:

```swift
let cents = try PaymentRequest.amountFromDecimal("12.50")  // 1250
// throws on "abc", "12,50", overflow, and sub-cent precision like "1.005"
```

## 7. Void an in-flight payment

Soft-void a payment you just started (before it settles). Resolves as a `cancelled`
result on your pay callback when the terminal acks.

```swift
POSRouter.shared.voidPayment(orderId: "ORDER-9")   // returns false if no such in-flight pay
```

## 8. Refund a settled payment

```swift
POSRouter.shared.refund(
    request: RefundRequest(terminalId: "TID001", orderId: "ORDER-9", amount: 500), // $5.00
    callback: PayHandler()
)
```

---

## 9. Connection status (for a status indicator)

```swift
final class StatusHandler: POSRouterTerminalListener {
    func onLensingStateChanged(_ state: LensingConnectionState) {
        let argb = state.indicatorColorArgb    // packed ARGB for a status dot
    }
}
POSRouter.shared.setTerminalListener(StatusHandler())

let state = POSRouter.shared.currentLensingState()
```

| State | Meaning | Indicator |
|---|---|---|
| `connected` | Ready to transact | Green `#22C55E` |
| `discovering` / `connecting` / `reconnecting` | Establishing / recovering | Amber `#F59E0B` |
| `failed` | Connection failed | Red `#EF4444` |
| `offline` | Not initialized / idle | Slate `#94A3B8` |

Only pay when `connected`. After returning from background, call
`POSRouter.shared.refreshLensingConnection(backgroundMs:)` (pass elapsed background time)
to refresh a stale socket; `reconnectLensing()` forces a fresh session.

## 10. Routing (local vs remote terminal)

By default (`auto`) the SDK pays the reachable terminal — a co-located acquirer app on
the same device if present, otherwise a remote terminal over the network. If you always
pay a **remote** terminal, set:

```swift
POSRouter.shared.setRoutePreference(RoutePreference.remoteOnly)   // or per-call:
POSRouter.shared.pay(request: req, callback: cb, routePreference: RoutePreference.remoteOnly)
```

| Preference | Behaviour |
|---|---|
| `auto` *(default)* | local when reachable → remote fallback |
| `remote_only` | always the remote terminal (network) |
| `local_only` | same-device acquirer only |
| `local_first` / `remote_first` | try one, fall back to the other |

## 11. Local track only — forward the acquirer callback

**Skip this section if you only use the remote terminal (`remote_only`).**

If you launch a same-device acquirer app (`auto` / `local_*`), it returns via your URL
scheme. Forward that URL to the SDK so your pay callback fires:

```swift
// SwiftUI
.onOpenURL { url in _ = POSRouter.shared.deliverAcquirerCallback(url) }

// UIKit (SceneDelegate/AppDelegate)
func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
    POSRouter.shared.deliverAcquirerCallback(url) != nil
}
```

Also add the acquirer's URL scheme(s) to your `Info.plist` under
`LSApplicationQueriesSchemes` (we tell you which) so the SDK can detect the local app.

---

## 12. `PaymentResult` fields

| Field | Type | |
|---|---|---|
| `status` | `PaymentStatus` | `.approved` / `.declined` / `.cancelled` / `.error` |
| `amount` | `Int64` | minor units (cents) |
| `currency` | `String` | ISO-4217 |
| `orderId` / `attemptId` | `String?` | your order id + the SDK's per-try id |
| `transactionId` | `String?` | acquirer transaction reference (on approval) |
| `message` | `String?` | human-readable detail |
| `metadata` | `[String:String]` | extra fields, e.g. `cancelReason` |

## 13. Error codes (`POSRouterError.code`)

| Code | Meaning / action |
|---|---|
| `NOT_INITIALIZED` | Call `initialize(config:)` first, or the engine isn't connected yet. |
| `INVALID_ARGUMENT` | Blank `orderId` or non-positive `amount` (or a malformed lane). Fix the request. |
| `ALREADY_CLAIMED` | A payment UI is already open for that order. |
| `CONNECTING` | Refund queued until the connection is back; it will retry. |
| `PUBLISH_FAILED` | Could not send to the terminal (transient) — retry when `connected`. |
| `GATEWAY_ERROR` | Gateway handshake failed — usually a wrong/whitespace key or wrong `gatewayBaseUrl`. |
| `LOCAL_ACQUIRER_UNAVAILABLE` / `LOCAL_KIOSK_UNAVAILABLE` | Local-track only: the acquirer app isn't installed. |
| `CONNECT_FAILED` | The lane could not be established. |

---

## 14. Good to know

- **Amounts are always integer cents.** Use `amountFromDecimal` to convert strings safely.
- **`orderId` must be unique per payment and non-blank.** It's how results are matched back to your request.
- **Confirm outcomes server-side too.** The live result is delivered over a network stream; for anything that must never be missed (e.g. reconciliation), also confirm the final status through your own backend / an order-status check — a result emitted during a brief reconnect is not replayed.
- **This SDK is initiator-only.** It cannot act as a terminal (iOS can't host a background acquirer).

## 15. Support

Contact your POSRouter integration contact for credentials, the exact SDK version, the
`acquirerCode`, and the acquirer URL scheme(s) for the local track.
