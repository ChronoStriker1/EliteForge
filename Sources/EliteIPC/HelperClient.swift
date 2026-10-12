import EliteKit
import Foundation

public enum HelperClientError: Error, LocalizedError {
    case unavailable(String)
    case failed(String)
    case unexpectedReply

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "The EliteForge helper isn't reachable. Is it installed? (\(detail))"
        case .failed(let message): message
        case .unexpectedReply: "The helper sent an unexpected reply."
        }
    }
}

/// Receives helper events on the XPC connection and passes them to the client.
final class EventForwarder: NSObject, HelperClientXPCProtocol {
    weak var client: HelperClient?

    init(client: HelperClient) { self.client = client }

    func receive(_ event: Data) { client?.receive(event) }
}

/// Talks to the root helper over XPC.
public final class HelperClient: NSObject, @unchecked Sendable {
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    /// Called on an XPC queue for every event the helper sends.
    public var onEvent: ((HelperEvent) -> Void)?
    /// Called when the connection to the helper drops.
    public var onInterrupted: (() -> Void)?

    public override init() { super.init() }

    deinit { connection?.invalidate() }

    private func proxy(_ errorHandler: @escaping (Error) -> Void) -> HelperXPCProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: HelperClientXPCProtocol.self)
            // The connection retains its exported object; a weak forwarder
            // keeps that from retaining this client.
            connection.exportedObject = EventForwarder(client: self)
            connection.interruptionHandler = { [weak self] in self?.onInterrupted?() }
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let self else { return }
                // A connection replaced after disconnect() may invalidate late; only
                // clear state if it's still the current one.
                let current = self.lock.withLock { () -> Bool in
                    guard let connection, self.connection === connection else { return false }
                    self.connection = nil
                    return true
                }
                if current { self.onInterrupted?() }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? HelperXPCProtocol
    }

    public func disconnect() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    public func receive(_ event: Data) {
        if let event = try? HelperCoding.decode(HelperEvent.self, from: event) { onEvent?(event) }
    }

    public func perform(_ request: HelperRequest) async throws -> HelperReply {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = self.proxy { error in
                once.run { continuation.resume(throwing: HelperClientError.unavailable(error.localizedDescription)) }
            }
            guard let proxy else {
                once.run { continuation.resume(throwing: HelperClientError.unavailable("no proxy")) }
                return
            }
            proxy.perform(HelperCoding.encode(request)) { data in
                once.run {
                    do {
                        let reply = try HelperCoding.decode(HelperReply.self, from: data)
                        if case .failure(let message) = reply {
                            continuation.resume(throwing: HelperClientError.failed(message))
                        } else {
                            continuation.resume(returning: reply)
                        }
                    } catch {
                        continuation.resume(throwing: HelperClientError.unexpectedReply)
                    }
                }
            }
        }
    }

    /// Blocking variant for command-line use. Don't call on the main thread of an app.
    public func performSync(_ request: HelperRequest, timeout: TimeInterval = 15) throws -> HelperReply {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<HelperReply, Error> = .failure(HelperClientError.unavailable("timed out"))
        Task.detached {
            do { result = .success(try await self.perform(request)) } catch { result = .failure(error) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw HelperClientError.unavailable("timed out")
        }
        return try result.get()
    }

    // MARK: Typed helpers

    public func status() async throws -> ControllerStatus {
        guard case .status(let status) = try await perform(.status) else { throw HelperClientError.unexpectedReply }
        return status
    }

    public func readSlot(_ slot: Int) async throws -> SlotPages {
        guard case .pages(let pages) = try await perform(.readSlot(slot)) else { throw HelperClientError.unexpectedReply }
        return pages
    }

    public func readName() async throws -> String {
        guard case .name(let name) = try await perform(.readName) else { throw HelperClientError.unexpectedReply }
        return name
    }

    public func writeName(_ name: String, serial: String?) async throws -> String {
        guard case .name(let stored) = try await perform(.writeName(name, serial: serial)) else { throw HelperClientError.unexpectedReply }
        return stored
    }
}

/// Runs a closure at most once; XPC can call both the reply and the error handler.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}
