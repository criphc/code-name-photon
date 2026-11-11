import Foundation
import ContractKit

/// The M2.1 HTTP transport: one small client for `appctl serve` on a trusted LAN.
///
/// Wire contract (docs/reference/wire.md, M2.1 wire contract — do not invent endpoints or fields):
///   GET  /api/health
///   GET  /api/items
///   POST /api/items/{id}/prepare
///   GET  /api/items/{id}/preview          (16-bit Display P3 PNG bytes)
///   GET  /api/items/{id}/thumbnail        (512-high Display P3 HEIC bytes, ADR-0013)
///   POST /api/items/{id}/recipe           (canonical recipe JSON up, renderKey down)
///
/// Everything is plain HTTP/1.1 with a bearer token; TLS and Bonjour are **not** in M3
/// (docs/reference/client.md, scope). The client is a value type, so the UI can hand it around freely; the
/// URLSession and its delegate are immutable for the lifetime of a connection.
public struct PhotonClient: Sendable {
    /// Where the Mac is and how to authenticate against it.
    ///
    /// Nested under `PhotonClient` on purpose: the app target compiles ClientKit into its own
    /// module, and a generic top-level `Configuration` would collide with UI-layer types.
    public struct Configuration: Equatable, Sendable {
        public let host: String
        public let port: Int
        public let token: String

        public init(host: String, port: Int, token: String) {
            self.host = host
            self.port = port
            self.token = token
        }
    }

    /// Root of the API, e.g. `http://192.168.1.5:8787` (no trailing slash, no `/api` suffix).
    public let baseURL: URL

    private let session: URLSession
    private let downloadDelegate: DownloadDelegate
    /// `Authorization` header value, absent when the token is empty (an open server).
    private let authorization: String?

    // MARK: - Per-endpoint deadlines (docs/reference/client.md, architecture "Transport")

    private enum Timeout {
        static let health: TimeInterval = 15
        static let list: TimeInterval = 15
        static let prepare: TimeInterval = 60
        static let recipe: TimeInterval = 30
        static let preview: TimeInterval = 600
        /// The thumbnail is ~150 KB and the server renders it on demand in milliseconds, so it
        /// gets a short deadline instead of `preview`'s 22 MB budget.
        static let thumbnail: TimeInterval = 30
    }

    // MARK: - Lifecycle

    /// Validates the settings and builds an ephemeral session with the M3 timeouts.
    ///
    /// - Throws: `ClientError.invalidConfiguration` for an empty host, a host with embedded
    ///   whitespace/path characters, a port outside 1...65535, or a token containing a line break
    ///   (header injection). An empty token is allowed: `/api/health` needs no auth and the user
    ///   may connect before pasting the token.
    public init(configuration: Configuration) throws {
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw ClientError.invalidConfiguration(message: "the host is empty")
        }
        guard !host.contains(where: { $0.isWhitespace || $0 == "/" }) else {
            throw ClientError.invalidConfiguration(
                message: "the host '\(host)' must be a bare address (no spaces or path)"
            )
        }
        guard (1...65535).contains(configuration.port) else {
            throw ClientError.invalidConfiguration(
                message: "the port \(configuration.port) is outside 1...65535"
            )
        }
        let token = configuration.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.contains(where: { $0.isNewline }) else {
            throw ClientError.invalidConfiguration(message: "the token contains a line break")
        }

        var hostComponent = host
        if hostComponent.hasPrefix("["), hostComponent.hasSuffix("]") {
            hostComponent = String(hostComponent.dropFirst().dropLast())
        }
        if hostComponent.contains(":") {
            // Only an IPv6 literal may contain a colon. A single colon is a pasted "host:port",
            // which belongs in two separate fields.
            guard hostComponent.filter({ $0 == ":" }).count >= 2 else {
                throw ClientError.invalidConfiguration(
                    message: "the host '\(host)' must not include a port; put the port in its own field"
                )
            }
            hostComponent = "[\(hostComponent)]" // bare IPv6 literal
        }
        guard let url = URL(string: "http://\(hostComponent):\(configuration.port)") else {
            throw ClientError.invalidConfiguration(
                message: "cannot build a URL from host '\(host)' and port \(configuration.port)"
            )
        }

        self.baseURL = url
        self.authorization = token.isEmpty ? nil : "Bearer \(token)"
        let downloadDelegate = DownloadDelegate()
        self.downloadDelegate = downloadDelegate

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = Timeout.health
        sessionConfiguration.timeoutIntervalForResource = Timeout.preview
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: downloadDelegate,
            delegateQueue: nil
        )
    }

    // MARK: - Endpoints

    /// `GET /api/health` — the reachability probe; no auth required, non-blocking on the server.
    public func health() async throws -> HealthResponse {
        let data = try await send(
            path: ["api", "health"],
            method: "GET",
            timeout: Timeout.health,
            accept: "application/json"
        )
        return try Self.decode(HealthResponse.self, from: data)
    }

    /// `GET /api/items` — the batch list, unwrapped from its `{items:[…]}` envelope.
    public func listItems() async throws -> [ItemSummary] {
        let data = try await send(
            path: ["api", "items"],
            method: "GET",
            timeout: Timeout.list,
            accept: "application/json"
        )
        return try Self.decode(ItemListResponse.self, from: data).items
    }

    /// `POST /api/items/{id}/prepare` — idempotent SDR base render; `cached` says whether it was
    /// a warm hit (the UI only shows the spinner for a cold one).
    public func prepare(itemID: String) async throws -> PrepareResponse {
        let data = try await send(
            path: ["api", "items", itemID, "prepare"],
            method: "POST",
            timeout: Timeout.prepare,
            accept: "application/json"
        )
        return try Self.decode(PrepareResponse.self, from: data)
    }

    /// `GET /api/items/{id}/preview` — the 16-bit Display P3 PNG SDR base (~22 MB).
    ///
    /// The body is downloaded to a file by `URLSessionDownloadTask` (never accumulated byte by
    /// byte) and handed over as one `Data`, because the caller must SHA-256 it and ImageIO needs
    /// the whole buffer anyway. `progress` receives `0…1` fractions from the download delegate;
    /// it is invoked on a background queue, so UI callers hop to the main actor themselves.
    public func previewPNG(
        itemID: String,
        progress: ((Double) -> Void)? = nil
    ) async throws -> Data {
        let request = makeRequest(
            path: ["api", "items", itemID, "preview"],
            method: "GET",
            timeout: Timeout.preview,
            accept: "image/png"
        )
        try Task.checkCancellation()
        progress?(0)

        let task = session.downloadTask(with: request)
        let taskID = task.taskIdentifier
        let delegate = downloadDelegate
        let result: (URL, URLResponse)
        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.register(taskID: taskID, progress: progress, continuation: continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            throw Self.translate(error)
        }
        defer { try? FileManager.default.removeItem(at: result.0) }
        try Task.checkCancellation()

        let data: Data
        do {
            data = try Data(contentsOf: result.0)
        } catch {
            throw ClientError.network(
                message: "cannot read the downloaded base preview: \(error.localizedDescription)"
            )
        }
        try Self.check(response: result.1, body: data)
        progress?(1)
        return data
    }

    /// `GET /api/items/{id}/thumbnail` — the 512-high Display P3 HEIC the filmstrip shows.
    ///
    /// ~150 KB, so this is a plain data task: no download delegate and no progress callback.
    /// The server renders it on demand (milliseconds) and never runs `prepare` for it, which is
    /// why browsing no longer pulls the 22 MB base (ADR-0013).
    public func thumbnailHEIC(itemID: String) async throws -> Data {
        try await send(
            path: ["api", "items", itemID, "thumbnail"],
            method: "GET",
            timeout: Timeout.thumbnail,
            accept: "image/heic"
        )
    }

    /// `POST /api/items/{id}/recipe` — sends the canonical recipe JSON (exactly the server's
    /// accepted form) and returns the stored recipe with the server-computed `renderKey`.
    ///
    /// The recipe is validated by `RecipeDraft`/the UI before it gets here; the server validates
    /// again and re-hashes the source before storing it.
    public func postRecipe(itemID: String, recipe: Recipe) async throws -> RecipePostResponse {
        let body: Data
        do {
            body = try recipe.canonicalJSON()
        } catch {
            throw ClientError.decoding(
                message: "cannot encode the recipe as canonical JSON: \(error)"
            )
        }
        let data = try await send(
            path: ["api", "items", itemID, "recipe"],
            method: "POST",
            timeout: Timeout.recipe,
            accept: "application/json",
            body: body,
            contentType: "application/json"
        )
        return try Self.decode(RecipePostResponse.self, from: data)
    }

    // MARK: - Request plumbing

    private func makeRequest(
        path components: [String],
        method: String,
        timeout: TimeInterval,
        accept: String,
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest {
        let url = components.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    private func send(
        path components: [String],
        method: String,
        timeout: TimeInterval,
        accept: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        let request = makeRequest(
            path: components,
            method: method,
            timeout: timeout,
            accept: accept,
            body: body,
            contentType: contentType
        )
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            try Self.check(response: response, body: data)
            return data
        } catch {
            throw Self.translate(error)
        }
    }

    /// Turns any thrown error into the transport-level `ClientError`/`CancellationError` the UI
    /// understands. `ClientError`s pass through unchanged.
    static func translate(_ error: Error) -> Error {
        if let clientError = error as? ClientError { return clientError }
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return ClientError.network(message: urlError.localizedDescription)
        }
        if Task.isCancelled { return CancellationError() }
        return ClientError.network(message: error.localizedDescription)
    }

    private static func check(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decoding(message: "the Mac returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.map(status: http.statusCode, body: body)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.decoding(message: "\(type): \(error)")
        }
    }
}

// MARK: - Download progress

/// Session-level download delegate that routes progress and completion to the awaiting call.
///
/// `URLSession.download(for:delegate:)` does not deliver delegate callbacks in this SDK, so the
/// preview path uses a manually-resumed `URLSessionDownloadTask` plus this router: progress is
/// keyed by `taskIdentifier`, and `didFinishDownloadingTo` *moves* the finished file out of
/// URLSession's temporary location (the system deletes it as soon as that method returns).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
        let progress: ((Double) -> Void)?
        var fileURL: URL?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func register(
        taskID: Int,
        progress: ((Double) -> Void)?,
        continuation: CheckedContinuation<(URL, URLResponse), Error>
    ) {
        lock.lock()
        pending[taskID] = Pending(continuation: continuation, progress: progress)
        lock.unlock()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let progress = pending[downloadTask.taskIdentifier]?.progress
        lock.unlock()
        guard let progress else { return }
        progress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // This file is deleted when the method returns: claim it with a move (rename(2)), and
        // fall back to a copy only if the move crosses a volume boundary.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-preview-\(UUID().uuidString).png")
        var saved: URL?
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            saved = destination
        } catch {
            try? FileManager.default.copyItem(at: location, to: destination)
            if FileManager.default.fileExists(atPath: destination.path) {
                saved = destination
            }
        }
        lock.lock()
        pending[downloadTask.taskIdentifier]?.fileURL = saved
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error {
            if let fileURL = entry.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            entry.continuation.resume(throwing: PhotonClient.translate(error))
            return
        }
        guard let fileURL = entry.fileURL, let response = task.response else {
            if let fileURL = entry.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            entry.continuation.resume(
                throwing: ClientError.decoding(message: "the download finished without a file")
            )
            return
        }
        entry.continuation.resume(returning: (fileURL, response))
    }
}
