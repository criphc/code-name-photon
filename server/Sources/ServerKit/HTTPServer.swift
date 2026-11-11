import Foundation
import Network
import ContractKit

/// Failures thrown by `HTTPServer.start()` / `init`. All messages are safe to print in a CLI.
public enum HTTPServerError: Error, CustomStringConvertible {
    case invalidHost(String)
    case bindFailed(host: String, port: UInt16, reason: String)
    case listenerWaiting(host: String, port: UInt16, reason: String)
    case startTimedOut
    case startInProgress
    case alreadyStopped

    public var description: String {
        switch self {
        case let .invalidHost(host):
            return "invalid bind host '\(host)'"
        case let .bindFailed(host, port, reason):
            return "could not listen on \(host):\(port): \(reason)"
        case let .listenerWaiting(host, port, reason):
            return "listener for \(host):\(port) could not become ready: \(reason)"
        case .startTimedOut:
            return "listener did not become ready within \(HTTPServer.startTimeoutSeconds) s"
        case .startInProgress:
            return "HTTPServer.start() is already in progress"
        case .alreadyStopped:
            return "HTTPServer has been stopped; create a new instance to listen again"
        }
    }
}

/// HTTP/1.1 listener on Network.framework: one request per connection, then close.
///
/// Deliberately not a production server: no TLS (M3 decision — see docs/reference/operations.md), no keep-alive, no
/// chunked encoding. It exists so the iPad can talk to the Mac over the LAN without adding a
/// package dependency to the project.
///
/// Lifecycle:
///   - `init` only validates and stores configuration; nothing is bound yet.
///   - `start()` binds and blocks until the listener is `.ready`, then publishes the actual port
///     (important for `port: 0`). Calling it again while running is a no-op; after `stop()` it
///     throws `.alreadyStopped`.
///   - `stop()` cancels the listener *and waits for its `.cancelled` state*, which releases the
///     port, then closes live connections. Idempotent.
///   - Each accepted connection is read until `HTTPCodec.isCompleteRequest` (or the read-inactivity
///     timeout / hard buffer cap). The receive deadline covers only the read phase: it is cancelled
///     the moment a complete request is parsed, so a slow `handler` is never mistaken for a slow
///     client. `handler` then runs on a dedicated serial queue (never the main thread) under a
///     separate handler deadline, the response is serialized and sent, and the connection is closed.
public final class HTTPServer {
    /// The port the listener is bound to. For `port: 0` this is the OS-assigned port after `start()`.
    ///
    /// Backed by `storedPort`, which is written only while holding `stateLock` (in `finishStart`).
    /// The public read takes the same lock, so a caller on another thread observes a synchronised
    /// value instead of racing with that write (a plain stored property was a real cross-thread
    /// access in the v5 language mode). `NSLock` is not reentrant: a path that already holds
    /// `stateLock` must use `storedPort` directly, never `port`.
    public var port: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedPort
    }

    static let startTimeoutSeconds = 10
    static let stopTimeoutSeconds = 2

    /// Per-connection deadlines. Internal so `@testable` tests can inject short values.
    struct Timeouts: Sendable {
        /// Longest a connection may stay silent while its request is still incomplete before it gets
        /// a 400 and is closed. Reset on every received chunk, and never in effect once the request
        /// has been parsed.
        var receiveInactivity: TimeInterval = 10
        /// Longest the request handler may take — including waiting on the single serial handler
        /// queue — before the connection gets a 500 and is closed.
        var handler: TimeInterval = 600

        static let `default` = Timeouts()
    }

    private let bindHost: String
    private let timeouts: Timeouts
    private let listenerQueue: DispatchQueue
    private let handlerQueue: DispatchQueue
    /// Called for every parsed request, off the main thread and serialized across connections.
    private let requestHandler: (HTTPRequest) -> HTTPResponse

    /// Protects `lifecycle`, `listener`, `pendingStart`, `startSemaphore`, `cancelSemaphore`,
    /// `connections` and `storedPort`. Not reentrant: a path that holds it must not read `port`
    /// (the public getter takes it again — that would deadlock).
    private let stateLock = NSLock()
    private enum Lifecycle { case idle, starting, ready, stopped }
    private var lifecycle: Lifecycle = .idle
    /// Backing storage for `port`; guarded by `stateLock`.
    private var storedPort: UInt16
    private var listener: NWListener?
    private var pendingStart: Result<UInt16, HTTPServerError>?
    private var startSemaphore: DispatchSemaphore?
    private var cancelSemaphore: DispatchSemaphore?
    private var connections: [UUID: HTTPConnectionHandler] = [:]

    /// - Parameters:
    ///   - bindHost: "0.0.0.0" for the LAN, "127.0.0.1" for loopback-only.
    ///   - port: 0 lets the OS pick (tests use this).
    ///   - handler: called off the main thread for every request; must be thread-safe.
    public convenience init(
        bindHost: String = "0.0.0.0",
        port: UInt16,
        handler: @escaping (HTTPRequest) -> HTTPResponse
    ) throws {
        try self.init(bindHost: bindHost, port: port, timeouts: .default, handler: handler)
    }

    /// Designated initializer. `timeouts` is internal so `@testable` tests can use short deadlines.
    init(
        bindHost: String = "0.0.0.0",
        port: UInt16,
        timeouts: Timeouts = .default,
        handler: @escaping (HTTPRequest) -> HTTPResponse
    ) throws {
        let host = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw HTTPServerError.invalidHost(bindHost) }
        self.bindHost = host
        self.storedPort = port
        self.timeouts = timeouts
        self.requestHandler = handler
        self.listenerQueue = DispatchQueue(label: "photon.http.listener")
        self.handlerQueue = DispatchQueue(label: "photon.http.handler", qos: .userInitiated)
    }

    deinit {
        stateLock.lock()
        let dyingListener = listener
        listener = nil
        let liveConnections = Array(connections.values)
        connections.removeAll()
        lifecycle = .stopped
        stateLock.unlock()
        dyingListener?.newConnectionHandler = nil
        dyingListener?.stateUpdateHandler = nil
        dyingListener?.cancel()
        for connection in liveConnections {
            connection.cancel()
        }
    }

    // MARK: - Lifecycle

    /// Starts accepting connections. Returns once the listener is ready; throws if the port cannot
    /// be bound (e.g. already in use).
    public func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        stateLock.lock()
        switch lifecycle {
        case .ready:
            stateLock.unlock()
            return
        case .stopped:
            stateLock.unlock()
            throw HTTPServerError.alreadyStopped
        case .starting:
            stateLock.unlock()
            throw HTTPServerError.startInProgress
        case .idle:
            lifecycle = .starting
            pendingStart = nil
            startSemaphore = semaphore
            stateLock.unlock()
        }

        let newListener: NWListener
        do {
            newListener = try makeListener()
        } catch {
            stateLock.lock()
            lifecycle = .idle
            startSemaphore = nil
            stateLock.unlock()
            throw error
        }

        stateLock.lock()
        listener = newListener
        stateLock.unlock()

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            self?.listenerStateChanged(state)
        }
        newListener.start(queue: listenerQueue)

        let waitResult = semaphore.wait(timeout: .now() + .seconds(Self.startTimeoutSeconds))

        stateLock.lock()
        let outcome = pendingStart
        pendingStart = nil
        startSemaphore = nil
        let timedOut = (waitResult == .timedOut)
        if timedOut {
            if case .starting = lifecycle { lifecycle = .idle }
        }
        stateLock.unlock()

        if timedOut || outcome == nil {
            discardListener()
            throw HTTPServerError.startTimedOut
        }
        switch outcome {
        case .success?:
            return
        case let .failure(error)?:
            discardListener()
            throw error
        case nil:
            discardListener()
            throw HTTPServerError.startTimedOut
        }
    }

    /// Stops the listener and closes in-flight connections. Idempotent.
    public func stop() {
        stateLock.lock()
        if case .stopped = lifecycle {
            stateLock.unlock()
            return
        }
        lifecycle = .stopped
        let dyingListener = listener
        listener = nil
        let liveConnections = Array(connections.values)
        connections.removeAll()
        var semaphore: DispatchSemaphore?
        if dyingListener != nil {
            let cancelSemaphore = DispatchSemaphore(value: 0)
            self.cancelSemaphore = cancelSemaphore
            semaphore = cancelSemaphore
        }
        stateLock.unlock()

        guard let dyingListener else {
            for connection in liveConnections { connection.cancel() }
            return
        }
        dyingListener.newConnectionHandler = nil
        dyingListener.cancel()

        // Cancelling releases the listening socket asynchronously; waiting for `.cancelled` means a
        // caller can immediately bind the same port again (tests assert that).
        if let semaphore {
            _ = semaphore.wait(timeout: .now() + .seconds(Self.stopTimeoutSeconds))
        }
        stateLock.lock()
        cancelSemaphore = nil
        stateLock.unlock()

        for connection in liveConnections { connection.cancel() }
    }

    // MARK: - Listener plumbing

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port
        if port == 0 {
            endpointPort = .any
        } else if let value = NWEndpoint.Port(rawValue: port) {
            endpointPort = value
        } else {
            throw HTTPServerError.bindFailed(host: bindHost, port: port, reason: "invalid TCP port")
        }
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(bindHost),
            port: endpointPort
        )
        do {
            return try NWListener(using: parameters)
        } catch {
            throw HTTPServerError.bindFailed(
                host: bindHost,
                port: port,
                reason: String(describing: error)
            )
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            stateLock.lock()
            let assignedPort = listener?.port?.rawValue ?? 0
            stateLock.unlock()
            if assignedPort == 0 {
                finishStart(.failure(HTTPServerError.bindFailed(
                    host: bindHost,
                    port: port,
                    reason: "listener became ready without an assigned port"
                )))
            } else {
                finishStart(.success(assignedPort))
            }
        case let .failed(error):
            finishStart(.failure(HTTPServerError.bindFailed(
                host: bindHost,
                port: port,
                reason: String(describing: error)
            )))
            discardListener()
        case let .waiting(error):
            // A local TCP listener should not wait; surfacing it beats hanging in start().
            finishStart(.failure(HTTPServerError.listenerWaiting(
                host: bindHost,
                port: port,
                reason: String(describing: error)
            )))
            discardListener()
        case .cancelled:
            stateLock.lock()
            let semaphore = cancelSemaphore
            cancelSemaphore = nil
            stateLock.unlock()
            semaphore?.signal()
        default:
            break
        }
    }

    private func finishStart(_ outcome: Result<UInt16, HTTPServerError>) {
        stateLock.lock()
        guard case .starting = lifecycle else {
            stateLock.unlock()
            return
        }
        switch outcome {
        case let .success(assignedPort):
            // Written under `stateLock`; `port`'s getter takes the same lock, so unlocking publishes
            // the assigned port to every reader.
            storedPort = assignedPort
            lifecycle = .ready
        case .failure:
            lifecycle = .idle
        }
        pendingStart = outcome
        let semaphore = startSemaphore
        startSemaphore = nil
        stateLock.unlock()
        semaphore?.signal()
    }

    private func discardListener() {
        stateLock.lock()
        let dyingListener = listener
        listener = nil
        stateLock.unlock()
        dyingListener?.newConnectionHandler = nil
        dyingListener?.stateUpdateHandler = nil
        dyingListener?.cancel()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        let isReady = {
            if case .ready = lifecycle { return true }
            return false
        }()
        stateLock.unlock()
        guard isReady else {
            connection.cancel()
            return
        }

        let handler = HTTPConnectionHandler(
            connection: connection,
            server: self,
            timeouts: timeouts
        )
        stateLock.lock()
        let accepted: Bool
        if case .ready = lifecycle {
            connections[handler.id] = handler
            accepted = true
        } else {
            accepted = false
        }
        stateLock.unlock()
        guard accepted else {
            connection.cancel()
            return
        }
        handler.start()
    }

    fileprivate func forget(_ handler: HTTPConnectionHandler) {
        stateLock.lock()
        connections.removeValue(forKey: handler.id)
        stateLock.unlock()
    }

    fileprivate var requestHandlerClosure: (HTTPRequest) -> HTTPResponse { requestHandler }

    fileprivate var handlerDispatchQueue: DispatchQueue { handlerQueue }

    // MARK: - Error responses

    /// The error mapping for protocol-level failures: 400 / 413 / 501 with an `APIErrorBody` so the
    /// M3 client can switch on `code` instead of prose.
    fileprivate static func protocolErrorResponse(_ error: HTTPCodecError) -> HTTPResponse {
        switch error {
        case let .malformed(message):
            return errorResponse(status: 400, code: .badRequest, message: message)
        case let .tooLarge(message):
            return errorResponse(status: 413, code: .badRequest, message: message)
        case let .unsupported(message):
            return errorResponse(status: 501, code: .badRequest, message: message)
        case .incomplete:
            return errorResponse(
                status: 400,
                code: .badRequest,
                message: "incomplete HTTP request"
            )
        }
    }

    fileprivate static func errorResponse(status: Int, code: APIErrorCode, message: String) -> HTTPResponse {
        let body = (try? JSONCoding.encode(APIErrorBody(code: code, message: message))) ?? Data()
        var response = HTTPResponse.json(body, status: status)
        response.headers["cache-control"] = "no-store"
        return response
    }
}

// MARK: - One connection

/// Buffers one connection's bytes on a private serial queue, parses exactly one request, invokes the
/// server handler, writes one response and closes.
///
/// Concurrency invariant (the reason this class needs no lock, and the thing to preserve under
/// Swift 6 strict concurrency): every mutable field — `buffer`, `didRespond`, `didClose`, both
/// deadline work items — is touched only on `queue`. Network.framework delivers the connection
/// state-update handler, every receive completion and the send `.contentProcessed` completion on the
/// queue passed to `connection.start(queue:)`, i.e. on `queue`; `close()`/`send()`/`process()` are
/// therefore only ever entered on `queue`. The request handler runs on `HTTPServer`'s shared handler
/// queue: it must not read any of that state. It receives only a value (`HTTPRequest`) and hands a
/// value (`HTTPResponse`) back with `queue.async`; `send` on the connection queue is the single
/// arbiter — `didRespond` makes it a no-op for late results (handler deadline or closed connection).
private final class HTTPConnectionHandler {
    let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var server: HTTPServer?
    private let timeouts: HTTPServer.Timeouts

    private var buffer = Data()
    private var didRespond = false
    private var didClose = false
    private var readDeadlineWork: DispatchWorkItem?
    private var handlerDeadlineWork: DispatchWorkItem?

    private static let receiveChunk = 64 * 1024
    private static let maximumBufferedBytes =
        HTTPCodec.maximumHeaderBytes + HTTPCodec.maximumBodyBytes + 8 * 1024

    init(connection: NWConnection, server: HTTPServer, timeouts: HTTPServer.Timeouts) {
        let identifier = UUID()
        self.id = identifier
        self.connection = connection
        self.server = server
        self.timeouts = timeouts
        self.queue = DispatchQueue(label: "photon.http.connection.\(identifier.uuidString)")
    }

    deinit {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        connection.start(queue: queue)
    }

    /// Called from `HTTPServer.stop()` (possibly from another thread); hops onto the connection queue.
    func cancel() {
        queue.async { [weak self] in
            self?.close()
        }
    }

    // MARK: State

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            armReadDeadline()
            receiveNext()
        case .failed, .cancelled, .waiting:
            close()
        default:
            break
        }
    }

    private func close() {
        // Connection queue only (state-update handler, receive completion, send completion, cancel()).
        guard !didClose else { return }
        didClose = true
        didRespond = true
        cancelReadDeadline()
        cancelHandlerDeadline()
        connection.stateUpdateHandler = nil
        connection.cancel()
        server?.forget(self)
    }

    // MARK: Reading

    private func receiveNext() {
        // The completion runs on the connection queue (the queue passed to `start`), so every state
        // read in it is a same-queue access.
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.receiveChunk
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.didClose else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if error != nil {
                self.close()
                return
            }
            if self.didRespond { return }

            if HTTPCodec.isCompleteRequest(self.buffer) {
                self.process(clientClosed: isComplete)
                return
            }
            if !HTTPCodec.hasCompleteHeaders(self.buffer),
               self.buffer.count > HTTPCodec.maximumHeaderBytes + 4 {
                // No CRLFCRLF and already past the header limit: let the parser say 413.
                self.process(clientClosed: isComplete)
                return
            }
            if self.buffer.count > Self.maximumBufferedBytes {
                self.process(clientClosed: isComplete)
                return
            }
            if isComplete {
                if self.buffer.isEmpty {
                    self.close()
                } else {
                    self.process(clientClosed: true)
                }
                return
            }
            // Still an incomplete request: reset the inactivity deadline for the next chunk.
            self.armReadDeadline()
            self.receiveNext()
        }
    }

    // MARK: Processing

    private func process(clientClosed: Bool) {
        // The request bytes are in hand: the read deadline must never cover handler execution, so it
        // is cancelled before anything else (the handler deadline takes over in `dispatch`).
        cancelReadDeadline()
        do {
            let request = try HTTPCodec.parseRequest(buffer)
            dispatch(request)
        } catch let codecError as HTTPCodecError {
            if case .incomplete = codecError {
                if clientClosed {
                    send(HTTPServer.protocolErrorResponse(.malformed(
                        "connection closed before the HTTP request was complete"
                    )))
                } else {
                    send(HTTPServer.protocolErrorResponse(.tooLarge(
                        "request exceeds the server limits (\(HTTPCodec.maximumHeaderBytes)-byte header, "
                            + "\(HTTPCodec.maximumBodyBytes)-byte body, \(Self.maximumBufferedBytes)-byte buffer)"
                    )))
                }
            } else {
                send(HTTPServer.protocolErrorResponse(codecError))
            }
        } catch {
            send(HTTPServer.errorResponse(
                status: 500,
                code: .internalError,
                message: "unexpected error while parsing the request: \(error)"
            ))
        }
    }

    private func dispatch(_ request: HTTPRequest) {
        guard let server else {
            close()
            return
        }
        // `dispatch` is reached from `process`, i.e. on the connection queue, so this read is safe.
        // A close that races after this point is resolved where it belongs: the handler result comes
        // back to the connection queue and `send` drops it.
        guard !didClose else { return }
        let handler = server.requestHandlerClosure
        let handlerQueue = server.handlerDispatchQueue
        // Captured before the hop: the handler queue must not touch `self`'s connection state.
        let connectionQueue = queue
        // Armed before the queue hop so time spent waiting behind a cold prepare counts against the
        // handler budget rather than against the client's read budget.
        armHandlerDeadline()
        handlerQueue.async { [weak self] in
            // Handler queue. Never read `buffer`/`didClose`/`didRespond`/deadline items here: they
            // are confined to `connectionQueue` (see the class comment). The weak check below only
            // tests that the connection object still exists; it is not connection state.
            guard self != nil else { return }
            let response = handler(request)
            connectionQueue.async { [weak self] in
                // Back on the connection queue: `send` owns the one authoritative `didRespond`
                // decision, so a result that lost the race to the handler deadline (or to `close`)
                // is dropped instead of being written after the 500/close.
                self?.send(response)
            }
        }
    }

    // MARK: Writing

    private func send(_ response: HTTPResponse) {
        // Connection queue only. This guard is the single arbiter for "is a response still allowed":
        // handler results, the read deadline and the handler deadline all funnel through here.
        guard !didRespond, !didClose else { return }
        didRespond = true
        cancelReadDeadline()
        cancelHandlerDeadline()
        let bytes = HTTPCodec.serialize(response)
        connection.send(
            content: bytes,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.close() }
            }
        )
    }

    // MARK: Deadlines

    /// (Re)arms the read-inactivity deadline. It covers only the receive phase: `process` cancels it
    /// as soon as a complete request arrives, so handler execution can never trip it. The work item is
    /// scheduled on the connection queue, so it may touch `didRespond`/`didClose` directly.
    private func armReadDeadline() {
        cancelReadDeadline()
        let seconds = timeouts.receiveInactivity
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.didRespond, !self.didClose else { return }
            self.send(HTTPServer.errorResponse(
                status: 400,
                code: .badRequest,
                message: "no complete HTTP request received within "
                    + "\(Self.secondsDescription(seconds)) s of inactivity"
            ))
        }
        readDeadlineWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelReadDeadline() {
        readDeadlineWork?.cancel()
        readDeadlineWork = nil
    }

    /// Arms the handler budget. A hung handler cannot be cancelled from the outside: it keeps holding
    /// the single serial handler queue (and, through `APIRouter`, the `ItemStore` lock) until it
    /// returns. The deadline only stops the connection from waiting forever — the client gets a 500
    /// instead of a hang — and the late handler result is dropped by `send`'s `didRespond` guard.
    /// The work item is scheduled on the connection queue, so it may touch the connection state.
    private func armHandlerDeadline() {
        cancelHandlerDeadline()
        let seconds = timeouts.handler
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.didRespond, !self.didClose else { return }
            self.send(HTTPServer.errorResponse(
                status: 500,
                code: .internalError,
                message: "the request handler did not answer within "
                    + "\(Self.secondsDescription(seconds)) s"
            ))
        }
        handlerDeadlineWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelHandlerDeadline() {
        handlerDeadlineWork?.cancel()
        handlerDeadlineWork = nil
    }

    /// "10" for whole-second timeouts and "0.3" for the shortened timeouts tests inject.
    private static func secondsDescription(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%g", seconds)
    }
}
