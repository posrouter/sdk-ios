// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "POSRouter",
    platforms: [
        .iOS(.v15),
        // macOS is supported only to allow `swift build` / `swift test` on a developer Mac
        // (the Nats dependency requires macOS 13+); the SDK ships for iOS.
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "POSRouter",
            targets: ["POSRouter"]
        )
    ],
    dependencies: [
        .package(name: "Nats", url: "https://github.com/nats-io/nats.swift.git", from: "0.4.0")
    ],
    targets: [
        .target(
            name: "POSRouter",
            dependencies: ["Nats"],
            path: "Sources/POSRouter"
        ),
        .testTarget(
            name: "POSRouterTests",
            dependencies: ["POSRouter"],
            path: "Tests/POSRouterTests"
        )
    ]
)
