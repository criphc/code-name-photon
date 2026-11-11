import Foundation

/// HTTP method, uppercased as it appears on the wire.
public enum HTTPMethod: String, Sendable {
    case GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS

    public init?(rawWireValue value: String) {
        self.init(rawValue: value.uppercased())
    }
}

/// One parsed HTTP/1.1 request.
///
/// `path` is percent-decoded and has no query string; `query` holds the decoded pairs (last value
/// wins for duplicates — the M2 API has no repeated keys). Header names are lowercased so lookups
/// are case-insensitive, as HTTP requires.
public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [String: String]
    /// Lowercased header names → trimmed values.
    public var headers: [String: String]
    public var body: Data

    public init(
        method: HTTPMethod,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// `Authorization: Bearer <token>` value, if present.
    public var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}

/// One HTTP/1.1 response. `Content-Length` and `Connection` are added by the serializer; callers
/// only set content type / cache headers.
public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names are stored lowercased; the serializer writes canonical casing.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json; charset=utf-8"], body: data)
    }

    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["content-type": "text/plain; charset=utf-8"],
            body: Data(string.utf8)
        )
    }

    public static func bytes(_ data: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": contentType], body: data)
    }
}

public enum HTTPStatus {
    public static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}
