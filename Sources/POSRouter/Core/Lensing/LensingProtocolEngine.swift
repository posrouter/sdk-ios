import Foundation
import Nats

/// Internal Lensing Protocol engine. NATS connection is fully encapsulated from public API access.
final class LensingProtocolEngine {
    static let shared = LensingProtocolEngine()
    private init() {}

    private var natsClient: NatsClient?
    private var state: LensingState = .idle
    private var participantCode: String?
    private var natsUrl: String?
    private var natsToken: String?
    private var reconnectAttempt = 0
    private let maxBackoffMs: UInt64 = 30_000

    private var fallbackQueue: [QueuedMessage] = []
    private let queueLock = NSLock()

    func start(code: String, key: String) {
        participantCode = code
        state = .discovering

        Task {
            do {
                let credentials = try await LensingGatewayClient.fetchNatsCredentials(code: code, key: key)
                natsUrl = credentials.natsUrl
                natsToken = credentials.natsToken
                await connectNats()
            } catch {
                state = .failed
            }
        }
    }

    private func connectNats() async {
        guard let urlString = natsUrl, let token = natsToken, let code = participantCode else { return }

        state = .connecting

        do {
            guard let url = URL(string: urlString) else {
                state = .failed
                return
            }

            let client = NatsClientOptions()
                .url(url)
                .usernameAndPassword(code, token)
                .build()

            client.on(.disconnected) { [weak self] _ in
                self?.state = .reconnecting
                Task { await self?.scheduleReconnect() }
            }

            client.on(.connected) { [weak self] _ in
                self?.state = .connected
                self?.reconnectAttempt = 0
                self?.flushFallbackQueue()
            }

            try await client.connect()
            natsClient = client
            state = .connected
            reconnectAttempt = 0
            flushFallbackQueue()
        } catch {
            state = .reconnecting
            await scheduleReconnect()
        }
    }

    private func scheduleReconnect() async {
        let delayMs = min(maxBackoffMs, UInt64(1000) * UInt64(1 << min(reconnectAttempt, 5)))
        reconnectAttempt += 1
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        await connectNats()
    }

    func dispatchTransaction(
        request: PaymentRequest,
        completion: @escaping (Result<PaymentResult, POSRouterError>) -> Void
    ) {
        let targetSubject = LensingSubjects.paySubject(terminalId: request.terminalId)
        let resultSubject = LensingSubjects.resultSubject(terminalId: request.terminalId)
        let payloadBytes = Data(request.toJSONString().utf8)

        guard let client = natsClient, state == .connected else {
            enqueue(QueuedMessage(
                subject: targetSubject,
                payload: payloadBytes,
                request: request,
                completion: completion
            ))
            if state == .idle || state == .failed {
                completion(.failure(POSRouterError(code: "NOT_INITIALIZED", message: "Lensing engine not connected")))
            }
            return
        }

        Task {
            do {
                try await subscribeForResult(client: client, resultSubject: resultSubject, completion: completion)
                try await client.publish(payloadBytes, subject: targetSubject)
            } catch {
                enqueue(QueuedMessage(
                    subject: targetSubject,
                    payload: payloadBytes,
                    request: request,
                    completion: completion
                ))
                completion(.failure(POSRouterError(code: "PUBLISH_FAILED", message: error.localizedDescription)))
            }
        }
    }

    private func subscribeForResult(
        client: NatsClient,
        resultSubject: String,
        completion: @escaping (Result<PaymentResult, POSRouterError>) -> Void
    ) async throws {
        let subscription = try await client.subscribe(subject: resultSubject)

        Task {
            for try await msg in subscription {
                guard let payload = msg.payload,
                      let json = String(data: payload, encoding: .utf8),
                      let result = PaymentResult.fromJSON(json) else {
                    completion(.failure(POSRouterError(code: "PARSE_ERROR", message: "Invalid result payload")))
                    return
                }
                completion(.success(result))
                break
            }
        }
    }

    private func enqueue(_ message: QueuedMessage) {
        queueLock.lock()
        fallbackQueue.append(message)
        queueLock.unlock()
    }

    private func flushFallbackQueue() {
        queueLock.lock()
        let pending = fallbackQueue
        fallbackQueue.removeAll()
        queueLock.unlock()

        for queued in pending {
            dispatchTransaction(request: queued.request, completion: queued.completion)
        }
    }

    private struct QueuedMessage {
        let subject: String
        let payload: Data
        let request: PaymentRequest
        let completion: (Result<PaymentResult, POSRouterError>) -> Void
    }
}
