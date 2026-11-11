import Foundation
import EngineKit
import ContractKit

/// The M2 HTTP API: a pure request → response mapping over `ItemStoreProtocol`.
///
/// Contract (docs/reference/wire.md, M2.1 wire contract, and the response types in
/// `contract/Sources/ContractKit/Wire`):
///   GET  /api/health                    (no auth)  server + batch summary
///   GET  /api/items                     list the batch
///   GET  /api/items/{id}                one item
///   GET  /api/items/{id}/status         item state (same shape as one item)
///   POST /api/items/{id}/prepare        idempotent render of the documented default recipe
///   GET  /api/items/{id}/preview        the SDR base as 16-bit Display P3 PNG bytes (prepares on a cold cache)
///   GET  /api/items/{id}/thumbnail      the filmstrip's 512-high Display P3 HEIC (never prepares)
///   GET  /api/items/{id}/meta           `PreviewMetadata` JSON (prepares on a cold cache)
///   GET  /api/items/{id}/recipe         stored recipe (404 when none)
///   POST /api/items/{id}/recipe         validate + store a recipe; returns it with its render key
///
/// Every /api route except /api/health requires `Authorization: Bearer <token>` (or the
/// `X-Photon-Token` header); item ids are opaque to the router and never become file paths.
///
/// Health is the M3 reachability probe: it needs no token, reports whether a token is required
/// (`authRequired == !token.isEmpty`, review P1-8) and must answer even while a cold `prepare`
/// holds the store's main lock — `ItemStore.itemCount()` has its own cache/lock. A failure to read
/// the batch is **not** swallowed: it goes through the normal `ItemStoreError` → 500 mapping.
public struct APIRouter {
    public let store: ItemStoreProtocol
    public let token: String
    public let appVersion: String

    public init(store: ItemStoreProtocol, token: String, appVersion: String) {
        self.store = store
        self.token = token
        self.appVersion = appVersion
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        do {
            return try route(request)
        } catch let error as ItemStoreError {
            return Self.response(for: error)
        } catch {
            return Self.apiError(.internalError, "unexpected error: \(error)")
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) throws -> HTTPResponse {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // The only unauthenticated route: useful as a reachability probe from the iPad.
        if segments == ["api", "health"] {
            guard request.method == .GET else {
                return Self.methodNotAllowed(allowed: [.GET], path: request.path)
            }
            // Do not `try?` this: an unreadable batch is a real 500, not `itemCount: 0`. The count
            // itself is an atomic cache and does not take the store's main lock (review P1-8).
            let count = try store.itemCount()
            return try Self.json(
                HealthResponse(version: appVersion, itemCount: count, authRequired: !token.isEmpty)
            )
        }

        guard isAuthorized(request) else {
            return Self.apiError(.unauthorized, "missing or invalid bearer token")
        }

        guard segments.first == "api" else {
            return Self.apiError(.notFound, "no such route: \(request.method.rawValue) \(request.path)")
        }
        let route = Array(segments.dropFirst())

        if route == ["items"] {
            guard request.method == .GET else {
                return Self.methodNotAllowed(allowed: [.GET], path: request.path)
            }
            return try Self.json(ItemListResponse(items: try store.listItems()))
        }

        guard route.count >= 2, route[0] == "items" else {
            return Self.apiError(.notFound, "no such route: \(request.method.rawValue) \(request.path)")
        }
        let id = route[1]

        if route.count == 2 {
            guard request.method == .GET else {
                return Self.methodNotAllowed(allowed: [.GET], path: request.path)
            }
            return try Self.json(try store.item(id: id))
        }

        guard route.count == 3 else {
            return Self.apiError(.notFound, "no such route: \(request.method.rawValue) \(request.path)")
        }

        switch route[2] {
        case "status":
            guard request.method == .GET else {
                return Self.methodNotAllowed(allowed: [.GET], path: request.path)
            }
            return try Self.json(try store.item(id: id))

        case "prepare":
            guard request.method == .POST else {
                return Self.methodNotAllowed(allowed: [.POST], path: request.path)
            }
            return try Self.json(try store.prepare(id: id))

        case "preview":
            guard request.method == .GET else {
                return Self.methodNotAllowed(allowed: [.GET], path: request.path)
            }
            // A cold cache renders the base now; warm hits are cheap. M3 shows a spinner for the first.
            _ = try store.prepare(id: id)
            return HTTPResponse.bytes(try store.previewPNG(id: id), contentType: "image/png")

        case "thumbnail":
            guard request.method == .GET else {
                return Self.methodNotAllowed(allowed: [.GET], path: request.path)
            }
            // A thumbnail is not a preview: this route must never call `store.prepare`, or browsing
            // would be back to rendering the 2560 px base (ADR-0013).
            return HTTPResponse.bytes(try store.thumbnail(id: id), contentType: "image/heic")

        case "meta":
            guard request.method == .GET else {
                return Self.methodNotAllowed(allowed: [.GET], path: request.path)
            }
            _ = try store.prepare(id: id)
            return .json(try store.metadataJSON(id: id))

        case "recipe":
            switch request.method {
            case .GET:
                guard let data = try store.recipeJSON(id: id) else {
                    return Self.apiError(.notFound, "no recipe stored for item \(id)")
                }
                return .json(data)
            case .POST:
                return try Self.json(try store.storeRecipe(id: id, body: request.body))
            default:
                return Self.methodNotAllowed(allowed: [.GET, .POST], path: request.path)
            }

        default:
            return Self.apiError(.notFound, "no such route: \(request.method.rawValue) \(request.path)")
        }
    }

    // MARK: - Auth

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        // Direct-construction behaviour only: `appctl serve` resolves a non-empty token through
        // `ServeToken`, and `ServerConfig` rejects an invalid one, so the open branch is not
        // reachable from the CLI.
        guard !token.isEmpty else { return true }
        let presented = request.bearerToken ?? request.header("x-photon-token")
        guard let presented else { return false }
        return Self.constantTimeEquals(presented, token)
    }

    /// Length-independent comparison is not needed on a trusted LAN, but a timing leak is free to
    /// avoid and this is the only secret the server has.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }

    // MARK: - Responses

    private static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        var response = HTTPResponse.json(try JSONCoding.encode(value), status: status)
        response.headers["cache-control"] = "no-store"
        return response
    }

    private static func apiError(_ code: APIErrorCode, _ message: String) -> HTTPResponse {
        let status: Int
        switch code {
        case .unauthorized: status = 401
        case .notFound: status = 404
        case .methodNotAllowed: status = 405
        case .badRequest, .invalidRecipe: status = 400
        case .sourceChanged: status = 409
        case .sourceUnreadable: status = 422
        case .prepareFailed, .internalError: status = 500
        }
        let body = (try? JSONCoding.encode(APIErrorBody(code: code, message: message))) ?? Data()
        var response = HTTPResponse.json(body, status: status)
        response.headers["cache-control"] = "no-store"
        if code == .unauthorized {
            response.headers["www-authenticate"] = "Bearer"
        }
        return response
    }

    private static func response(for error: ItemStoreError) -> HTTPResponse {
        switch error {
        case let .unknownItem(id):
            return apiError(.notFound, "unknown item \(id)")
        case let .invalidRecipe(message):
            return apiError(.invalidRecipe, message)
        case let .sourceChanged(expected, actual):
            return apiError(.sourceChanged, "source changed: expected sha256 \(expected), found \(actual); re-export detected")
        case let .sourceUnreadable(message):
            return apiError(.sourceUnreadable, message)
        case let .prepareFailed(message):
            return apiError(.prepareFailed, message)
        case let .io(message):
            return apiError(.internalError, message)
        }
    }

    private static func methodNotAllowed(allowed: [HTTPMethod], path: String) -> HTTPResponse {
        var response = apiError(.methodNotAllowed, "method not allowed for \(path)")
        response.headers["allow"] = allowed.map(\.rawValue).joined(separator: ", ")
        return response
    }
}
