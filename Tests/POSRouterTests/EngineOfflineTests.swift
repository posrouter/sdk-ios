import XCTest
@testable import POSRouter

/// Engine behaviour that does not require a live Gateway/NATS. The connected path (start → discover →
/// connect → publish → result) needs a real broker and is exercised via the demo apps, mirroring the
/// Android SDK whose engine is likewise integration-tested rather than unit-tested against a broker.
final class EngineOfflineTests: XCTestCase {
    func testDispatchWhileIdleErrorsNotInitialized() {
        let engine = LensingProtocolEngine.shared
        // No initialize() is ever called in the test bundle, so the shared engine stays idle.
        XCTAssertEqual(engine.currentState(), .idle)

        let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "TIDX",
                                     acquirerCode: "SUPY", merchantId: "m")
        let wire = PaymentRequest(terminalId: "TIDX", amount: 1, orderId: "OZ")
            .toWire(config: config, routing: AcquirerRegistry.shared.resolve(config), resolvedAttemptId: "OZ#1")

        let exp = expectation(description: "error")
        final class CB: POSRouterCallback {
            let onErr: (POSRouterError) -> Void
            init(_ f: @escaping (POSRouterError) -> Void) { onErr = f }
            func onResult(_ result: PaymentResult) {}
            func onError(_ error: POSRouterError) { onErr(error) }
        }
        let cb = CB { err in
            XCTAssertEqual(err.code, "NOT_INITIALIZED")
            exp.fulfill()
        }
        engine.dispatchTransaction(wire, callback: cb)
        waitForExpectations(timeout: 2)
    }

    /// The transport abstraction is a clean seam: a fake conforms and reports state without NATS.
    func testFakeTransportConformsAndReportsState() async throws {
        let fake = FakeTransport()
        XCTAssertFalse(fake.isConnected)
        try await fake.connect(url: "nats://x", token: "t", participantCode: "G")
        XCTAssertTrue(fake.isConnected)

        var received: [String] = []
        try await fake.subscribe(subject: "lensing.SUPY.m._.T.result") { data in
            received.append(String(data: data, encoding: .utf8) ?? "")
        }
        try await fake.publish(Data("hello".utf8), subject: "lensing.SUPY.m._.T.pay")
        XCTAssertEqual(fake.published.first?.subject, "lensing.SUPY.m._.T.pay")
        fake.emit(subject: "lensing.SUPY.m._.T.result", payload: Data("world".utf8))
        XCTAssertEqual(received, ["world"])
        fake.close()
        XCTAssertFalse(fake.isConnected)
    }
}

/// In-memory ``LensingTransport`` for tests.
final class FakeTransport: LensingTransport {
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReconnected: (() -> Void)?
    private(set) var isConnected = false
    private(set) var published: [(payload: Data, subject: String)] = []
    private var handlers: [String: (Data) -> Void] = [:]

    func connect(url: String, token: String, participantCode: String) async throws {
        isConnected = true
        onConnected?()
    }
    func publish(_ payload: Data, subject: String) async throws {
        published.append((payload, subject))
    }
    func subscribe(subject: String, handler: @escaping (Data) -> Void) async throws {
        handlers[subject] = handler
    }
    func emit(subject: String, payload: Data) { handlers[subject]?(payload) }
    func close() { isConnected = false }
}
