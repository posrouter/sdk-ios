import Foundation
import Nats

/// Transport abstraction the engine talks to, so the Lensing state machine is testable without a
/// live broker. The default implementation wraps `nats.swift`.
protocol LensingTransport: AnyObject {
    var onConnected: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onReconnected: (() -> Void)? { get set }
    var isConnected: Bool { get }

    func connect(url: String, token: String, participantCode: String) async throws
    func publish(_ payload: Data, subject: String) async throws
    func subscribe(subject: String, handler: @escaping (Data) -> Void) async throws
    func close()
}

/// `nats.swift`-backed transport. Subscriptions are drained on detached tasks and cancelled on close.
final class NatsLensingTransport: LensingTransport {
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReconnected: (() -> Void)?

    private var client: NatsClient?
    private var subscriptionTasks: [Task<Void, Never>] = []
    private let lock = NSLock()
    private var everConnected = false
    private var _isConnected = false

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    func connect(url: String, token: String, participantCode: String) async throws {
        guard let serverURL = URL(string: url) else {
            throw LensingException(code: "INVALID_URL", message: "Invalid NATS URL: \(url)")
        }
        let client = NatsClientOptions()
            .url(serverURL)
            .usernameAndPassword(participantCode, token)
            .build()

        _ = client.on([.connected]) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            let wasConnected = self.everConnected
            self.everConnected = true
            self._isConnected = true
            self.lock.unlock()
            if wasConnected { self.onReconnected?() } else { self.onConnected?() }
        }
        _ = client.on([.disconnected, .closed, .suspended]) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); self._isConnected = false; self.lock.unlock()
            self.onDisconnected?()
        }

        try await client.connect()
        lock.lock(); self.client = client; self._isConnected = true; self.everConnected = true; lock.unlock()
    }

    func publish(_ payload: Data, subject: String) async throws {
        guard let client = client else {
            throw LensingException(code: "NOT_CONNECTED", message: "NATS client not connected")
        }
        try await client.publish(payload, subject: subject)
    }

    func subscribe(subject: String, handler: @escaping (Data) -> Void) async throws {
        guard let client = client else {
            throw LensingException(code: "NOT_CONNECTED", message: "NATS client not connected")
        }
        let subscription = try await client.subscribe(subject: subject)
        let task = Task {
            do {
                for try await message in subscription {
                    if Task.isCancelled { break }
                    if let payload = message.payload { handler(payload) }
                }
            } catch {
                // Subscription ended (connection closed / cancelled); the engine re-subscribes on reconnect.
            }
        }
        lock.lock(); subscriptionTasks.append(task); lock.unlock()
    }

    func close() {
        lock.lock()
        let tasks = subscriptionTasks
        subscriptionTasks.removeAll()
        let client = self.client
        self.client = nil
        _isConnected = false
        lock.unlock()
        tasks.forEach { $0.cancel() }
        Task { try? await client?.close() }
    }
}
