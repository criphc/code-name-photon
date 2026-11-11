import Foundation
import XCTest
@testable import ServerKit

/// Parser/serializer tests for the M2 HTTP/1.1 codec. No network, no files: every fixture is a byte
/// string built in the test.
final class HTTPCodecTests: XCTestCase {
    // MARK: - Helpers

    private func data(_ string: String) -> Data { Data(string.utf8) }

    private func parse(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> HTTPRequest? {
        do {
            return try HTTPCodec.parseRequest(data(raw))
        } catch {
            XCTFail("expected a successful parse, got \(error)", file: file, line: line)
            return nil
        }
    }

    private func parseError(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> HTTPCodecError? {
        do {
            _ = try HTTPCodec.parseRequest(data(raw))
            XCTFail("expected parseRequest to throw", file: file, line: line)
            return nil
        } catch let error as HTTPCodecError {
            return error
        } catch {
            XCTFail("expected an HTTPCodecError, got \(error)", file: file, line: line)
            return nil
        }
    }

    /// The failure class, without the message text: these tests pin classification, and the failing
    /// variant is still named by the XCTAssertEqual message.
    private enum CodecFailure: Equatable {
        case incomplete, malformed, unsupported, tooLarge
    }

    private func parseFailure(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CodecFailure? {
        guard let error = parseError(raw, file: file, line: line) else { return nil }
        switch error {
        case .incomplete: return .incomplete
        case .malformed: return .malformed
        case .unsupported: return .unsupported
        case .tooLarge: return .tooLarge
        }
    }

    private func split(_ response: Data) -> (head: String, body: Data)? {
        guard let range = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: response[response.startIndex..<range.lowerBound], as: UTF8.self)
        return (head, Data(response[range.upperBound...]))
    }

    private func headerLines(_ head: String) -> [String] {
        head.components(separatedBy: "\r\n")
    }

    private func headerValue(_ name: String, in head: String) -> String? {
        for line in headerLines(head) where line.hasPrefix(name + ":") {
            return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Request parsing

    func testParsesGetWithQueryAndPercentEncodedPath() throws {
        let request = try XCTUnwrap(parse(
            "GET /api/items/a%20b/preview?x=1&name=hello%20world HTTP/1.1\r\n"
                + "Host: mac.local:8787\r\n"
                + "Accept: */*\r\n"
                + "\r\n"
        ))
        XCTAssertEqual(request.method, .GET)
        XCTAssertEqual(request.path, "/api/items/a b/preview")
        XCTAssertEqual(request.query, ["x": "1", "name": "hello world"])
        XCTAssertEqual(request.header("host"), "mac.local:8787")
        XCTAssertEqual(request.header("ACCEPT"), "*/*")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testParsesPostWithBody() throws {
        let json = "{\"schema\":0}"
        let raw = "POST /api/items/abc/recipe HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8787\r\n"
            + "content-type: application/json\r\n"
            + "Content-Length: \(json.utf8.count)\r\n"
            + "\r\n"
            + json
        let request = try XCTUnwrap(parse(raw))
        XCTAssertEqual(request.method, .POST)
        XCTAssertEqual(request.path, "/api/items/abc/recipe")
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), json)
        // The serializer owns Content-Length, but the parser keeps the client's value in headers.
        XCTAssertEqual(request.header("content-length"), "\(json.utf8.count)")
    }

    func testParsesBinaryBodyWithNULAndCRLFBytes() throws {
        let body = Data([0x00, 0x0D, 0x0A, 0xFF, 0x00, 0x0D, 0x0A, 0x0D, 0x0A])
        var raw = Data("POST /api/items/x/recipe HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        raw.append(body)
        let request = try XCTUnwrap(try? HTTPCodec.parseRequest(raw))
        XCTAssertEqual(request.body, body)
    }

    func testHeaderNamesAreCaseInsensitiveAndValuesTrimmed() throws {
        let request = try XCTUnwrap(parse(
            "GET /api/health HTTP/1.1\r\n"
                + "X-Photon-Token:   \t secret-token \t \r\n"
                + "x-photon-token: second-value\r\n"
                + "\r\n"
        ))
        // Lowercased keys and last duplicate wins.
        XCTAssertEqual(request.headers["x-photon-token"], "second-value")
        XCTAssertEqual(request.headers.keys.filter { $0 == "x-photon-token" }.count, 1)
        XCTAssertEqual(request.header("X-PHOTON-TOKEN"), "second-value")
        XCTAssertNil(request.headers["X-Photon-Token"])
    }

    func testHeaderValueSplitsOnFirstColonOnly() throws {
        let request = try XCTUnwrap(parse(
            "GET / HTTP/1.1\r\nX-Thing: a:b:c \r\n\r\n"
        ))
        XCTAssertEqual(request.header("x-thing"), "a:b:c")
    }

    func testParsesAbsoluteFormTarget() throws {
        let request = try XCTUnwrap(parse(
            "GET http://127.0.0.1:8787/api/health?probe=1 HTTP/1.1\r\nHost: 127.0.0.1:8787\r\n\r\n"
        ))
        XCTAssertEqual(request.path, "/api/health")
        XCTAssertEqual(request.query, ["probe": "1"])
    }

    func testParsesAbsoluteFormTargetWithoutPath() throws {
        let request = try XCTUnwrap(parse("GET http://127.0.0.1:8787 HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request.path, "/")
        XCTAssertTrue(request.query.isEmpty)
    }

    func testParsesBarePathAndEmptyQuery() throws {
        let bare = try XCTUnwrap(parse("GET /api/health HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(bare.path, "/api/health")
        XCTAssertTrue(bare.query.isEmpty)

        let emptyQuery = try XCTUnwrap(parse("GET /api/health? HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(emptyQuery.path, "/api/health")
        XCTAssertTrue(emptyQuery.query.isEmpty)
    }

    func testQueryDecodingKeepsLastValueAndDecodesPlusAsSpace() throws {
        let request = try XCTUnwrap(parse(
            "GET /api/items?tag=a&tag=b&q=hello+world&flag&empty=&a%20b=c%2Fd HTTP/1.1\r\n\r\n"
        ))
        XCTAssertEqual(request.query["tag"], "b")
        XCTAssertEqual(request.query["q"], "hello world")
        XCTAssertEqual(request.query["flag"], "")
        XCTAssertEqual(request.query["empty"], "")
        XCTAssertEqual(request.query["a b"], "c/d")
    }

    func testAcceptsAnyKnownMethodCaseInsensitively() throws {
        for method in ["get", "Get", "POST", "delete", "HEAD", "OPTIONS", "PUT", "PATCH"] {
            let request = try XCTUnwrap(parse("\(method) /api/health HTTP/1.1\r\n\r\n"))
            XCTAssertEqual(request.method.rawValue, method.uppercased())
        }
    }

    func testToleratesTrailingBytesAfterCompleteBody() throws {
        // One request per connection: pipelined bytes after Content-Length are ignored, not an error.
        let request = try XCTUnwrap(parse(
            "POST /first HTTP/1.1\r\nContent-Length: 4\r\n\r\nbodyGET /second HTTP/1.1\r\n\r\n"
        ))
        XCTAssertEqual(request.path, "/first")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "body")
    }

    func testParsesStarTarget() throws {
        let request = try XCTUnwrap(parse("OPTIONS * HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request.path, "*")
    }

    // MARK: - Malformed requests

    func testRejectsMalformedRequestLines() {
        let cases: [(String, CodecFailure)] = [
            ("GET /\r\n\r\n", .malformed),
            ("GET  / HTTP/1.1\r\n\r\n", .malformed),
            ("GET / HTTP/1.1 extra\r\n\r\n", .malformed),
            ("GET / 1.1\r\n\r\n", .malformed),
            ("GET / HTTP/1.0\r\n\r\n", .unsupported),
            ("GET / HTTP/2.0\r\n\r\n", .unsupported),
            ("BREW / HTTP/1.1\r\n\r\n", .unsupported),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(parseFailure(raw), expected, "for \(raw.debugDescription)")
        }
    }

    func testRejectsHeaderLineWithoutColon() {
        // One exact message stays pinned: the text is user-facing.
        XCTAssertEqual(
            parseError("GET / HTTP/1.1\r\nHost 127.0.0.1\r\n\r\n"),
            .malformed("header line without ':'")
        )
    }

    func testRejectsHeaderNameWithWhitespace() {
        XCTAssertEqual(
            parseFailure("GET / HTTP/1.1\r\nBad Header: x\r\n\r\n"),
            .malformed
        )
    }

    func testRejectsConflictingContentLength() {
        XCTAssertEqual(
            parseFailure("POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!"),
            .malformed
        )
    }

    func testAcceptsRepeatedIdenticalContentLength() throws {
        let request = try XCTUnwrap(parse(
            "POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello"
        ))
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")
    }

    func testRejectsInvalidContentLength() {
        for value in ["abc", "-1", "5x", "1.5", ""] {
            let raw = "POST /x HTTP/1.1\r\nContent-Length: \(value)\r\n\r\nhello"
            guard let error = parseError(raw) else { continue }
            if case .malformed = error {
                // expected
            } else {
                XCTFail("Content-Length '\(value)' produced \(error)")
            }
        }
    }

    func testRejectsChunkedTransferEncoding() {
        let error = parseError(
            "POST /api/items/x/recipe HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        )
        guard case let .unsupported(message) = error else {
            return XCTFail("expected .unsupported, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("Transfer-Encoding chunked"), message)
    }

    /// P1-10: every `Transfer-Encoding` value is checked, not just the first one. A first `identity`
    /// used to mask a second `chunked` value.
    func testChecksEveryTransferEncodingValue() {
        let mixed = "POST /x HTTP/1.1\r\n"
            + "Transfer-Encoding: identity\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "\r\n0\r\n\r\n"
        guard case let .unsupported(message)? = parseError(mixed) else {
            return XCTFail("expected .unsupported when a later Transfer-Encoding is chunked")
        }
        XCTAssertTrue(message.contains("Transfer-Encoding chunked"), message)

        let rejected = [
            // Two non-identity values.
            "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            // A single header with a comma-separated coding list.
            "POST /x HTTP/1.1\r\nTransfer-Encoding: identity, chunked\r\n\r\n0\r\n\r\n",
            // Header names and coding values are case-insensitive.
            "POST /x HTTP/1.1\r\nTransfer-Encoding: Identity\r\nTransfer-Encoding: Chunked\r\n\r\n0\r\n\r\n",
            // An empty value is not `identity` either.
            "POST /x HTTP/1.1\r\nTransfer-Encoding:\r\n\r\n",
        ]
        for raw in rejected {
            guard case .unsupported? = parseError(raw) else {
                return XCTFail("expected .unsupported for \(raw.debugDescription)")
            }
        }
    }

    /// Duplicate `identity` values do not change the framing, so they are accepted; the body length
    /// still comes from `Content-Length` (both values are inspected, not just the first).
    func testAcceptsRepeatedIdentityTransferEncoding() throws {
        let request = try XCTUnwrap(parse(
            "POST /x HTTP/1.1\r\n"
                + "Transfer-Encoding: identity\r\n"
                + "Transfer-Encoding: identity\r\n"
                + "Content-Length: 5\r\n\r\nhello"
        ))
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")
    }

    /// P1-10: LF-only framing is reported complete and is a `.malformed` (400), never `.incomplete`
    /// (which would make the connection wait for the inactivity timeout).
    func testLFOnlyHeaderTerminatorIsCompleteAndMalformed() {
        let lfOnly = "GET /api/health\nHost: 127.0.0.1\n\n"
        XCTAssertTrue(HTTPCodec.isCompleteRequest(data(lfOnly)))
        guard case let .malformed(message)? = parseError(lfOnly) else {
            return XCTFail("expected .malformed for LF-only headers")
        }
        XCTAssertTrue(message.contains("CRLF-terminated"), message)

        // No terminator yet: still incomplete, and no false positive for a lone LF.
        let partial = "GET /api/health\nHost: 127.0.0.1\n"
        XCTAssertFalse(HTTPCodec.isCompleteRequest(data(partial)))
        XCTAssertEqual(parseError(partial), .incomplete)
        // A chunk boundary in the middle of a valid CRLFCRLF is not an LF-only terminator.
        XCTAssertFalse(HTTPCodec.isCompleteRequest(data("GET / HTTP/1.1\r\nHost: x\r")))
    }

    /// The LF-only detection only runs while no CRLFCRLF has arrived, so `\n\n` bytes inside a
    /// CRLF-framed body must never be misclassified as malformed framing.
    func testCRLFFramedBodyContainingLFBytesIsNotMisclassified() throws {
        let body = Data("a\n\nb".utf8)
        var raw = Data("POST /x HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        raw.append(body)
        XCTAssertTrue(HTTPCodec.isCompleteRequest(raw))
        let request = try XCTUnwrap(try? HTTPCodec.parseRequest(raw))
        XCTAssertEqual(request.body, body)
    }

    func testRejectsTooLargeHeaderBlock() {
        let bigValue = String(repeating: "a", count: HTTPCodec.maximumHeaderBytes + 1)
        let raw = "GET /api/health HTTP/1.1\r\nX-Big: \(bigValue)\r\n\r\n"
        guard case .tooLarge? = parseError(raw) else {
            return XCTFail("expected .tooLarge for a header block over the limit")
        }
    }

    func testRejectsTooLargeHeaderBlockWithoutTerminator() {
        let raw = "GET /api/health HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: HTTPCodec.maximumHeaderBytes + 1)
        guard case .tooLarge? = parseError(raw) else {
            return XCTFail("expected .tooLarge for an unterminated header block over the limit")
        }
    }

    func testRejectsDeclaredBodyOverLimit() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: \(HTTPCodec.maximumBodyBytes + 1)\r\n\r\n"
        guard case .tooLarge? = parseError(raw) else {
            return XCTFail("expected .tooLarge for a declared body over the limit")
        }
    }

    func testThrowsIncompleteWhenMoreBytesAreNeeded() {
        let cases = [
            "",
            "GET /api/hea",
            "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1",
            "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n",
            "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc",
        ]
        for raw in cases {
            XCTAssertEqual(parseError(raw), .incomplete, "for \(raw.debugDescription)")
        }
    }

    // MARK: - Completeness

    func testIsCompleteRequestTransitions() {
        XCTAssertFalse(HTTPCodec.isCompleteRequest(Data()))
        XCTAssertFalse(HTTPCodec.isCompleteRequest(data("GET / HTTP/1.1\r\n")))
        XCTAssertFalse(HTTPCodec.isCompleteRequest(data("GET / HTTP/1.1\r\nHost: x\r\n")))
        XCTAssertTrue(HTTPCodec.isCompleteRequest(data("GET / HTTP/1.1\r\nHost: x\r\n\r\n")))
        XCTAssertTrue(HTTPCodec.isCompleteRequest(data("GET / HTTP/1.1\r\n\r\n")))

        let postHead = "POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        XCTAssertFalse(HTTPCodec.isCompleteRequest(data(postHead)))
        XCTAssertFalse(HTTPCodec.isCompleteRequest(data(postHead + "hell")))
        XCTAssertTrue(HTTPCodec.isCompleteRequest(data(postHead + "hello")))
        XCTAssertTrue(HTTPCodec.isCompleteRequest(data(postHead + "hello-extra")))

        // A broken Content-Length is reported complete after the header block so the parser can
        // return the specific 400 instead of the connection loop waiting forever.
        XCTAssertTrue(HTTPCodec.isCompleteRequest(data("POST /x HTTP/1.1\r\nContent-Length: nope\r\n\r\n")))
        XCTAssertTrue(HTTPCodec.isCompleteRequest(
            data("POST /x HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n")
        ))
    }

    func testHasCompleteHeaders() {
        XCTAssertFalse(HTTPCodec.hasCompleteHeaders(data("GET / HTTP/1.1\r\nHost: x")))
        XCTAssertTrue(HTTPCodec.hasCompleteHeaders(data("GET / HTTP/1.1\r\nHost: x\r\n\r\n")))
    }

    /// P1-10: a declared `Content-Length` over the limit is complete from the header block alone, so
    /// the connection answers 413 immediately instead of buffering (or waiting for) the body.
    func testIsCompleteRequestReportsDeclaredBodyOverLimitFromHeaders() {
        let overLimit = "POST /api/items/x/recipe HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Content-Length: \(HTTPCodec.maximumBodyBytes + 1)\r\n\r\n"
        XCTAssertTrue(HTTPCodec.isCompleteRequest(data(overLimit)))
        guard case let .tooLarge(message)? = parseError(overLimit) else {
            return XCTFail("expected .tooLarge for a declared body over the limit")
        }
        XCTAssertTrue(message.contains("exceeds"), message)

        // Exactly at the limit is still an ordinary Content-Length request: not complete without body.
        let atLimit = "POST /x HTTP/1.1\r\nContent-Length: \(HTTPCodec.maximumBodyBytes)\r\n\r\n"
        XCTAssertFalse(HTTPCodec.isCompleteRequest(data(atLimit)))
    }

    func testDocumentedLimitsAreStable() {
        XCTAssertEqual(HTTPCodec.maximumHeaderBytes, 64 * 1024)
        XCTAssertEqual(HTTPCodec.maximumBodyBytes, 4 * 1024 * 1024)
    }

    // MARK: - Serializing

    func testSerializeStatusLineReasonAndFraming() throws {
        let response = HTTPResponse(
            status: 200,
            headers: ["content-type": "text/plain; charset=utf-8"],
            body: Data("hi".utf8)
        )
        let serialized = HTTPCodec.serialize(response)
        let split = try XCTUnwrap(self.split(serialized))
        XCTAssertEqual(split.body, Data("hi".utf8))

        let lines = headerLines(split.head)
        XCTAssertEqual(lines.first, "HTTP/1.1 200 OK")
        XCTAssertEqual(headerValue("Content-Type", in: split.head), "text/plain; charset=utf-8")
        XCTAssertEqual(headerValue("Content-Length", in: split.head), "2")
        XCTAssertEqual(headerValue("Connection", in: split.head), "close")
        XCTAssertNotNil(headerValue("Date", in: split.head))
        XCTAssertTrue(split.head.hasSuffix("Connection: close"), split.head)

        let datePattern = "Date: [A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT"
        XCTAssertNotNil(
            split.head.range(of: datePattern, options: .regularExpression),
            "Date header must be RFC 1123 GMT: \(split.head)"
        )
    }

    func testSerializeDefaultsContentTypeForBody() throws {
        let serialized = HTTPCodec.serialize(HTTPResponse(status: 201, body: Data([0x01, 0x02, 0x03])))
        let split = try XCTUnwrap(self.split(serialized))
        XCTAssertEqual(headerLines(split.head).first, "HTTP/1.1 201 Created")
        XCTAssertEqual(headerValue("Content-Type", in: split.head), "application/octet-stream")
        XCTAssertEqual(headerValue("Content-Length", in: split.head), "3")
        XCTAssertEqual(split.body, Data([0x01, 0x02, 0x03]))
    }

    func testSerializeEmptyBodyHasZeroContentLengthAndNoContentType() throws {
        for status in [204, 200] {
            let serialized = HTTPCodec.serialize(HTTPResponse(status: status))
            let split = try XCTUnwrap(self.split(serialized))
            XCTAssertEqual(headerValue("Content-Length", in: split.head), "0")
            XCTAssertNil(headerValue("Content-Type", in: split.head))
            XCTAssertTrue(split.body.isEmpty)
        }
        let noContent = HTTPCodec.serialize(HTTPResponse(status: 204))
        XCTAssertTrue(
            String(decoding: noContent, as: UTF8.self).hasPrefix("HTTP/1.1 204 No Content\r\n")
        )
    }

    func testSerializeOverridesCallerFramingHeaders() throws {
        let response = HTTPResponse(
            status: 200,
            headers: [
                "content-length": "999",
                "connection": "keep-alive",
                "date": "yesterday",
            ],
            body: Data("hello".utf8)
        )
        let split = try XCTUnwrap(self.split(HTTPCodec.serialize(response)))
        XCTAssertEqual(headerValue("Content-Length", in: split.head), "5")
        XCTAssertEqual(headerValue("Connection", in: split.head), "close")
        XCTAssertNotEqual(headerValue("Date", in: split.head), "yesterday")
        XCTAssertEqual(headerLines(split.head).filter { $0.hasPrefix("Content-Length:") }.count, 1)
        XCTAssertEqual(headerLines(split.head).filter { $0.hasPrefix("Connection:") }.count, 1)
        XCTAssertEqual(headerLines(split.head).filter { $0.hasPrefix("Date:") }.count, 1)
    }

    func testSerializeCanonicalHeaderCasing() throws {
        let response = HTTPResponse(
            status: 401,
            headers: [
                "www-authenticate": "Bearer",
                "cache-control": "no-store",
                "x-photon-version": "0.2.0-m2",
            ]
        )
        let split = try XCTUnwrap(self.split(HTTPCodec.serialize(response)))
        XCTAssertEqual(headerValue("WWW-Authenticate", in: split.head), "Bearer")
        XCTAssertEqual(headerValue("Cache-Control", in: split.head), "no-store")
        XCTAssertEqual(headerValue("X-Photon-Version", in: split.head), "0.2.0-m2")
        XCTAssertFalse(split.head.contains("www-authenticate:"))
    }

    func testSerializeAppendsBodyVerbatimAfterHeaderTerminator() throws {
        // The body itself contains CRLFCRLF; the first occurrence in the serialized response must be
        // the header terminator, and everything after it must be the untouched body.
        let body = Data("abc\r\n\r\n\u{0}\r\ndef".utf8)
        let response = HTTPResponse(status: 200, headers: ["content-type": "application/octet-stream"], body: body)
        let serialized = HTTPCodec.serialize(response)
        let split = try XCTUnwrap(self.split(serialized))
        XCTAssertEqual(split.body, body)
        XCTAssertEqual(headerValue("Content-Length", in: split.head), "\(body.count)")
    }

    func testSerializeDropsHeaderInjectionAttempts() throws {
        let response = HTTPResponse(
            status: 200,
            headers: [
                "x-good": "value",
                "x-bad": "value\r\nX-Injected: evil",
            ]
        )
        let serialized = HTTPCodec.serialize(response)
        let split = try XCTUnwrap(self.split(serialized))
        XCTAssertNil(headerValue("X-Injected", in: split.head))
        XCTAssertEqual(headerValue("X-Good", in: split.head), "value")
        XCTAssertEqual(headerLines(split.head).filter { $0.contains("X-Injected") }.count, 0)
    }

    func testSerializeThenInspectWithRawBytes() throws {
        let response = HTTPResponse.json(Data("{\"ok\":true}".utf8), status: 200)
        let serialized = HTTPCodec.serialize(response)
        // ASCII request/response head: everything before the body must be valid UTF-8 with CRLF.
        let split = try XCTUnwrap(self.split(serialized))
        XCTAssertTrue(split.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertEqual(headerValue("Content-Type", in: split.head), "application/json; charset=utf-8")
        XCTAssertEqual(split.body, Data("{\"ok\":true}".utf8))
    }
}
