@testable import ClientKit
import ContractKit
import Foundation
import Network
import XCTest

/// End-to-end transport tests over a real loopback HTTP server (Network.framework), so the wire
/// path — request line, headers, canonical recipe body, response decoding, status → `ClientError`,
/// download progress and cancellation — is exercised the way the iPad will use it.
///
/// If the sandbox blocks `NWListener`, every test that needs a server skips with the concrete
/// error instead of failing (same policy as the Mac server's own HTTP tests).
final class TransportTests: XCTestCase {
    // MARK: - Stub server

    private struct StubRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct StubResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
        var delay: TimeInterval = 0

        static func json(_ data: Data, status: Int = 200) -> StubResponse {
            StubResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
        }
    }

    private final class StubHTTPServer {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "TransportTests.StubHTTPServer")
        private let handler: (StubRequest, UInt16) -> StubResponse
        private let lock = NSLock()
        private var recorded: [StubRequest] = []
        private var connections: [NWConnection] = []
        private(set) var port: UInt16 = 0

        init(handler: @escaping (StubRequest, UInt16) -> StubResponse) throws {
            self.handler = handler
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener

            let ready = DispatchSemaphore(value: 0)
            var startupError: Error?
            var assignedPort: UInt16 = 0
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    assignedPort = listener.port?.rawValue ?? 0
                    ready.signal()
                case let .failed(error):
                    startupError = error
                    ready.signal()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 5) != .timedOut else {
                listener.cancel()
                throw StubServerError.startup("listener did not become ready")
            }
            if let startupError {
                listener.cancel()
                throw startupError
            }
            guard assignedPort != 0 else {
                listener.cancel()
                throw StubServerError.startup("listener became ready without a port")
            }
            self.port = assignedPort
        }

        func stop() {
            listener.cancel()
            lock.lock()
            let open = connections
            connections.removeAll()
            lock.unlock()
            for connection in open { connection.cancel() }
        }

        func recordedRequests() -> [StubRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        private func record(_ request: StubRequest) {
            lock.lock()
            recorded.append(request)
            lock.unlock()
        }

        private func accept(_ connection: NWConnection) {
            lock.lock()
            connections.append(connection)
            lock.unlock()
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.record(request)
                    let response = self.handler(request, self.port)
                    self.respond(response, on: connection)
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(connection, buffer: buffer)
            }
        }

        private func respond(_ response: StubResponse, on connection: NWConnection) {
            let send = {
                let body = response.body
                var headers = response.headers
                headers["Content-Length"] = "\(body.count)"
                headers["Connection"] = "close"
                if headers["Content-Type"] == nil {
                    headers["Content-Type"] = "application/json"
                }
                var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
                for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                    head += "\(name): \(value)\r\n"
                }
                head += "\r\n"
                var payload = Data(head.utf8)
                payload.append(body)
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            if response.delay > 0 {
                queue.asyncAfter(deadline: .now() + response.delay, execute: send)
            } else {
                send()
            }
        }

        private static func parse(_ buffer: Data) -> StubRequest? {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headerData = buffer[buffer.startIndex ..< headerEnd.lowerBound]
            guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
            var lines = headerText.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return nil }
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2, let method = requestLine.first.map(String.init) else {
                return nil
            }
            let path = String(requestLine[1])
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else {
                return nil
            }
            let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
            return StubRequest(
                method: method,
                path: path,
                headers: headers,
                body: Data(buffer[bodyStart ..< bodyEnd])
            )
        }

        private static func reason(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 409: return "Conflict"
            case 422: return "Unprocessable Entity"
            case 500: return "Internal Server Error"
            default: return "Status"
            }
        }
    }

    private enum StubServerError: Error, CustomStringConvertible {
        case startup(String)
        var description: String {
            switch self {
            case let .startup(message): return message
            }
        }
    }

    // MARK: - Test helpers

    private func makeServer(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ handler: @escaping (StubRequest, UInt16) -> StubResponse
    ) throws -> StubHTTPServer {
        do {
            return try StubHTTPServer(handler: handler)
        } catch {
            throw XCTSkip("Network.framework listener unavailable in this sandbox: \(error)", file: file, line: line)
        }
    }

    private func makeClient(port: UInt16, token: String = "s3cret") throws -> PhotonClient {
        try PhotonClient(
            configuration: PhotonClient.Configuration(
                host: "127.0.0.1",
                port: Int(port),
                token: token
            )
        )
    }

    private func makeRecipe() -> Recipe {
        Recipe.defaults(
            sourcePath: "samples/sources/R0003777-P3.tif",
            sourceSHA256: "bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116",
            width: 6000,
            height: 4000,
            encoderVersion: "5dba4e2",
            created: "2026-11-02T20:52:00+08:00"
        )
    }

    private func makeItem(id: String = "item-a", state: ItemState = .previewReady) -> ItemSummary {
        ItemSummary(
            id: id,
            name: "R0003777-P3.tif",
            path: "/batch/R0003777-P3.tif",
            state: state,
            previewReady: true,
            hasRecipe: state == .recipeReceived,
            width: 6000,
            height: 4000
        )
    }

    private func makeMeta(recipe: Recipe) -> PreviewMetadata {
        PreviewMetadata(
            source: PreviewMetadata.SourceInfo(
                path: "samples/sources/R0003777-P3.tif",
                sha256: recipe.source.sha256,
                width: 6000,
                height: 4000,
                profileName: "Display P3",
                bitsPerComponent: 16
            ),
            base: PreviewMetadata.BaseInfo(
                file: "preview-base.png",
                bytes: 100,
                sha256: String(repeating: "ab", count: 32),
                width: 2560,
                height: 1707,
                format: "png-16-p3",
                workingSpace: "linear-extended-DisplayP3-float32",
                profileName: "Display P3",
                longEdge: 2560
            ),
            recipeDefaults: recipe,
            appVersion: "0.3.0-m21",
            createdAt: "2026-11-02T23:29:20+08:00"
        )
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private func errorBody(_ code: APIErrorCode, _ message: String = "server prose") -> Data {
        encoded(APIErrorBody(code: code, message: message))
    }

    /// Asserts that `operation` throws exactly `expected` (a `ClientError`).
    private func assertClientError<T>(
        _ expected: ClientError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected), but the call succeeded", file: file, line: line)
        } catch let error as ClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(type(of: error)): \(error)", file: file, line: line)
        }
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Double] = []

        func record(_ value: Double) {
            lock.lock()
            recorded.append(value)
            lock.unlock()
        }

        var values: [Double] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    // MARK: - Happy paths

    func testHealthDecodesAndSendsTheExpectedRequest() async throws {
        let server = try makeServer { _, _ in
            StubResponse.json(self.encoded(HealthResponse(
                ok: true,
                name: "photon",
                version: "0.3.0-m21",
                itemCount: 3,
                authRequired: true
            )))
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port, token: "")

        let health = try await client.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.name, "photon")
        XCTAssertEqual(health.version, "0.3.0-m21")
        XCTAssertEqual(health.itemCount, 3)
        XCTAssertTrue(health.authRequired)

        let request = try XCTUnwrap(server.recordedRequests().first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/health")
        XCTAssertEqual(request.headers["accept"], "application/json")
    }

    func testListItemsDecodesTheBatchAndSendsTheToken() async throws {
        let items = [
            makeItem(id: "item-a", state: .previewReady),
            makeItem(id: "item-b", state: .recipeReceived),
        ]
        let server = try makeServer { _, _ in
            StubResponse.json(self.encoded(ItemListResponse(items: items)))
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)

        let listed = try await client.listItems()
        XCTAssertEqual(listed.map(\.id), ["item-a", "item-b"])
        XCTAssertEqual(listed.map(\.state), [.previewReady, .recipeReceived])

        let request = try XCTUnwrap(server.recordedRequests().first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/items")
        XCTAssertEqual(request.headers["authorization"], "Bearer s3cret")
    }

    func testPreparePostsAndDecodesThePreviewMetadata() async throws {
        let recipe = makeRecipe()
        let response = PrepareResponse(item: makeItem(), meta: makeMeta(recipe: recipe), cached: false)
        let server = try makeServer { _, _ in StubResponse.json(self.encoded(response)) }
        defer { server.stop() }
        let client = try makeClient(port: server.port)

        let prepared = try await client.prepare(itemID: "item-a")
        XCTAssertFalse(prepared.cached)
        XCTAssertEqual(prepared.meta.base.width, 2560)
        XCTAssertEqual(prepared.meta.recipeDefaults.hdr.start, 0.62)
        XCTAssertEqual(prepared.item.id, "item-a")

        let request = try XCTUnwrap(server.recordedRequests().first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/items/item-a/prepare")
        XCTAssertEqual(request.body, Data())
    }

    func testPostRecipeSendsCanonicalJSONAndReturnsTheRenderKey() async throws {
        let recipe = makeRecipe()
        let renderKey = String(repeating: "cd", count: 32)
        let response = RecipePostResponse(
            item: makeItem(state: .recipeReceived),
            recipe: recipe,
            renderKey: renderKey
        )
        let server = try makeServer { _, _ in StubResponse.json(self.encoded(response)) }
        defer { server.stop() }
        let client = try makeClient(port: server.port)

        let posted = try await client.postRecipe(itemID: "item-a", recipe: recipe)
        XCTAssertEqual(posted.renderKey, renderKey)
        XCTAssertEqual(posted.recipe, recipe)
        XCTAssertEqual(posted.item.state, .recipeReceived)

        let request = try XCTUnwrap(server.recordedRequests().first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/items/item-a/recipe")
        XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertEqual(request.headers["authorization"], "Bearer s3cret")
        XCTAssertEqual(request.body, try recipe.canonicalJSON(), "the server accepts exactly canonical JSON")
    }

    // MARK: - Error mapping over the wire

    func test409MapsToSourceChangedAndNeverSucceeds() async throws {
        let server = try makeServer { _, _ in
            StubResponse.json(
                self.errorBody(.sourceChanged, "source changed: expected sha256 a…, found b…; re-export detected"),
                status: 409
            )
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)
        do {
            _ = try await client.postRecipe(itemID: "item-a", recipe: makeRecipe())
            XCTFail("a 409 must never be treated as success")
        } catch let error as ClientError {
            XCTAssertEqual(error, .sourceChanged)
            XCTAssertTrue(error.requiresRejudge)
            XCTAssertEqual(error.userMessage, "the source was re-exported; judge it again")
        }
    }

    func testMalformedErrorBodyFallsBackToTheStatus() async throws {
        let server = try makeServer { _, _ in
            StubResponse.json(Data("not json".utf8), status: 404)
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)
        do {
            _ = try await client.prepare(itemID: "item-a")
            XCTFail("expected .notFound")
        } catch let error as ClientError {
            XCTAssertEqual(error, .notFound)
            XCTAssertTrue(error.shouldRefreshList)
        }
    }

    func testMalformedSuccessBodyThrowsDecoding() async throws {
        let server = try makeServer { _, _ in
            StubResponse.json(Data(#"{"items":"not an array"}"#.utf8))
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)
        await assertClientErrorProducedByDecoding { try await client.listItems() }
    }

    private func assertClientErrorProducedByDecoding<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected a .decoding error", file: file, line: line)
        } catch let error as ClientError {
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("expected a ClientError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Preview download

    func testPreviewDownloadsThePNGWithProgress() async throws {
        let payload = Data(repeating: 0x7f, count: 100_000)
        let server = try makeServer { _, _ in
            StubResponse(status: 200, headers: ["Content-Type": "image/png"], body: payload)
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)
        let progress = ProgressBox()

        let data = try await client.previewPNG(itemID: "item-a") { progress.record($0) }
        XCTAssertEqual(data, payload)

        let values = progress.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.first, 0, "progress starts at 0")
        XCTAssertEqual(values.last, 1, "progress ends at 1 after a complete download")
        XCTAssertEqual(values, values.sorted(), "progress must be monotonic")
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 }, "progress must stay in 0...1")

        let request = try XCTUnwrap(server.recordedRequests().first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/items/item-a/preview")
        XCTAssertEqual(request.headers["accept"], "image/png")
    }

    func testPreviewStatusErrorsAreMappedNotReturnedAsBytes() async throws {
        let server = try makeServer { _, _ in
            StubResponse.json(self.errorBody(.sourceChanged, "re-export detected"), status: 409)
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)
        await assertClientError(.sourceChanged) { try await client.previewPNG(itemID: "item-a") }
    }

    // MARK: - Thumbnail download

    func testThumbnailDownloadsTheHEICBytesVerbatim() async throws {
        let payload = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        let server = try makeServer { _, _ in
            StubResponse(status: 200, headers: ["Content-Type": "image/heic"], body: payload)
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)

        let data = try await client.thumbnailHEIC(itemID: "item-a")
        XCTAssertEqual(data, payload, "the HEIC bytes must pass through untouched")

        let request = try XCTUnwrap(server.recordedRequests().first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/items/item-a/thumbnail")
        XCTAssertEqual(request.headers["accept"], "image/heic")
        XCTAssertEqual(request.headers["authorization"], "Bearer s3cret")
    }

    func testThumbnailStatusErrorsAreMappedNotReturnedAsBytes() async throws {
        let server = try makeServer { _, _ in
            StubResponse.json(self.errorBody(.sourceUnreadable, "unsupported source"), status: 422)
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)
        await assertClientError(.sourceUnreadable) { try await client.thumbnailHEIC(itemID: "item-a") }
    }

    // MARK: - Configuration and connection failures

    func testInvalidConfigurationsAreRejectedBeforeAnyNetworkIO() {
        let bad: [PhotonClient.Configuration] = [
            PhotonClient.Configuration(host: "", port: 8787, token: "t"),
            PhotonClient.Configuration(host: "   ", port: 8787, token: "t"),
            PhotonClient.Configuration(host: "192.168.1.5:8787", port: 8787, token: "t"),
            PhotonClient.Configuration(host: "host/path", port: 8787, token: "t"),
            PhotonClient.Configuration(host: "127.0.0.1", port: 0, token: "t"),
            PhotonClient.Configuration(host: "127.0.0.1", port: 70_000, token: "t"),
            PhotonClient.Configuration(host: "127.0.0.1", port: 8787, token: "bad\r\ntoken"),
        ]
        for configuration in bad {
            XCTAssertThrowsError(try PhotonClient(configuration: configuration)) { error in
                guard case .invalidConfiguration = error as? ClientError else {
                    return XCTFail("expected .invalidConfiguration for \(configuration), got \(error)")
                }
            }
        }

        let good = PhotonClient.Configuration(host: " 192.168.1.5 ", port: 8787, token: " tok ")
        let client = try? PhotonClient(configuration: good)
        XCTAssertNotNil(client, "surrounding whitespace is trimmed, not rejected")
        XCTAssertEqual(client?.baseURL.absoluteString, "http://192.168.1.5:8787")
    }

    func testIPv6HostGetsBracketsInTheBaseURL() throws {
        let client = try PhotonClient(
            configuration: PhotonClient.Configuration(host: "fe80::1", port: 8787, token: "t")
        )
        XCTAssertEqual(client.baseURL.absoluteString, "http://[fe80::1]:8787")
    }

    func testUnreachableServerMapsToNetworkError() async throws {
        // Port 1 is privileged and unassigned on this machine: a loopback connect is refused
        // immediately, which is exactly the "Mac is not running / wrong port" case.
        let client = try PhotonClient(
            configuration: PhotonClient.Configuration(host: "127.0.0.1", port: 1, token: "t")
        )
        do {
            _ = try await client.health()
            XCTFail("expected a network error when nothing listens")
        } catch let error as ClientError {
            guard case .network = error else {
                return XCTFail("expected .network, got \(error)")
            }
            XCTAssertTrue(error.userMessage.contains("retry"))
        } catch {
            XCTFail("expected a .network ClientError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Cancellation

    func testCancellationThrowsCancellationError() async throws {
        let server = try makeServer { _, _ in
            StubResponse(
                status: 200,
                headers: [:],
                body: Data(#"{"ok":true,"name":"photon","version":"v","itemCount":0,"authRequired":false}"#.utf8),
                delay: 2
            )
        }
        defer { server.stop() }
        let client = try makeClient(port: server.port)

        let task = Task { try await client.health() }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the cancelled request to throw")
        } catch is CancellationError {
            // The documented outcome: cancellation surfaces as CancellationError.
        } catch let error as ClientError {
            // A .network cancellation is the other allowed outcome only if the URLSession reports
            // it that way; a 2 s delay with a 200 ms cancel should really be a real cancellation.
            XCTFail("expected CancellationError, got \(error)")
        } catch {
            XCTFail("expected CancellationError, got \(type(of: error)): \(error)")
        }
    }
}
