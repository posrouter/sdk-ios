# POSRouter iOS SDK

Pure Swift native iOS SDK (Swift Package Manager ready) for the Lensing Protocol.

## Usage

```swift
POSRouter.shared.initialize(code: "GPOS", key: "your-participant-key")

POSRouter.shared.pay(
    from: viewController,
    request: PaymentRequest(
        terminalId: "TID001",
        amount: 1250,
        currency: "USD",
        targetScheme: "ezypos://"
    ),
    completion: { result in
        // handle PaymentResult
    }
)
```

## Build

Open in Xcode or:

```bash
swift build
```
