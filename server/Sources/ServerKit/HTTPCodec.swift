import Foundation

public enum HTTPCodecError: Error, Equatable {
    /// The buffer does not yet contain a complete request (headers or body still arriving).
    case incomplete
    /// Bytes are present but not a valid HTTP/1.1 request.
    case malformed(String)
    /// Well-formed but not supported by this M2 server (e.g. chunked transfer-encoding).
    case unsupported(String)
    /// Header block or body over the configured limits.
    case tooLarge(String)
}

/// Minimal HTTP/1.1 codec: one request per connection, `Content-Length` bodies only.
///
/// M2 is a single-user LAN server; there is no keep-alive, no chunked bodies, no compression and no
/// HTTP/2. The parser must be strict about the things that matter for safety (header size, body
/// size, CRLF framing) and tolerant about what browsers/Swift clients do in practice
/// (case-insensitive header names, optional query, percent-encoded path, absolute-form targets).
///
/// Error mapping used by `HTTPServer` (and the M3 client):
///   `.malformed`   → 400 Bad Request   `{"error":{"code":"bad_request",...}}`
///   `.tooLarge`    → 413 Payload Too Large
///   `.unsupported` → 501 Not Implemented
///   `.incomplete`  → only thrown while reading; the server answers 400 if it has to give up.
///
/// Framing rules, documented because they are deliberate:
///   - Request line: `METHOD SP request-target SP HTTP/1.1` with exactly one SP each and no empty
///     part. Any other HTTP-version token is `.unsupported` (501); a non-`HTTP/` version token is
///     `.malformed` (400). An unknown method is `.unsupported` (501).
///   - Headers: CRLF-separated, split at the first `:`; names must be RFC 9110 tokens (no
///     whitespace) and are lowercased; values are trimmed of SP/HTAB at both ends. The header block
///     must be terminated by CRLFCRLF; a bare `\n\n` with no CRLFCRLF is LF-only framing and is
///     `.malformed` (400). `isCompleteRequest` reports such a buffer as complete as soon as the
///     terminator is visible, so the connection answers 400 immediately instead of waiting for the
///     inactivity deadline.
///   - Body length: `Content-Length` only. Duplicate identical values are accepted; conflicting
///     values are `.malformed`. Every value of every `Transfer-Encoding` header (and every
///     comma-separated coding in a value) must be `identity`, case-insensitively; any other coding —
///     `chunked`, a mixture such as `identity, chunked`, or a duplicate non-identity value — is
///     `.unsupported` (501). Duplicate `identity` values are accepted because they do not change the
///     framing. Bytes after a complete request (pipelining) are ignored, one request per connection.
///   - Limits: a header block (or an unterminated buffer) over `maximumHeaderBytes` is `.tooLarge`
///     (413). A declared `Content-Length` over `maximumBodyBytes` is reported complete by
///     `isCompleteRequest` as soon as the header block arrives, so `.tooLarge` (413) is sent without
///     buffering the body or waiting for it.
///   - Request target: origin-form (`/path?query`), absolute-form (`http://host/path?query`) and
///     `*` are accepted. Path and query are percent-decoded (`+` means space in the query only,
///     the form convention); duplicate query keys keep the last value.
public enum HTTPCodec {
    public static let maximumHeaderBytes = 64 * 1024
    public static let maximumBodyBytes = 4 * 1024 * 1024

    // MARK: - Completeness

    /// True once `buffer` holds a complete request (headers and a full `Content-Length` body), or
    /// holds bytes that `parseRequest` must reject without any further reading. Used by the connection
    /// loop to decide whether to keep reading. Never throws.
    ///
    /// Besides the normal "headers + full body" case this returns `true` for the error cases the
    /// parser must decide as soon as the header block is complete, so the connection never waits for
    /// bytes that cannot help:
    ///   - a syntactically invalid `Content-Length` (parser → 400);
    ///   - a declared `Content-Length` over `maximumBodyBytes` (parser → 413, without buffering or
    ///     awaiting the oversized body);
    ///   - a non-`identity`/repeated `Transfer-Encoding` (parser → 501);
    ///   - an LF-only header terminator within the header limit (parser → 400).
    public static func isCompleteRequest(_ buffer: Data) -> Bool {
        guard let headerEnd = headerEnd(in: buffer) else {
            // No CRLFCRLF yet. A bare `\n\n` means the headers are LF-only, which can only be
            // `.malformed`: report complete now so the connection answers 400 instead of waiting for
            // inactivity. Only an in-limit terminator counts — past the header limit `parseRequest`
            // keeps its `.tooLarge` (413) answer for an unterminated header block.
            return hasLFOnlyHeaderTerminator(in: buffer)
        }
        let bodyStart = headerEnd + 4
        let declared: Int
        switch scanContentLength(in: buffer, headerEnd: headerEnd) {
        case .absent, .invalid, .conflicting:
            declared = 0
        case let .value(length):
            // Over the limit: the header block alone decides `.tooLarge` (413). Report complete now so
            // the body is never buffered and its arrival is never awaited.
            if length > maximumBodyBytes { return true }
            declared = length
        }
        return buffer.count - bodyStart >= declared
    }

    /// True once the header block (through CRLFCRLF) has arrived. Cheap; used to distinguish "still
    /// reading headers" from "reading the body" without parsing the body.
    public static func hasCompleteHeaders(_ buffer: Data) -> Bool {
        headerEnd(in: buffer) != nil
    }

    // MARK: - Parsing

    /// Parses one complete request. Throws `.incomplete` when more bytes are needed.
    public static func parseRequest(_ buffer: Data) throws -> HTTPRequest {
        guard !buffer.isEmpty else { throw HTTPCodecError.incomplete }
        guard let headerEnd = headerEnd(in: buffer) else {
            // An LF-only header terminator inside the header limit can never be decoded as HTTP/1.1;
            // it is `.malformed` (400), not "wait for more bytes" and not the inactivity timeout.
            // Checked before the size limit so an over-limit buffer that does contain a bare `\n\n`
            // still reports the real framing problem; a buffer with no terminator at all past the
            // limit keeps its `.tooLarge` (413) answer.
            if hasLFOnlyHeaderTerminator(in: buffer) {
                throw HTTPCodecError.malformed(
                    "HTTP headers must be CRLF-terminated; the header block ends with a bare LF "
                        + "(LF-only) instead of CRLFCRLF"
                )
            }
            if buffer.count > maximumHeaderBytes {
                throw HTTPCodecError.tooLarge(
                    "request header block exceeds \(maximumHeaderBytes) bytes before CRLFCRLF"
                )
            }
            throw HTTPCodecError.incomplete
        }
        guard headerEnd <= maximumHeaderBytes else {
            throw HTTPCodecError.tooLarge(
                "request header block of \(headerEnd) bytes exceeds the \(maximumHeaderBytes)-byte limit"
            )
        }

        return try buffer.withUnsafeBytes { raw -> HTTPRequest in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw HTTPCodecError.incomplete
            }
            let byteCount = raw.count
            let lines = headerLineRanges(base: base, headerEnd: headerEnd)
            guard let requestLine = lines.first else {
                throw HTTPCodecError.malformed("empty request")
            }
            let (method, target) = try parseRequestLine(base: base, line: requestLine)
            let (path, query) = try parseTarget(target)

            var headers: [String: String] = [:]
            var contentLengthValues: [String] = []
            var transferEncodingValues: [String] = []
            for line in lines.dropFirst() {
                let (name, value) = try parseHeaderLine(base: base, line: line)
                if name == "content-length" {
                    contentLengthValues.append(value)
                } else if name == "transfer-encoding" {
                    transferEncodingValues.append(value)
                }
                headers[name] = value
            }

            if !transferEncodingValues.isEmpty {
                // Check every value of every `Transfer-Encoding` header, and every coding in a
                // comma-separated list. The old code inspected only the first value, so
                // `Transfer-Encoding: identity` followed by `Transfer-Encoding: chunked` was accepted
                // as a Content-Length body. Duplicate `identity` values are accepted because they do
                // not change the framing (docs/reference/wire.md, M2 server: one request per connection, no chunked).
                for value in transferEncodingValues {
                    for coding in value.split(separator: ",", omittingEmptySubsequences: false) {
                        let trimmed = coding.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.lowercased() == "identity" else {
                            let display = trimmed.isEmpty ? "\"\"" : trimmed
                            throw HTTPCodecError.unsupported(
                                "Transfer-Encoding \(display) is not supported; "
                                    + "only Content-Length bodies are implemented (no chunked encoding)"
                            )
                        }
                    }
                }
            }

            let contentLength = try resolveContentLength(contentLengthValues)
            let bodyStart = headerEnd + 4
            let available = byteCount - bodyStart
            guard available >= contentLength else {
                throw HTTPCodecError.incomplete
            }
            let body: Data
            if contentLength == 0 {
                body = Data()
            } else {
                body = Data(bytes: base + bodyStart, count: contentLength)
            }

            return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
        }
    }

    // MARK: - Serializing

    /// Serializes a response with `Content-Length`, `Connection: close`, a `Date` header and the
    /// canonical reason phrase. Header names are written in their conventional casing.
    ///
    /// Framing headers supplied by the caller are ignored (the serializer owns them): `Content-Length`
    /// is always `body.count`, `Connection` is always `close`, and `Date` is always "now" in RFC 1123
    /// form. `Content-Type: application/octet-stream` is added when a body is present and the caller
    /// set none. The body is appended verbatim after the CRLFCRLF header terminator.
    public static func serialize(_ response: HTTPResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(HTTPStatus.reasonPhrase(for: response.status))\r\n"

        let framingHeaders: Set<String> = ["content-length", "connection", "date"]
        var writtenHeaders: Set<String> = []
        var hasContentType = false

        for name in response.headers.keys.sorted() {
            let lowercasedName = name.lowercased()
            guard !framingHeaders.contains(lowercasedName) else { continue }
            guard !writtenHeaders.contains(lowercasedName) else { continue }
            writtenHeaders.insert(lowercasedName)
            guard let value = response.headers[name] else { continue }
            // Never let a header name/value smuggle a second line into the response. Note that
            // checking `String.contains("\r")` is wrong in Swift: CRLF is a single grapheme cluster,
            // so scan the unicode scalars instead.
            guard !containsNewline(lowercasedName), !containsNewline(value) else { continue }
            if lowercasedName == "content-type" {
                hasContentType = true
            }
            head += "\(canonicalHeaderName(lowercasedName)): \(value)\r\n"
        }

        if !hasContentType && !response.body.isEmpty {
            head += "Content-Type: application/octet-stream\r\n"
        }
        head += "Date: \(httpDate())\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }

    // MARK: - Byte scanning

    /// Index of the first `\r` of the CRLFCRLF header terminator, relative to `buffer`'s storage.
    private static func headerEnd(in buffer: Data) -> Int? {
        guard buffer.count >= 4 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let last = raw.count - 3
            var index = 0
            while index < last {
                if base[index] == 0x0D, base[index + 1] == 0x0A,
                   base[index + 2] == 0x0D, base[index + 3] == 0x0A {
                    return index
                }
                index += 1
            }
            return nil
        }
    }

    /// True when the header-limit window contains a bare `\n\n` (LF-only header terminator). Only
    /// consulted when no CRLFCRLF was found, so this can never misfire on a valid CRLF-framed request
    /// whose body happens to contain `\n\n`: with CRLFCRLF present the caller takes the normal path.
    ///
    /// A pair counts when the header block before the terminator, `index`, is within
    /// `maximumHeaderBytes` — the same limit `headerEnd` is compared against.
    private static func hasLFOnlyHeaderTerminator(in buffer: Data) -> Bool {
        guard buffer.count >= 2 else { return false }
        return buffer.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let lastPairStart = min(raw.count - 2, maximumHeaderBytes)
            var index = 0
            while index <= lastPairStart {
                if base[index] == 0x0A, base[index + 1] == 0x0A { return true }
                index += 1
            }
            return false
        }
    }

    /// Ranges of the lines in the header block `[0, headerEnd)`, with the CRLF omitted.
    private static func headerLineRanges(base: UnsafePointer<UInt8>, headerEnd: Int) -> [Range<Int>] {
        guard headerEnd > 0 else { return [] }
        var ranges: [Range<Int>] = []
        var lineStart = 0
        var index = 0
        while index + 1 < headerEnd {
            if base[index] == 0x0D, base[index + 1] == 0x0A {
                ranges.append(lineStart..<index)
                index += 2
                lineStart = index
            } else {
                index += 1
            }
        }
        if lineStart < headerEnd {
            ranges.append(lineStart..<headerEnd)
        }
        return ranges
    }

    private static func parseRequestLine(
        base: UnsafePointer<UInt8>,
        line: Range<Int>
    ) throws -> (HTTPMethod, String) {
        guard line.count > 0 else { throw HTTPCodecError.malformed("empty request line") }
        var spaces: [Int] = []
        for index in line where base[index] == 0x20 {
            spaces.append(index)
        }
        guard spaces.count == 2 else {
            throw HTTPCodecError.malformed("request line must be 'METHOD SP target SP HTTP/1.1'")
        }
        let firstSpace = spaces[0]
        let secondSpace = spaces[1]
        guard firstSpace > line.lowerBound,
              secondSpace > firstSpace + 1,
              secondSpace < line.upperBound - 1 else {
            throw HTTPCodecError.malformed("request line has an empty method, target or version")
        }

        let methodBytes = UnsafeRawBufferPointer(
            start: base + line.lowerBound,
            count: firstSpace - line.lowerBound
        )
        let methodString = String(decoding: methodBytes, as: UTF8.self)
        guard let method = HTTPMethod(rawWireValue: methodString) else {
            throw HTTPCodecError.unsupported("HTTP method \(methodString) is not implemented")
        }

        let targetBytes = UnsafeRawBufferPointer(
            start: base + firstSpace + 1,
            count: secondSpace - firstSpace - 1
        )
        let target = String(decoding: targetBytes, as: UTF8.self)

        let versionBytes = UnsafeRawBufferPointer(
            start: base + secondSpace + 1,
            count: line.upperBound - secondSpace - 1
        )
        let version = String(decoding: versionBytes, as: UTF8.self)
        if version != "HTTP/1.1" {
            if version.hasPrefix("HTTP/") {
                throw HTTPCodecError.unsupported("HTTP version \(version) is not supported; only HTTP/1.1")
            }
            throw HTTPCodecError.malformed("malformed HTTP version \(version)")
        }
        return (method, target)
    }

    private static func parseTarget(_ target: String) throws -> (path: String, query: [String: String]) {
        var value = target
        if let fragment = value.firstIndex(of: "#") {
            value = String(value[value.startIndex..<fragment])
        }

        // absolute-form: scheme "://" authority [path] ["?" query]
        if let schemeRange = value.range(of: "://"), isScheme(value[value.startIndex..<schemeRange.lowerBound]) {
            let afterScheme = value[schemeRange.upperBound...]
            if let delimiter = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) {
                value = String(afterScheme[delimiter...])
            } else {
                value = "/"
            }
        }
        if value.isEmpty { value = "/" }

        let pathPart: String
        let queryPart: String?
        if let question = value.firstIndex(of: "?") {
            pathPart = String(value[value.startIndex..<question])
            queryPart = String(value[value.index(after: question)...])
        } else {
            pathPart = value
            queryPart = nil
        }

        // `OPTIONS *` is a valid request-target; keep it verbatim.
        if pathPart == "*" { return ("*", [:]) }

        guard let path = pathPart.removingPercentEncoding else {
            throw HTTPCodecError.malformed("invalid percent-encoding in request target path")
        }

        var query: [String: String] = [:]
        if let queryPart, !queryPart.isEmpty {
            for pair in queryPart.split(separator: "&", omittingEmptySubsequences: true) {
                let pairString = String(pair)
                let key: String
                let rawValue: String
                if let equals = pairString.firstIndex(of: "=") {
                    key = String(pairString[pairString.startIndex..<equals])
                    rawValue = String(pairString[pairString.index(after: equals)...])
                } else {
                    key = pairString
                    rawValue = ""
                }
                guard let decodedKey = formDecoded(key), let decodedValue = formDecoded(rawValue) else {
                    throw HTTPCodecError.malformed("invalid percent-encoding in query string")
                }
                guard !decodedKey.isEmpty else { continue }
                query[decodedKey] = decodedValue
            }
        }
        return (path.isEmpty ? "/" : path, query)
    }

    private static func isScheme(_ candidate: Substring) -> Bool {
        guard !candidate.isEmpty else { return false }
        for character in candidate {
            guard character.isASCII,
                  character.isLetter || character.isNumber
                    || character == "+" || character == "-" || character == "." else {
                return false
            }
        }
        return true
    }

    /// Percent-decodes a query component; `+` is a space (the form convention).
    private static func formDecoded(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func parseHeaderLine(
        base: UnsafePointer<UInt8>,
        line: Range<Int>
    ) throws -> (name: String, value: String) {
        guard line.count > 0 else {
            throw HTTPCodecError.malformed("unexpected empty header line")
        }
        var colon: Int?
        for index in line where base[index] == 0x3A {
            colon = index
            break
        }
        guard let colon else {
            throw HTTPCodecError.malformed("header line without ':'")
        }
        guard colon > line.lowerBound else {
            throw HTTPCodecError.malformed("header line has an empty name")
        }
        for index in line.lowerBound..<colon where !isTokenByte(base[index]) {
            throw HTTPCodecError.malformed("header name contains an invalid byte")
        }

        var valueStart = colon + 1
        var valueEnd = line.upperBound
        while valueStart < valueEnd, base[valueStart] == 0x20 || base[valueStart] == 0x09 {
            valueStart += 1
        }
        while valueEnd > valueStart, base[valueEnd - 1] == 0x20 || base[valueEnd - 1] == 0x09 {
            valueEnd -= 1
        }

        let name = String(
            decoding: UnsafeRawBufferPointer(start: base + line.lowerBound, count: colon - line.lowerBound),
            as: UTF8.self
        ).lowercased()
        let value = String(
            decoding: UnsafeRawBufferPointer(start: base + valueStart, count: valueEnd - valueStart),
            as: UTF8.self
        )
        return (name, value)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
             0x30...0x39, 0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }

    // MARK: - Content-Length

    private enum ContentLengthScan: Equatable {
        case absent
        case value(Int)
        case invalid
        case conflicting
    }

    private enum ContentLengthLine {
        case notContentLength
        case valid(Int)
        case invalid
    }

    /// Cheap `Content-Length` scan for the completeness check; walks header lines without copying.
    private static func scanContentLength(in buffer: Data, headerEnd: Int) -> ContentLengthScan {
        buffer.withUnsafeBytes { raw -> ContentLengthScan in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return .absent }
            var first: Int?
            var sawInvalid = false
            var sawConflict = false
            var lineStart = 0
            var index = 0
            while index < headerEnd {
                if base[index] == 0x0D, index + 1 < headerEnd, base[index + 1] == 0x0A {
                    switch parseContentLengthLine(base: base, start: lineStart, end: index) {
                    case .notContentLength:
                        break
                    case .invalid:
                        sawInvalid = true
                    case let .valid(length):
                        if let first, first != length {
                            sawConflict = true
                        } else if first == nil {
                            first = length
                        }
                    }
                    index += 2
                    lineStart = index
                } else {
                    index += 1
                }
            }
            if lineStart < headerEnd {
                switch parseContentLengthLine(base: base, start: lineStart, end: headerEnd) {
                case .notContentLength:
                    break
                case .invalid:
                    sawInvalid = true
                case let .valid(length):
                    if let first, first != length {
                        sawConflict = true
                    } else if first == nil {
                        first = length
                    }
                }
            }
            if sawConflict { return .conflicting }
            if sawInvalid { return .invalid }
            if let first { return .value(first) }
            return .absent
        }
    }

    private static func parseContentLengthLine(
        base: UnsafePointer<UInt8>,
        start: Int,
        end: Int
    ) -> ContentLengthLine {
        var colon: Int?
        for index in start..<end where base[index] == 0x3A {
            colon = index
            break
        }
        guard let colon, colon > start else { return .notContentLength }

        let expected: [UInt8] = Array("content-length".utf8)
        guard colon - start == expected.count else { return .notContentLength }
        for offset in 0..<expected.count {
            var byte = base[start + offset]
            if byte >= 0x41, byte <= 0x5A { byte += 0x20 }
            guard byte == expected[offset] else { return .notContentLength }
        }

        var valueStart = colon + 1
        var valueEnd = end
        while valueStart < valueEnd, base[valueStart] == 0x20 || base[valueStart] == 0x09 {
            valueStart += 1
        }
        while valueEnd > valueStart, base[valueEnd - 1] == 0x20 || base[valueEnd - 1] == 0x09 {
            valueEnd -= 1
        }
        guard valueStart < valueEnd else { return .invalid }

        var value = 0
        for index in valueStart..<valueEnd {
            let byte = base[index]
            guard byte >= 0x30, byte <= 0x39 else { return .invalid }
            let digit = Int(byte - 0x30)
            // Saturate instead of wrapping: the caller turns an oversized value into 413.
            if value > (Int.max - digit) / 10 { return .valid(Int.max) }
            value = value * 10 + digit
        }
        return .valid(value)
    }

    /// Full parse of the collected `Content-Length` values (same values may repeat).
    private static func resolveContentLength(_ values: [String]) throws -> Int {
        guard !values.isEmpty else { return 0 }
        var lengths: [Int] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !trimmed.isEmpty else {
                throw HTTPCodecError.malformed("empty Content-Length header")
            }
            guard trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
                throw HTTPCodecError.malformed("invalid Content-Length value '\(trimmed)'")
            }
            guard let length = Int(trimmed) else {
                throw HTTPCodecError.tooLarge("Content-Length '\(trimmed)' is too large to represent")
            }
            lengths.append(length)
        }
        if let first = lengths.first, lengths.contains(where: { $0 != first }) {
            throw HTTPCodecError.malformed("multiple conflicting Content-Length headers")
        }
        let length = lengths[0]
        guard length <= maximumBodyBytes else {
            throw HTTPCodecError.tooLarge(
                "request body of \(length) bytes exceeds the \(maximumBodyBytes)-byte limit"
            )
        }
        return length
    }

    // MARK: - Response formatting

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
    private static let httpDateLock = NSLock()

    private static func httpDate(_ date: Date = Date()) -> String {
        httpDateLock.lock()
        defer { httpDateLock.unlock() }
        return httpDateFormatter.string(from: date)
    }

    private static func containsNewline(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
    }

    /// Conventional HTTP casing for header names. Unknown names get Title-Case per dash segment,
    /// which is what clients expect even though HTTP itself is case-insensitive.
    private static func canonicalHeaderName(_ lowercased: String) -> String {
        if let known = canonicalHeaderNames[lowercased] { return known }
        return lowercased
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { segment -> String in
                guard let first = segment.first else { return String(segment) }
                return first.uppercased() + segment.dropFirst()
            }
            .joined(separator: "-")
    }

    private static let canonicalHeaderNames: [String: String] = [
        "content-type": "Content-Type",
        "content-length": "Content-Length",
        "content-disposition": "Content-Disposition",
        "cache-control": "Cache-Control",
        "connection": "Connection",
        "date": "Date",
        "allow": "Allow",
        "location": "Location",
        "etag": "ETag",
        "last-modified": "Last-Modified",
        "accept-ranges": "Accept-Ranges",
        "vary": "Vary",
        "server": "Server",
        "www-authenticate": "WWW-Authenticate",
    ]
}
