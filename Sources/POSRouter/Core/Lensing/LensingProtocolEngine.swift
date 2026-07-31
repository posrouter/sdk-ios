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

    private var fallbackQueue: [QueuedMessage] = []
    private var ownClaimedEchoKeys: Set<String> = []
    /// In-flight/settled subscription per result subject. Concurrent callers for the same scope
    /// await the SAME task, so no pay is published before its result SUB is on the wire and no
    /// duplicate subscription is opened. A failed subscribe is dropped so the next attempt retries.
    private var resultScopeSubs: [String: Task<Bool, Never>] = [:]

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

    /// Test seam: drop the engine straight into a CONNECTED session on `transport`, bypassing the
    /// live Gateway/NATS handshake, and set up the initiator subscriptions for `config`'s scope.
    /// Returns once subscriptions are established so tests can assert ordering deterministically.
    func injectConnectedTransportForTesting(_ transport: LensingTransport, config: POSRouterConfig) async {
        LensingContextHolder.shared.config = config
        try? await transport.connect(url: "nats://test", token: "t", participantCode: config.participantCode)
        lock.lock()
        activeConfig = config
        startGeneration += 1
        self.transport = transport
        resultScopeSubs.removeAll()
        fallbackQueue.removeAll()
        ownClaimedEchoKeys.removeAll()
        state = .connected
        lock.unlock()
        await setupInitiatorSubscriptionsAsync(LensingSubjectScope.fromConfig(config))
    }

    /// Test seam: return the engine to `.idle` and drop any injected transport.
    func resetForTesting() {
        lock.lock()
        let t = transport
        transport = nil
        activeConfig = nil
        state = .idle
        startGeneration += 1
        resultScopeSubs.removeAll()
        fallbackQueue.removeAll()
        ownClaimedEchoKeys.removeAll()
        lock.unlock()
        t?.close()
        LensingContextHolder.shared.config = nil
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
        resultScopeSubs.removeAll()
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
        let transport = transportFactory()
        self.transport = transport
        lock.unlock()

        let scope = LensingSubjectScope.fromConfig(config)
        transport.onConnected = { [weak self] in
            guard let self = self, self.isCurrent(generation) else { return }
            self.lock.lock(); self.reconnectAttempt = 0; self.lock.unlock()
            self.setState(.connected)
            Task {
                await self.setupInitiatorSubscriptionsAsync(scope)
                self.flushFallbackQueue()
            }
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
            await setupInitiatorSubscriptionsAsync(scope)
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
        lock.lock(); let cfg = activeConfig; lock.unlock()
        guard let config = cfg ?? LensingContextHolder.shared.config else { return }
        if !force && !shouldRefreshConnection(backgroundMs: backgroundMs) { return }
        start(config, force: true)
    }

    private func shouldRefreshConnection(backgroundMs: Int64) -> Bool {
        lock.lock()
        let s = state
        let socketAlive = transport?.isConnected == true
        lock.unlock()
        if s == .connected && !socketAlive { return true }
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
        resultScopeSubs.removeAll()
        lock.unlock()
        t?.close()
    }

    // MARK: - Subscriptions

    /// Establishes the initiator's `.claimed` / `.result` / `.void` subscriptions and only returns
    /// once the transport has accepted them. Deduped and serialized per result subject via
    /// ``ensureResultScopeSubscribed(_:subscribe:)``.
    @discardableResult
    private func setupInitiatorSubscriptionsAsync(_ scope: LensingSubjectScope) async -> Bool {
        await ensureResultScopeSubscribed(LensingSubjects.resultSubject(scope)) { [weak self] transport in
            guard let self = self else { return false }
            let ok1 = await self.subscribeAsync(transport, LensingSubjects.claimedSubject(scope)) { [weak self] d in self?.handleIncomingClaimed(d) }
            let ok2 = await self.subscribeAsync(transport, LensingSubjects.resultSubject(scope)) { [weak self] d in self?.handleIncomingResult(d) }
            let ok3 = await self.subscribeAsync(transport, LensingSubjects.voidSubject(scope)) { [weak self] d in self?.handleIncomingVoid(d) }
            return ok1 && ok2 && ok3
        }
    }

    /// Initiator must listen on the pay wire namespace (V1.6 subject) for the remote `.result`
    /// BEFORE the pay is published, otherwise a fast terminal's result can race ahead of the SUB
    /// and be missed. Returns `true` once the subscription is accepted (or already active).
    @discardableResult
    private func ensureSubscriptionsForWireAsync(_ wire: WirePaymentRequest) async -> Bool {
        let key = LensingSubjects.resultSubject(LensingSubjectScope.fromWire(wire))
        return await ensureResultScopeSubscribed(key) { [weak self] transport in
            await self?.subscribeAsync(transport, key) { [weak self] d in self?.handleIncomingResult(d) } ?? false
        }
    }

    /// Serializes subscription setup per result subject: the first caller runs `subscribe`, any
    /// concurrent caller awaits the same task, and a failed attempt is dropped so a later pay /
    /// reconnect retries instead of silently publishing with no listener.
    private func ensureResultScopeSubscribed(_ key: String, subscribe: @escaping (LensingTransport) async -> Bool) async -> Bool {
        lock.lock()
        if let existing = resultScopeSubs[key] { lock.unlock(); return await existing.value }
        guard let transport = self.transport else { lock.unlock(); return false }
        let task = Task { await subscribe(transport) }
        resultScopeSubs[key] = task
        lock.unlock()

        let ok = await task.value
        if !ok { lock.lock(); if resultScopeSubs[key] != nil { resultScopeSubs[key] = nil }; lock.unlock() }
        return ok
    }

    @discardableResult
    private func subscribeAsync(_ transport: LensingTransport, _ subject: String, _ handler: @escaping (Data) -> Void) async -> Bool {
        do { try await transport.subscribe(subject: subject) { data in handler(data) }; return true }
        catch { return false }
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

        Task {
            // Subscribe to the result subject BEFORE publishing the pay, so a fast terminal's
            // result cannot arrive before our SUB is on the wire. If the subscribe fails, do NOT
            // publish blind (the pay would go out with no result listener and hang) — queue and
            // surface an error so the next connected attempt retries with a live subscription.
            let subscribed = await self.ensureSubscriptionsForWireAsync(request)
            guard subscribed else {
                PaymentAttemptRegistry.shared.close(request.terminalId, request.orderId, request.attemptId)
                self.lock.lock(); self.fallbackQueue.append(QueuedMessage(subject: subject, payload: payload, request: request, callback: callback)); self.lock.unlock()
                self.deliverError(callback, POSRouterError(code: "PUBLISH_FAILED", message: "Result subscription failed"))
                return
            }
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
        // Result data can originate from an external callback; don't publish on a malformed subject.
        guard (try? LensingSubjects.validate(scope)) != nil else { return }
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
            Task {
                await self.ensureSubscriptionsForWireAsync(queued.request)
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
