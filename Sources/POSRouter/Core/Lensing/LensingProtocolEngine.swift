import Foundation

/// Internal Lensing engine. Owns Gateway discovery, the NATS session lifecycle, initiator-side
/// subscriptions, and outbound pay/refund/void/result publishing. NATS is fully encapsulated behind
/// ``LensingTransport``. This is the A-side (initiator) engine: it does not launch a local acquirer
/// for inbound remote pays (iOS cannot host an acquirer terminal), so it subscribes to the
/// initiator-relevant verbs (`claimed`, `result`, `void`) and not `pay` / `refund`.
final class LensingProtocolEngine {
    static let shared = LensingProtocolEngine()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.posrouter.lensing.engine")

    private var transportFactory: () -> LensingTransport = { NatsLensingTransport() }
    private var transport: LensingTransport?
    private var state: LensingState = .idle
    private var activeConfig: POSRouterConfig?
    private var startGeneration = 0
    private var reconnectAttempt = 0
    private let maxBackoffMs: Int64 = 30_000
    private let minBackgroundForReconnectMs: Int64 = 30_000

    private var pendingCredentials: (url: String, token: String, code: String)?
    private var fallbackQueue: [QueuedMessage] = []
    private var ownClaimedEchoKeys: Set<String> = []
    private var subscribedResultScopes: Set<String> = []

    private struct QueuedMessage {
        let subject: String
        let payload: Data
        let request: WirePaymentRequest
        let callback: POSRouterCallback
    }

    private static let activeStates: Set<Int> = [1, 2, 3, 4] // discovering, connecting, connected, reconnecting

    private func stateRank(_ s: LensingState) -> Int {
        switch s {
        case .idle: return 0
        case .discovering: return 1
        case .connecting: return 2
        case .connected: return 3
        case .reconnecting: return 4
        case .failed: return 5
        }
    }

    /// Test seam: inject a fake transport before ``start(_:force:)``.
    func setTransportFactory(_ factory: @escaping () -> LensingTransport) {
        lock.lock(); transportFactory = factory; lock.unlock()
    }

    func currentState() -> LensingState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func start(_ config: POSRouterConfig, force: Bool = false) {
        lock.lock()
        if !force && activeConfig == config && Self.activeStates.contains(stateRank(state)) {
            lock.unlock()
            return
        }
        activeConfig = config
        startGeneration += 1
        let generation = startGeneration
        subscribedResultScopes.removeAll()
        lock.unlock()

        shutdownConnection()
        setState(.discovering)

        Task { await discoverAndConnect(config, generation: generation) }
    }

    private func discoverAndConnect(_ config: POSRouterConfig, generation: Int) async {
        do {
            guard isCurrent(generation) else { return }
            let credentials = try await LensingGatewayClient.fetchNatsCredentials(
                code: config.participantCode,
                key: config.participantKey,
                initUrl: GatewayEndpoints.initUrl(config)
            )
            guard isCurrent(generation) else { return }
            await AcquirerRegistry.shared.prefetch(config)
            lock.lock(); reconnectAttempt = 0; lock.unlock()
            await connectTransport(credentials, config: config, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            setState(.reconnecting)
            scheduleGatewayRetry(config, generation: generation)
        }
    }

    private func scheduleGatewayRetry(_ config: POSRouterConfig, generation: Int) {
        let delayMs = backoffDelayMs()
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) { [weak self] in
            guard let self = self, self.isCurrent(generation) else { return }
            Task { await self.discoverAndConnect(config, generation: generation) }
        }
    }

    private func connectTransport(_ credentials: GatewayResponse, config: POSRouterConfig, generation: Int) async {
        guard isCurrent(generation) else { return }
        setState(.connecting)

        lock.lock()
        pendingCredentials = (credentials.natsUrl, credentials.natsToken, config.participantCode)
        let transport = transportFactory()
        self.transport = transport
        lock.unlock()

        let scope = LensingSubjectScope.fromConfig(config)
        transport.onConnected = { [weak self] in
            guard let self = self, self.isCurrent(generation) else { return }
            self.lock.lock(); self.reconnectAttempt = 0; self.lock.unlock()
            self.setState(.connected)
            self.setupInitiatorSubscriptions(scope)
            self.flushFallbackQueue()
        }
        transport.onReconnected = { [weak self] in
            guard let self = self, self.isCurrent(generation) else { return }
            self.lock.lock(); self.reconnectAttempt = 0; self.lock.unlock()
            self.setState(.connected)
            self.flushFallbackQueue()
        }
        transport.onDisconnected = { [weak self] in
            guard let self = self, self.isCurrent(generation) else { return }
            self.setState(.reconnecting)
        }

        do {
            try await transport.connect(url: credentials.natsUrl, token: credentials.natsToken, participantCode: config.participantCode)
            guard isCurrent(generation) else { transport.close(); return }
            // Fire subscriptions + state even if the transport didn't emit `.connected` synchronously.
            setState(.connected)
            lock.lock(); reconnectAttempt = 0; lock.unlock()
            setupInitiatorSubscriptions(scope)
            flushFallbackQueue()
        } catch {
            guard isCurrent(generation) else { return }
            setState(.reconnecting)
            scheduleTransportReconnect(credentials, config: config, generation: generation)
        }
    }

    private func scheduleTransportReconnect(_ credentials: GatewayResponse, config: POSRouterConfig, generation: Int) {
        let delayMs = backoffDelayMs()
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) { [weak self] in
            guard let self = self, self.isCurrent(generation) else { return }
            Task { await self.connectTransport(credentials, config: config, generation: generation) }
        }
    }

    private func backoffDelayMs() -> Int64 {
        lock.lock()
        let attempt = min(reconnectAttempt, 5)
        reconnectAttempt += 1
        lock.unlock()
        return min(maxBackoffMs, 1000 * Int64(1 << attempt))
    }

    func refreshConnectionIfNeeded(force: Bool = false, backgroundMs: Int64 = 0) {
        guard let config = activeConfig ?? LensingContextHolder.shared.config else { return }
        if !force && !shouldRefreshConnection(backgroundMs: backgroundMs) { return }
        start(config, force: true)
    }

    private func shouldRefreshConnection(backgroundMs: Int64) -> Bool {
        let s = currentState()
        if s == .connected && transport?.isConnected != true { return true }
        if s == .failed { return true }
        if backgroundMs >= minBackgroundForReconnectMs && s != .connected { return true }
        return false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == startGeneration
    }

    private func setState(_ newState: LensingState) {
        lock.lock()
        if state == newState { lock.unlock(); return }
        state = newState
        lock.unlock()
        TerminalEventDispatcher.shared.dispatchLensingState(newState)
    }

    private func shutdownConnection() {
        lock.lock()
        let t = transport
        transport = nil
        subscribedResultScopes.removeAll()
        lock.unlock()
        t?.close()
    }

    // MARK: - Subscriptions

    private func setupInitiatorSubscriptions(_ scope: LensingSubjectScope) {
        guard let transport = self.transport else { return }
        let resultKey = LensingSubjects.resultSubject(scope)
        lock.lock()
        let alreadySubscribed = subscribedResultScopes.contains(resultKey)
        if !alreadySubscribed { subscribedResultScopes.insert(resultKey) }
        lock.unlock()
        guard !alreadySubscribed else { return }

        subscribe(transport, LensingSubjects.claimedSubject(scope)) { [weak self] data in
            self?.handleIncomingClaimed(data)
        }
        subscribe(transport, LensingSubjects.resultSubject(scope)) { [weak self] data in
            self?.handleIncomingResult(data)
        }
        subscribe(transport, LensingSubjects.voidSubject(scope)) { [weak self] data in
            self?.handleIncomingVoid(data)
        }
    }

    /// Initiator must listen on the pay wire namespace (V1.6 subject) for the remote `.result`.
    private func ensureSubscriptionsForWire(_ wire: WirePaymentRequest) {
        let scope = LensingSubjectScope.fromWire(wire)
        let key = LensingSubjects.resultSubject(scope)
        lock.lock()
        if subscribedResultScopes.contains(key) { lock.unlock(); return }
        subscribedResultScopes.insert(key)
        let transport = self.transport
        lock.unlock()
        guard let transport = transport else { return }
        subscribe(transport, key) { [weak self] data in self?.handleIncomingResult(data) }
    }

    private func subscribe(_ transport: LensingTransport, _ subject: String, _ handler: @escaping (Data) -> Void) {
        Task { try? await transport.subscribe(subject: subject) { data in handler(data) } }
    }

    // MARK: - Inbound

    private func handleIncomingClaimed(_ data: Data) {
        guard let json = String(data: data, encoding: .utf8), let claim = PaymentClaim.fromJson(json) else { return }
        let echoKey = PaymentAttemptKey(terminalId: claim.terminalId, orderId: claim.orderId, attemptId: claim.attemptId).storageKey()
        lock.lock()
        let isOwnEcho = ownClaimedEchoKeys.remove(echoKey) != nil
        lock.unlock()
        if isOwnEcho { return }
        PaymentClaimRegistry.shared.markClaimed(claim)
    }

    private func handleIncomingResult(_ data: Data) {
        guard let json = String(data: data, encoding: .utf8) else { return }
        let result = PaymentResult.fromJson(json)
        _ = PaymentResultDispatcher.deliver(result, source: .natsInbound, publishNats: false, dispatchTerminal: false)
    }

    private func handleIncomingVoid(_ data: Data) {
        guard let json = String(data: data, encoding: .utf8), let voidReq = PaymentVoidRequest.fromJson(json) else { return }
        // This device is the initiator waiting on a callback: ignore our own void; the cancelled
        // result arrives on `.result` from the terminal.
        if PaymentAttemptRegistry.shared.hasInitiatorCallback(voidReq.terminalId, voidReq.orderId, voidReq.attemptId) {
            return
        }
        if VoidedAttemptRegistry.shared.isVoided(voidReq.terminalId, voidReq.orderId, voidReq.attemptId) { return }
        VoidedAttemptRegistry.shared.mark(voidReq.terminalId, voidReq.orderId, voidReq.attemptId)
        PaymentAttemptRegistry.shared.close(voidReq.terminalId, voidReq.orderId, voidReq.attemptId)
        PaymentClaimRegistry.shared.releaseClaim(voidReq.terminalId, voidReq.orderId, voidReq.attemptId)
    }

    // MARK: - Outbound

    func publishClaimed(_ wire: WirePaymentRequest) {
        let claim = PaymentClaim(terminalId: wire.terminalId, orderId: wire.orderId, attemptId: wire.attemptId)
        PaymentClaimRegistry.shared.markClaimed(claim)
        let echoKey = PaymentAttemptKey(terminalId: wire.terminalId, orderId: wire.orderId, attemptId: wire.attemptId).storageKey()
        lock.lock(); ownClaimedEchoKeys.insert(echoKey); lock.unlock()
        publishToSubject(LensingSubjects.claimedSubject(LensingSubjectScope.fromWire(wire)), claim.toJsonString())
    }

    func dispatchTransaction(_ request: WirePaymentRequest, callback: POSRouterCallback) {
        let subject = LensingSubjects.paySubject(LensingSubjectScope.fromWire(request))
        let payload = Data(request.toJsonString().utf8)

        lock.lock()
        let transport = self.transport
        let s = state
        lock.unlock()

        guard let transport = transport, s == .connected, transport.isConnected else {
            lock.lock(); fallbackQueue.append(QueuedMessage(subject: subject, payload: payload, request: request, callback: callback)); lock.unlock()
            if s == .idle || s == .failed {
                deliverError(callback, POSRouterError(code: "NOT_INITIALIZED", message: "Lensing engine not connected"))
            }
            return
        }

        PaymentAttemptRegistry.shared.store(request, callback: callback)
        ensureSubscriptionsForWire(request)

        Task {
            do {
                try await transport.publish(payload, subject: subject)
            } catch {
                PaymentAttemptRegistry.shared.close(request.terminalId, request.orderId, request.attemptId)
                self.lock.lock(); self.fallbackQueue.append(QueuedMessage(subject: subject, payload: payload, request: request, callback: callback)); self.lock.unlock()
                self.deliverError(callback, POSRouterError(code: "PUBLISH_FAILED", message: "Failed to publish"))
            }
        }
    }

    func dispatchRefund(_ request: WireRefundRequest, callback: POSRouterCallback) {
        let subject = LensingSubjects.refundSubject(request.subjectScope())
        let payload = Data(request.toJsonString().utf8)

        lock.lock()
        let transport = self.transport
        let s = state
        lock.unlock()

        guard let transport = transport, s == .connected, transport.isConnected else {
            if s == .idle || s == .failed {
                deliverError(callback, POSRouterError(code: "NOT_INITIALIZED", message: "Lensing engine not connected"))
            } else {
                RefundAttemptRegistry.shared.store(request, callback: callback)
                deliverError(callback, POSRouterError(code: "CONNECTING", message: "Refund queued until NATS reconnects"))
            }
            return
        }

        RefundAttemptRegistry.shared.store(request, callback: callback)
        Task {
            do {
                try await transport.publish(payload, subject: subject)
            } catch {
                RefundAttemptRegistry.shared.close(request)
                self.deliverError(callback, POSRouterError(code: "PUBLISH_FAILED", message: "Failed to publish refund"))
            }
        }
    }

    func publishVoid(_ request: PaymentVoidRequest) -> Bool {
        lock.lock()
        let transport = self.transport
        let s = state
        lock.unlock()
        guard let transport = transport, s == .connected, transport.isConnected else { return false }
        VoidedAttemptRegistry.shared.mark(request.terminalId, request.orderId, request.attemptId)
        let payload = Data(request.toJsonString().utf8)
        let subject = LensingSubjects.voidSubject(request.subjectScope())
        Task { try? await transport.publish(payload, subject: subject) }
        return true
    }

    func publishPaymentResult(_ result: PaymentResult) {
        guard let scope = resolveResultScope(result) else { return }
        publishToSubject(LensingSubjects.resultSubject(scope), result.toJsonString())
    }

    private func resolveResultScope(_ result: PaymentResult) -> LensingSubjectScope? {
        let config = LensingContextHolder.shared.config
        let tid = result.terminalId.isEmpty ? (config?.terminalId ?? "") : result.terminalId
        if tid.isEmpty { return nil }
        if let orderId = result.orderId, let attemptId = result.attemptId {
            if let wire = PaymentAttemptRegistry.shared.lookup(PaymentAttemptKey(terminalId: tid, orderId: orderId, attemptId: attemptId)) {
                return LensingSubjectScope.fromWire(wire)
            }
            if let refund = RefundAttemptRegistry.shared.lookup(tid, orderId, attemptId) {
                return refund.subjectScope()
            }
        }
        guard let cfg = config else { return nil }
        return LensingSubjectScope(
            acquirerCode: cfg.acquirerCode,
            merchantId: cfg.merchantId,
            subMerchantId: result.subMerchantId ?? cfg.subMerchantId,
            terminalId: tid
        )
    }

    private func publishToSubject(_ subject: String, _ payload: String) {
        lock.lock(); let transport = self.transport; lock.unlock()
        guard let transport = transport else { return }
        Task { try? await transport.publish(Data(payload.utf8), subject: subject) }
    }

    private func flushFallbackQueue() {
        lock.lock()
        guard let transport = self.transport, state == .connected else { lock.unlock(); return }
        let pending = fallbackQueue
        fallbackQueue.removeAll()
        lock.unlock()

        for queued in pending {
            PaymentAttemptRegistry.shared.store(queued.request, callback: queued.callback)
            ensureSubscriptionsForWire(queued.request)
            Task {
                do {
                    try await transport.publish(queued.payload, subject: queued.subject)
                } catch {
                    PaymentAttemptRegistry.shared.close(queued.request.terminalId, queued.request.orderId, queued.request.attemptId)
                    self.lock.lock(); self.fallbackQueue.append(queued); self.lock.unlock()
                }
            }
        }
    }

    private func deliverError(_ callback: POSRouterCallback, _ error: POSRouterError) {
        DispatchQueue.main.async { callback.onError(error) }
    }
}
