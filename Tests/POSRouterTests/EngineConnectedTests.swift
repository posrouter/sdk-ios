import XCTest
@testable import POSRouter

/// Engine tests that drive the CONNECTED path through a recording fake transport (no live broker),
/// covering the subscribe-before-publish ordering and the inbound-result → callback round-trip that
/// the wire/crypto unit tests could not reach.
final class EngineConnectedTests: XCTestCase {
    private let engine = LensingProtocolEngine.shared

    override func tearDown() {
        engine.resetForTesting()
        super.tearDown()
    }

    /// A `pay` whose wire scope differs from the connect-time config scope must SUBSCRIBE to that
    /// scope's `.result` before it PUBLISHES the pay — otherwise a fast terminal's result races
    /// ahead of the SUB and is lost. (Fable High #2.)
    func testResultSubscribedBeforePublish() async throws {
        let transport = RecordingTransport()
        // Config terminal T1; the pay targets terminal T2, so its result scope is newly subscribed.
        let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "T1",
                                     acquirerCode: "SUPY", merchantId: "m")
        await engine.injectConnectedTransportForTesting(transport, config: config)

        let wire = PaymentRequest(terminalId: "T2", amount: 6600, orderId: "ORDA")
            .toWire(config: config, routing: AcquirerRegistry.shared.resolve(config), resolvedAttemptId: "ORDA#1")
        engine.dispatchTransaction(wire, callback: NoopCallback())

        let paySubject = "lensing.SUPY.m._.T2.pay"
        let resultSubject = "lensing.SUPY.m._.T2.result"
        await waitFor { transport.index(of: "pub:\(paySubject)") != nil }

        guard let subIdx = transport.index(of: "sub:\(resultSubject)"),
              let pubIdx = transport.index(of: "pub:\(paySubject)") else {
            return XCTFail("expected both a result subscribe and a pay publish; got \(transport.events)")
        }
        XCTAssertLessThan(subIdx, pubIdx, "result SUB must precede pay PUB; events=\(transport.events)")
    }

    /// Two pays racing to the SAME not-yet-subscribed scope must open exactly ONE result
    /// subscription, and both must publish only after that subscription is on the wire. Guards the
    /// concurrent-first-use variant of the result-loss race.
    func testConcurrentPaysSameScopeSubscribeOnceBeforePublish() async throws {
        let transport = RecordingTransport()
        let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "T1",
                                     acquirerCode: "SUPY", merchantId: "m")
        await engine.injectConnectedTransportForTesting(transport, config: config)

        func wire(_ order: String) -> WirePaymentRequest {
            PaymentRequest(terminalId: "T9", amount: 100, orderId: order)
                .toWire(config: config, routing: AcquirerRegistry.shared.resolve(config), resolvedAttemptId: "\(order)#1")
        }
        engine.dispatchTransaction(wire("OC1"), callback: NoopCallback())
        engine.dispatchTransaction(wire("OC2"), callback: NoopCallback())

        let paySubject = "lensing.SUPY.m._.T9.pay"
        let resultSubject = "lensing.SUPY.m._.T9.result"
        await waitFor { transport.events.filter { $0 == "pub:\(paySubject)" }.count == 2 }

        XCTAssertEqual(transport.events.filter { $0 == "sub:\(resultSubject)" }.count, 1,
                       "same scope must subscribe exactly once; events=\(transport.events)")
        guard let subIdx = transport.index(of: "sub:\(resultSubject)"),
              let lastPubIdx = transport.events.lastIndex(of: "pub:\(paySubject)") else {
            return XCTFail("expected one result sub and two pay pubs; got \(transport.events)")
        }
        XCTAssertLessThan(subIdx, lastPubIdx, "result SUB must precede BOTH pay PUBs; events=\(transport.events)")
    }

    /// A result arriving on the subscribed `.result` subject must be delivered to the pending
    /// `pay` callback. Exercises subscribe → inbound JSON parse → dispatcher → callback.
    func testInboundResultDeliversCallback() async throws {
        let transport = RecordingTransport()
        let config = POSRouterConfig(participantCode: "G", participantKey: "k", terminalId: "T1",
                                     acquirerCode: "SUPY", merchantId: "m")
        await engine.injectConnectedTransportForTesting(transport, config: config)

        let wire = PaymentRequest(terminalId: "T2", amount: 6600, orderId: "ORDB")
            .toWire(config: config, routing: AcquirerRegistry.shared.resolve(config), resolvedAttemptId: "ORDB#1")

        let exp = expectation(description: "onResult")
        let cb = ResultCallback { result in
            XCTAssertEqual(result.status, .approved)
            XCTAssertEqual(result.orderId, "ORDB")
            exp.fulfill()
        }
        engine.dispatchTransaction(wire, callback: cb)

        let resultSubject = "lensing.SUPY.m._.T2.result"
        await waitFor { transport.index(of: "pub:lensing.SUPY.m._.T2.pay") != nil }

        let resultJson = #"{"terminalId":"T2","status":"approved","amount":6600,"currency":"NZD","orderId":"ORDB","attemptId":"ORDB#1"}"#
        transport.emit(subject: resultSubject, Data(resultJson.utf8))

        await fulfillment(of: [exp], timeout: 2)
    }
}

// MARK: - Test doubles

/// Records the ordered sequence of subscribe/publish operations and lets tests emit inbound frames.
final class RecordingTransport: LensingTransport {
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReconnected: (() -> Void)?

    private let lock = NSLock()
    private var _isConnected = false
    private var _events: [String] = []
    private var handlers: [String: (Data) -> Void] = [:]

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return _isConnected }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    func index(of event: String) -> Int? { lock.lock(); defer { lock.unlock() }; return _events.firstIndex(of: event) }

    func connect(url: String, token: String, participantCode: String) async throws {
        lock.lock(); _isConnected = true; lock.unlock()
    }
    func publish(_ payload: Data, subject: String) async throws {
        lock.lock(); _events.append("pub:\(subject)"); lock.unlock()
    }
    func subscribe(subject: String, handler: @escaping (Data) -> Void) async throws {
        lock.lock(); _events.append("sub:\(subject)"); handlers[subject] = handler; lock.unlock()
    }
    func emit(subject: String, _ data: Data) {
        lock.lock(); let handler = handlers[subject]; lock.unlock()
        handler?(data)
    }
    func close() { lock.lock(); _isConnected = false; lock.unlock() }
}

final class NoopCallback: POSRouterCallback {
    func onResult(_ result: PaymentResult) {}
    func onError(_ error: POSRouterError) {}
}

final class ResultCallback: POSRouterCallback {
    private let onResultHandler: (PaymentResult) -> Void
    init(_ handler: @escaping (PaymentResult) -> Void) { onResultHandler = handler }
    func onResult(_ result: PaymentResult) { onResultHandler(result) }
    func onError(_ error: POSRouterError) {}
}

extension XCTestCase {
    /// Polls `condition` until true or `timeout` elapses, yielding between checks.
    func waitFor(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
