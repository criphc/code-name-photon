import Darwin
import Foundation
import XCTest
@testable import ServerKit

/// End-to-end tests for the Network.framework listener: real loopback HTTP requests, a real client
/// (URLSession for well-formed traffic, raw TCP for malformed traffic and framing assertions).
///
/// If the DSH sandbox ever blocks `NWListener`, every test skips with the concrete error instead of
/// failing; the codec tests still cover parsing/serialization in that case.
final class HTTPServerTests: XCTestCase {
    // MARK: - Helpers

    private enum SocketFailure: Error, CustomStringConvertible {
        case create(Int32)
        case connect(Int32)
        case send(Int32)
        case receive(Int32)

        var description: String {
            switch self {
            case let .create(code): return "socket() failed: errno \(code)"
            case let .connect(code): return "connect() failed: errno \(code)"
            case let .send(code): return "send() failed: errno \(code)"
            case let .receive(code): return "recv() failed: errno \(code)"
            }
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldUsePipelining = false
        return URLSession(configuration: configuration)
    }

    @discardableResult
    private func startServer(
        _ server: HTTPServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HTTPServer {
        do {
            try server.start()
            return server
        } catch {
            throw XCTSkip("Network.framework listener unavailable in this sandbox: \(error)")
        }
    }

    private func makeServer(
        _ handler: @escaping (HTTPRequest) -> HTTPResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HTTPServer {
        try makeServer(timeouts: .default, handler: handler, file: file, line: line)
    }

    /// Same as above but with injected per-connection deadlines (the tests use short ones).
    private func makeServer(
        timeouts: HTTPServer.Timeouts,
        handler: @escaping (HTTPRequest) -> HTTPResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HTTPServer {
        do {
            let server = try HTTPServer(
                bindHost: "127.0.0.1",
                port: 0,
                timeouts: timeouts,
                handler: handler
            )
            return try startServer(server, file: file, line: line)
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("could not create the loopback listener in this sandbox: \(error)")
        }
    }

    /// One-shot URLSession request with a hard timeout so a server bug fails the test instead of hanging it.
    private func perform(
        _ request: URLRequest,
        using session: URLSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (body: Data, response: HTTPURLResponse)? {
        let done = expectation(description: "http request")
        var result: (Data, HTTPURLResponse)?
        var failure: Error?
        session.dataTask(with: request) { data, response, error in
            if let error {
                failure = error
            } else if let data, let http = response as? HTTPURLResponse {
                result = (data, http)
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        if let failure {
            XCTFail("request failed: \(failure)", file: file, line: line)
            return nil
        }
        guard let result else {
            XCTFail("no HTTPURLResponse", file: file, line: line)
            return nil
        }
        return (result.0, result.1)
    }

    /// Sends `request` over a raw loopback TCP socket and reads until the server closes (EOF).
    ///
    /// `receiveTimeoutSeconds` bounds a *silent* server (the test asserts an earlier deadline); the
    /// default is generous enough for ordinary exchanges.
    private func rawExchange(
        port: UInt16,
        request: Data,
        receiveTimeoutSeconds: Int = 5
    ) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketFailure.create(errno) }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSIGPIPE: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw SocketFailure.connect(errno) }

        var offset = 0
        while offset < request.count {
            let sent: Int = request.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    request.count - offset,
                    0
                )
            }
            guard sent > 0 else { throw SocketFailure.send(errno) }
            offset += sent
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = recv(descriptor, &chunk, chunk.count, 0)
            if received > 0 {
                response.append(chunk, count: received)
            } else if received == 0 {
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno == ECONNRESET, hasCompleteHTTPResponse(response) {
                // The review flagged `ECONNRESET` as a flaky failure: the server may `cancel()` a
                // connection it has already answered while unread pipelined/body bytes are still in
                // flight, which surfaces as an RST on the client. Tolerate it only when a complete
                // HTTP response (status line + full Content-Length body) was already received;
                // anything less is a real failure and still throws.
                break
            } else {
                throw SocketFailure.receive(errno)
            }
        }
        return response
    }

    /// True when `data` contains one complete HTTP response: a CRLFCRLF-terminated head with a
    /// `Content-Length` and at least that many body bytes after the terminator.
    private func hasCompleteHTTPResponse(_ data: Data) -> Bool {
        guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[data.startIndex..<terminator.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/1.1 ") else { return false }
        var contentLength: Int?
        for line in lines where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(
                line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            )
        }
        guard let contentLength else { return false }
        return data.distance(from: terminator.upperBound, to: data.endIndex) >= contentLength
    }

    private func startWithRetry(_ server: HTTPServer, attempts: Int = 40) throws {
        var lastError: Error?
        for _ in 0..<attempts {
            do {
                try server.start()
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw lastError ?? HTTPServerError.startTimedOut
    }

    private func responseText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private func statusLine(_ data: Data) -> String? {
        responseText(data).components(separatedBy: "\r\n").first
    }

    // MARK: - Well-formed traffic

    func testServesGetOnOSAssignedPort() throws {
        let lock = NSLock()
        var requestCount = 0
        var observedMethod: HTTPMethod?
        var observedPath: String?
        var observedOnMainThread: Bool?

        let server = try makeServer { request in
            lock.lock()
            requestCount += 1
            observedMethod = request.method
            observedPath = request.path
            observedOnMainThread = Thread.isMainThread
            lock.unlock()
            return .json(Data("{\"ok\":true}".utf8))
        }
        defer { server.stop() }

        XCTAssertNotEqual(server.port, 0, "port 0 must be replaced by the OS-assigned port")
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/health")!)
        request.httpMethod = "GET"

        let result = try XCTUnwrap(perform(request, using: session))
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(result.body, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(result.response.value(forHTTPHeaderField: "Content-Length"), "11")
        XCTAssertEqual(
            result.response.value(forHTTPHeaderField: "Content-Type"),
            "application/json; charset=utf-8"
        )

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(observedMethod, .GET)
        XCTAssertEqual(observedPath, "/api/health")
        XCTAssertEqual(observedOnMainThread, false, "handler must run off the main thread")
    }

    func testServesPostWithBody() throws {
        let lock = NSLock()
        var observedBody: Data?
        var observedContentType: String?

        let server = try makeServer { request in
            lock.lock()
            observedBody = request.body
            observedContentType = request.header("content-type")
            lock.unlock()
            let summary = "\(request.method.rawValue) \(request.path) \(request.body.count) "
                + String(decoding: request.body, as: UTF8.self)
            return .text(summary)
        }
        defer { server.stop() }

        let payload = Data("{\"schema\":0}".utf8)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/items/abc/recipe")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let result = try XCTUnwrap(perform(request, using: session))
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(
            String(decoding: result.body, as: UTF8.self),
            "POST /api/items/abc/recipe \(payload.count) {\"schema\":0}"
        )

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(observedBody, payload)
        XCTAssertEqual(observedContentType, "application/json")
    }

    func testOneRequestPerConnection() throws {
        let lock = NSLock()
        var paths: [String] = []

        let server = try makeServer { request in
            lock.lock()
            paths.append(request.path)
            lock.unlock()
            return .text("ok")
        }
        defer { server.stop() }

        // Two pipelined requests in a single write: the server must answer exactly the first one and
        // close the connection (M2 is one request per connection).
        let raw = "GET /first HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            + "GET /second HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let response = try rawExchange(port: server.port, request: Data(raw.utf8))
        let text = responseText(response)

        XCTAssertEqual(statusLine(response), "HTTP/1.1 200 OK")
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 200 OK").count - 1, 1, text)
        XCTAssertTrue(text.contains("Connection: close"), text)
        XCTAssertFalse(text.contains("/second"))

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(paths, ["/first"])
    }

    // MARK: - Malformed traffic (JSON error bodies, never a silent close)

    func testMalformedRequestLineGetsJSON400() throws {
        let lock = NSLock()
        var requestCount = 0
        let server = try makeServer { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return .text("should not happen")
        }
        defer { server.stop() }

        let response = try rawExchange(
            port: server.port,
            request: Data("NOT-HTTP\r\n\r\n".utf8)
        )
        let text = responseText(response)
        XCTAssertEqual(statusLine(response), "HTTP/1.1 400 Bad Request")
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8"), text)
        XCTAssertTrue(text.contains("\"code\":\"bad_request\""), text)
        XCTAssertTrue(text.contains("Connection: close"), text)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(requestCount, 0, "a malformed request must never reach the router")
    }

    func testUnsupportedTransferEncodingGets501() throws {
        let server = try makeServer { _ in .text("should not happen") }
        defer { server.stop() }

        let raw = "POST /api/items/abc/recipe HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "\r\n"
            + "0\r\n\r\n"
        let response = try rawExchange(port: server.port, request: Data(raw.utf8))
        let text = responseText(response)
        XCTAssertEqual(statusLine(response), "HTTP/1.1 501 Not Implemented")
        XCTAssertTrue(text.contains("\"code\":\"bad_request\""), text)
        XCTAssertTrue(text.contains("Transfer-Encoding chunked"), text)
    }

    func testOversizedHeaderGets413() throws {
        let server = try makeServer { _ in .text("should not happen") }
        defer { server.stop() }

        let raw = "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Big: "
            + String(repeating: "a", count: HTTPCodec.maximumHeaderBytes + 512)
            + "\r\n\r\n"
        let response = try rawExchange(port: server.port, request: Data(raw.utf8))
        let text = responseText(response)
        XCTAssertEqual(statusLine(response), "HTTP/1.1 413 Payload Too Large")
        XCTAssertTrue(text.contains("\"code\":\"bad_request\""), text)
    }

    /// P1-10: a request that only *declares* an oversized body must get 413 from the header block
    /// alone. The old code saw "incomplete" and sat on the connection: with no body arriving it
    /// answered 400 after the 10 s read-inactivity deadline, and a body that did arrive was buffered
    /// up to the hard buffer cap first. The default timeouts are in force here, so an elapsed time
    /// under 2 s proves the early 413 decision.
    func testDeclaredOversizedBodyGets413WithoutWaitingForTheBody() throws {
        let lock = NSLock()
        var requestCount = 0
        let server = try makeServer { _ in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return .text("should not happen")
        }
        defer { server.stop() }

        // Only the header is sent: the body never starts. The old code would sit here until the
        // 10 s inactivity deadline fired and then answer 400.
        let raw = "POST /api/items/abc/recipe HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Content-Length: \(5 * 1024 * 1024)\r\n"
            + "\r\n"
        let start = Date()
        let response = try rawExchange(
            port: server.port,
            request: Data(raw.utf8),
            receiveTimeoutSeconds: 3
        )
        let elapsed = Date().timeIntervalSince(start)
        let text = responseText(response)
        XCTAssertEqual(statusLine(response), "HTTP/1.1 413 Payload Too Large", text)
        XCTAssertTrue(text.contains("\"code\":\"bad_request\""), text)
        XCTAssertLessThan(
            elapsed,
            2.0,
            "413 must come from the header block, not from the 10 s inactivity deadline"
        )

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(requestCount, 0, "an oversized body must never reach the router")
    }

    /// P1-10: LF-only framing (only `\n`, no CRLFCRLF) must be a 400 decided as soon as the terminator
    /// arrives, not a 400 after the 10 s read-inactivity deadline.
    func testLFOnlyRequestGets400Immediately() throws {
        let lock = NSLock()
        var requestCount = 0
        let server = try makeServer { _ in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return .text("should not happen")
        }
        defer { server.stop() }

        let start = Date()
        let response = try rawExchange(
            port: server.port,
            request: Data("GET /api/health\nHost: 127.0.0.1\n\n".utf8),
            receiveTimeoutSeconds: 3
        )
        let elapsed = Date().timeIntervalSince(start)
        let text = responseText(response)
        XCTAssertEqual(statusLine(response), "HTTP/1.1 400 Bad Request", text)
        XCTAssertTrue(text.contains("\"code\":\"bad_request\""), text)
        XCTAssertTrue(text.lowercased().contains("crlf"), text)
        XCTAssertLessThan(
            elapsed,
            2.0,
            "LF-only framing must be a 400 without the inactivity wait"
        )

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(requestCount, 0, "an LF-only framed request must never reach the router")
    }

    // MARK: - Deadlines (P0-2: the receive timeout must cover reading, not the handler)

    /// P0-2 regression: the 10 s receive timeout used to be armed on `.ready` and only cancelled by
    /// `send()`, so it also covered handler execution. A handler slower than the receive-inactivity
    /// deadline (1.2 s > 0.5 s) must still get its 200 answered; the old code answered 400 instead.
    func testSlowHandlerOutlivesTheReadDeadline() throws {
        let server = try makeServer(
            timeouts: HTTPServer.Timeouts(receiveInactivity: 0.5, handler: 5)
        ) { request in
            Thread.sleep(forTimeInterval: 1.2)
            return .text("slow but valid: \(request.path)")
        }
        defer { server.stop() }

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/health")!)

        let result = try XCTUnwrap(perform(request, using: session))
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(
            String(decoding: result.body, as: UTF8.self),
            "slow but valid: /api/health"
        )
    }

    /// A client that connects, sends half a request and then goes quiet must get a 400 whose body
    /// explains the inactivity (the read deadline stays in force while the request is incomplete).
    func testIncompleteRequestGets400AfterInactivity() throws {
        let server = try makeServer(
            timeouts: HTTPServer.Timeouts(receiveInactivity: 0.3, handler: 5)
        ) { _ in .text("should not happen") }
        defer { server.stop() }

        // No blank line: the request never becomes complete, so only the read deadline can answer.
        let response = try rawExchange(
            port: server.port,
            request: Data("GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
        )
        let text = responseText(response)
        XCTAssertEqual(statusLine(response), "HTTP/1.1 400 Bad Request")
        XCTAssertTrue(text.contains("\"code\":\"bad_request\""), text)
        XCTAssertTrue(text.lowercased().contains("inactivity"), text)
        XCTAssertTrue(text.contains("Connection: close"), text)
    }

    /// A handler that blows the handler budget gets a 500 `internal_error` and the connection closes;
    /// the late result is dropped (the test would otherwise see the 200 body).
    func testHandlerDeadlineReturns500() throws {
        let server = try makeServer(
            timeouts: HTTPServer.Timeouts(receiveInactivity: 5, handler: 0.3)
        ) { _ in
            Thread.sleep(forTimeInterval: 1.0)
            return .text("too late")
        }
        defer { server.stop() }

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/health")!)

        let result = try XCTUnwrap(perform(request, using: session))
        XCTAssertEqual(result.response.statusCode, 500)
        let text = responseText(result.body)
        XCTAssertTrue(text.contains("\"code\":\"internal_error\""), text)
        XCTAssertTrue(text.lowercased().contains("did not answer"), text)
        XCTAssertEqual(result.response.value(forHTTPHeaderField: "Connection"), "close")
    }

    // MARK: - Lifecycle

    func testStopFreesThePortAndIsIdempotent() throws {
        let first = try makeServer { _ in .text("first") }
        let assignedPort = first.port
        XCTAssertNotEqual(assignedPort, 0)

        first.stop()
        first.stop() // idempotent

        let second = try HTTPServer(bindHost: "127.0.0.1", port: assignedPort) { _ in .text("second") }
        defer { second.stop() }
        try startWithRetry(second)
        XCTAssertEqual(second.port, assignedPort)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(assignedPort)/api/health")!)
        let result = try XCTUnwrap(perform(request, using: session))
        XCTAssertEqual(result.body, Data("second".utf8))
    }

    func testStartIsIdempotentAndStartAfterStopThrows() throws {
        let server = try makeServer { _ in .text("ok") }
        defer { server.stop() }

        let assignedPort = server.port
        XCTAssertNoThrow(try server.start(), "start() while running must be a no-op")
        XCTAssertEqual(server.port, assignedPort)

        server.stop()
        XCTAssertThrowsError(try server.start()) { error in
            guard case HTTPServerError.alreadyStopped = error else {
                return XCTFail("expected .alreadyStopped, got \(error)")
            }
        }
    }

    func testPortInUseThrowsClearError() throws {
        let first = try makeServer { _ in .text("first") }
        defer { first.stop() }

        let second = try HTTPServer(bindHost: "127.0.0.1", port: first.port) { _ in .text("second") }
        defer { second.stop() }

        XCTAssertThrowsError(try second.start()) { error in
            guard case let HTTPServerError.bindFailed(host, port, reason) = error else {
                return XCTFail("expected .bindFailed, got \(error)")
            }
            XCTAssertEqual(host, "127.0.0.1")
            XCTAssertEqual(port, first.port)
            let text = reason.lowercased()
            XCTAssertTrue(
                text.contains("in use") || text.contains("48"),
                "expected an address-in-use reason, got: \(reason)"
            )
        }
    }
}
