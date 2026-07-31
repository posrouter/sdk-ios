import Foundation

/// Outward-facing POSRouter facade for A-side (initiator / POS) integration. Lensing internals are
/// isolated behind ``LensingProtocolEngine``. Feature-parity with the Android SDK's initiator API:
/// `connect` / `pay` / `refund` / `voidPayment`, route preferences, connection state + indicator
/// colors, and acquirer callback parsing. B-side terminal hosting (a device that receives remote
/// pays and drives a local acquirer) is Android-only and intentionally not part of the iOS SDK.
public final class POSRouter {
    public static let shared = POSRouter()
    private init() {}

    private var holder: LensingContextHolder { .shared }
    private var engine: LensingProtocolEngine { .shared }

    // MARK: - Lifecycle

    public func initialize(config: POSRouterConfig) {
        holder.config = config
        holder.routePreference = RoutePreference.auto
        engine.start(config)
    }

    /// Sets routing preference for ``connect``, ``pay``, and ``refund``. Unknown values become `auto`.
    public func setRoutePreference(_ routePreference: String) {
        holder.routePreference = RoutePreference.normalize(routePreference)
    }

    public func getRoutePreference() -> String { holder.routePreference }

    /// Whether a same-device POSRouter Kiosk is available for ``RoutePreference/localPosrouterKiosk``.
    public func isLocalKioskAvailable() -> Bool { LocalKioskLauncher.isAvailable(holder.config) }

    // MARK: - Connect

    public func connect(callback: POSRouterCallback, routePreference: String? = nil) {
        if let routePreference = routePreference { setRoutePreference(routePreference) }
        guard let config = holder.config else {
            callback.onError(POSRouterError(code: "NOT_INITIALIZED", message: "Call initialize(config:) first"))
            return
        }
        let routing = AcquirerRegistry.shared.resolve(config)
        let preference = holder.routePreference

        if RoutePreferencePolicy.isLocalPosrouterKiosk(preference) {
            if isLocalKioskAvailable() {
                deliver(callback, localKioskConnectResult(config))
            } else {
                deliver(callback, POSRouterError(code: "LOCAL_KIOSK_UNAVAILABLE", message: "POSRouter Kiosk is not installed on this device"))
            }
            return
        }

        if !RoutePreferencePolicy.skipsLocalAttempt(preference)
            && RoutePreferencePolicy.shouldTryLocal(preference, acquirerCode: routing.code) {
            let launch = LocalAcquirerLauncher.launchConnect(config, routing: routing)
            if launch.success, let method = launch.method {
                deliver(callback, connectResult(config, method: method))
                return
            }
        }

        if !RoutePreferencePolicy.shouldFallbackToRemote(preference) {
            deliver(callback, POSRouterError(code: "LOCAL_ACQUIRER_UNAVAILABLE", message: "Local acquirer is not available on this device"))
            return
        }

        switch engine.currentState() {
        case .connected:
            deliver(callback, PendingConnectRegistry.networkConnectResult(config))
        case .discovering, .connecting, .reconnecting:
            PendingConnectRegistry.shared.enqueue(callback)
        case .failed:
            deliver(callback, POSRouterError(code: "CONNECT_FAILED", message: "Lensing engine connection failed"))
        case .idle:
            deliver(callback, POSRouterError(code: "NOT_INITIALIZED", message: "Call initialize(config:) first"))
        }
    }

    // MARK: - Pay

    public func pay(request: PaymentRequest, callback: POSRouterCallback, routePreference: String? = nil) {
        if let routePreference = routePreference { setRoutePreference(routePreference) }
        guard let config = holder.config else {
            deliver(callback, POSRouterError(code: "NOT_INITIALIZED", message: "Call initialize(config:) first"))
            return
        }
        let resolvedAttemptId = PaymentAttemptIdResolver.shared.resolve(orderId: request.orderId, explicit: request.attemptId)
        let routing = AcquirerRegistry.shared.resolve(config, attemptCode: request.attemptCode)
        let wire = request.toWire(config: config, routing: routing, resolvedAttemptId: resolvedAttemptId)
        let preference = holder.routePreference

        if PaymentClaimRegistry.shared.isClaimed(wire.terminalId, wire.orderId, wire.attemptId) {
            deliver(callback, POSRouterError(code: "ALREADY_CLAIMED", message: "Payment UI already claimed for order \(wire.orderId)"))
            return
        }

        if RoutePreferencePolicy.isLocalPosrouterKiosk(preference) {
            PaymentAttemptRegistry.shared.store(wire.with(method: PaymentRequest.methodSelection), callback: callback)
            if !LocalKioskLauncher.launchCharge(config, wire: wire) {
                PaymentAttemptRegistry.shared.close(wire.terminalId, wire.orderId, wire.attemptId)
                deliver(callback, POSRouterError(code: "LOCAL_KIOSK_UNAVAILABLE", message: "POSRouter Kiosk is not installed or callbackUrl is missing"))
            }
            return
        }

        // Method selection is rendered on a remote terminal (NATS), not a local acquirer deeplink.
        if PaymentRequest.requiresTerminalMethodSelection(request.method) {
            if RoutePreference.normalize(preference) == RoutePreference.localOnly {
                deliver(callback, POSRouterError(code: "LOCAL_TERMINAL_REQUIRED", message: "Method selection requires remote_only, local_posrouter_kiosk, or kiosk deeplink"))
                return
            }
            engine.dispatchTransaction(wire, callback: callback)
            return
        }

        if !RoutePreferencePolicy.skipsLocalAttempt(preference)
            && RoutePreferencePolicy.shouldTryLocal(preference, acquirerCode: routing.code) {
            if !PaymentClaimRegistry.shared.tryAcquireClaim(wire.terminalId, wire.orderId, wire.attemptId) {
                deliver(callback, POSRouterError(code: "ALREADY_CLAIMED", message: "Payment UI already claimed for order \(wire.orderId)"))
                return
            }
            let launch = LocalAcquirerLauncher.launchPay(config, routing: routing, request: wire)
            if launch.success {
                engine.publishClaimed(wire)
                PaymentClaimRegistry.shared.releaseClaim(wire.terminalId, wire.orderId, wire.attemptId)
                PaymentAttemptRegistry.shared.store(wire, callback: callback)
                return
            }
            PaymentClaimRegistry.shared.releaseClaim(wire.terminalId, wire.orderId, wire.attemptId)
        }

        if !RoutePreferencePolicy.shouldFallbackToRemote(preference) {
            deliver(callback, POSRouterError(code: "LOCAL_ACQUIRER_UNAVAILABLE", message: "Local acquirer is not available on this device"))
            return
        }

        engine.dispatchTransaction(wire, callback: callback)
    }

    // MARK: - Refund

    public func refund(request: RefundRequest, callback: POSRouterCallback, routePreference: String? = nil) {
        if let routePreference = routePreference { setRoutePreference(routePreference) }
        guard let config = holder.config else {
            deliver(callback, POSRouterError(code: "NOT_INITIALIZED", message: "Call initialize(config:) first"))
            return
        }
        let resolvedAttemptId = RefundAttemptIdResolver.resolve(orderId: request.orderId, attemptId: request.attemptId)
        let routing = AcquirerRegistry.shared.resolve(config, attemptCode: request.attemptCode)
        let wire = request.toWire(config: config, routing: routing, resolvedAttemptId: resolvedAttemptId)
        let preference = holder.routePreference

        if !RoutePreferencePolicy.skipsLocalAttempt(preference)
            && RoutePreferencePolicy.shouldTryLocal(preference, acquirerCode: routing.code) {
            let launch = LocalAcquirerLauncher.launchRefund(config, routing: routing, request: wire)
            if launch.success {
                RefundAttemptRegistry.shared.store(wire, callback: callback)
                return
            }
        }

        if !RoutePreferencePolicy.shouldFallbackToRemote(preference) {
            deliver(callback, POSRouterError(code: "LOCAL_ACQUIRER_UNAVAILABLE", message: "Local acquirer is not available on this device"))
            return
        }

        engine.dispatchRefund(wire, callback: callback)
    }

    // MARK: - Void / cancel

    /// Void an in-flight payment on the remote terminal (soft void). Keeps the local `pay` callback
    /// until the terminal acks with a cancelled ``PaymentResult`` (`cancelReason=initiator_void`).
    @discardableResult
    public func voidPayment(orderId: String, attemptId: String? = nil) -> Bool {
        guard let config = holder.config else { return false }
        let wire: WirePaymentRequest?
        if let attemptId = attemptId {
            wire = PaymentAttemptRegistry.shared.lookup(PaymentAttemptKey(terminalId: config.terminalId, orderId: orderId, attemptId: attemptId))
        } else {
            wire = PaymentAttemptRegistry.shared.lookupOpenByOrder(config.terminalId, orderId)
        }
        guard let wire = wire else { return false }
        let voidReq = PaymentVoidRequest(
            acquirerCode: wire.acquirerCode,
            merchantId: wire.merchantId,
            subMerchantId: wire.subMerchantId,
            terminalId: wire.terminalId,
            orderId: wire.orderId,
            attemptId: wire.attemptId
        )
        return engine.publishVoid(voidReq)
    }

    /// Clears the routing claim only; does not cancel a pending pay callback.
    public func releasePaymentClaim(orderId: String, attemptId: String? = nil) {
        guard let config = holder.config else { return }
        if let attemptId = attemptId {
            PaymentClaimRegistry.shared.releaseClaim(config.terminalId, orderId, attemptId)
            return
        }
        if let wire = PaymentAttemptRegistry.shared.lookupOpenByOrder(config.terminalId, orderId) {
            PaymentClaimRegistry.shared.releaseClaim(wire.terminalId, wire.orderId, wire.attemptId)
        }
    }

    /// Cancels a pending ``pay`` callback locally without notifying the remote terminal.
    public func cancelPendingPayment(orderId: String, attemptId: String? = nil) {
        guard let config = holder.config else { return }
        if let attemptId = attemptId {
            PaymentAttemptRegistry.shared.cancel(config.terminalId, orderId, attemptId)
            PaymentClaimRegistry.shared.releaseClaim(config.terminalId, orderId, attemptId)
        } else {
            PaymentAttemptRegistry.shared.cancelLatestOpen(config.terminalId, orderId)
            releasePaymentClaim(orderId: orderId)
        }
    }

    // MARK: - Acquirer callbacks

    /// Handle an acquirer callback URL (e.g. `gomenu://pay_result?status=SUCCESS&orderid=...&type=PAY`).
    /// Call from your app's URL-scheme handler. Delivers to a pending ``pay``/``refund`` callback and
    /// publishes the result to NATS for remote initiators.
    @discardableResult
    public func deliverAcquirerCallback(_ url: URL) -> PaymentResult? {
        guard let config = holder.config else { return nil }

        if let refund = AcquirerCallbackParser.parseRefundCallback(url, config: config) {
            let enriched = refund.merging(metadata: ["operation": "refund"])
            PaymentResultDispatcher.deliver(enriched, source: .localCallback)
            return enriched
        }

        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let orderId = comps.queryItems?.first(where: { $0.name == "orderid" || $0.name == "orderId" })?.value
        guard let orderId = orderId else { return nil }

        let session = PaymentAttemptRegistry.shared.lookupOpenByOrder(config.terminalId, orderId)
        let attemptId = session?.attemptId
            ?? comps.queryItems?.first(where: { $0.name == "attemptid" || $0.name == "attemptId" })?.value
        if let attemptId = attemptId,
           VoidedAttemptRegistry.shared.isVoided(config.terminalId, orderId, attemptId) {
            return nil
        }

        guard var result = AcquirerCallbackParser.parsePayCallback(url, config: config, session: session) else { return nil }

        if result.status == .cancelled && result.metadata["cancelReason"] == nil {
            result = result.merging(metadata: ["cancelReason": PaymentCancelReason.userCancel])
        }

        let hadPayCallback = session != nil
            && PaymentAttemptRegistry.shared.hasInitiatorCallback(config.terminalId, orderId, session!.attemptId)

        PaymentResultDispatcher.deliver(result, source: .localCallback)
        return hadPayCallback ? result.merging(metadata: [Self.metaPayCallbackDelivered: "1"]) : result
    }

    /// Present on ``deliverAcquirerCallback(_:)`` return value when a pending ``pay`` callback fired.
    public static let metaPayCallbackDelivered = "payCallbackDelivered"

    /// Parses an acquirer reverse callback without publishing or dispatching terminal events.
    public func parseAcquirerCallback(_ url: URL) -> PaymentResult? {
        guard let config = holder.config else { return nil }
        if let refund = AcquirerCallbackParser.parseRefundCallback(url, config: config) { return refund }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let orderId = comps.queryItems?.first(where: { $0.name == "orderid" || $0.name == "orderId" })?.value
        else { return nil }
        let session = PaymentAttemptRegistry.shared.lookupOpenByOrder(config.terminalId, orderId)
        return AcquirerCallbackParser.parsePayCallback(url, config: config, session: session)
    }

    /// Publish a payment result to NATS when no acquirer callback is available. Dedupes by
    /// (terminalId, orderId, attemptId).
    @discardableResult
    public func publishPaymentResult(_ result: PaymentResult) -> Bool {
        let enriched: PaymentResult
        if !result.terminalId.isEmpty {
            enriched = result
        } else if let config = holder.config {
            enriched = result.with(terminalId: config.terminalId)
        } else {
            enriched = result
        }
        return PaymentResultDispatcher.deliver(enriched, source: .manualPublish, publishNats: true, dispatchTerminal: true)
    }

    // MARK: - Status

    public func setTerminalListener(_ listener: POSRouterTerminalListener?) {
        TerminalEventDispatcher.shared.listener = listener
        listener?.onLensingStateChanged(engine.currentState().publicState)
    }

    public func currentLensingState() -> LensingConnectionState { engine.currentState().publicState }

    /// Canonical ARGB indicator color for a Lensing status dot.
    public func lensingIndicatorColor(_ state: LensingConnectionState? = nil) -> UInt32 {
        LensingConnectionIndicator.colorArgb(state ?? currentLensingState())
    }

    /// Re-runs Gateway discovery and opens a fresh NATS session.
    public func reconnectLensing() {
        guard let config = holder.config else { return }
        engine.start(config, force: true)
    }

    /// After returning from background, pass elapsed background time in ms. Refreshes when the socket
    /// is dead while CONNECTED, or after a long idle while not CONNECTED.
    public func refreshLensingConnection(backgroundMs: Int64 = 0) {
        engine.refreshConnectionIfNeeded(force: false, backgroundMs: backgroundMs)
    }

    // MARK: - Result builders

    private func connectResult(_ config: POSRouterConfig, method: LocalLaunchMethod) -> PaymentResult {
        PaymentResult(
            terminalId: config.terminalId, status: .approved, transactionId: nil,
            amount: 0, currency: config.currency, message: localLaunchMessage(method, "connect"),
            localRouteMethod: method.publicRouteMethod
        )
    }

    private func localKioskConnectResult(_ config: POSRouterConfig) -> PaymentResult {
        PaymentResult(
            terminalId: config.terminalId, status: .approved, transactionId: nil,
            amount: 0, currency: config.currency, message: "POSRouter Kiosk available for local_posrouter_kiosk",
            localRouteMethod: .deepLink
        )
    }

    private func localLaunchMessage(_ method: LocalLaunchMethod, _ action: String) -> String {
        "Local \(action) launched via deep link"
    }

    private func deliver(_ callback: POSRouterCallback, _ result: PaymentResult) {
        DispatchQueue.main.async { callback.onResult(result) }
    }

    private func deliver(_ callback: POSRouterCallback, _ error: POSRouterError) {
        DispatchQueue.main.async { callback.onError(error) }
    }
}
