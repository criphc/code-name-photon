import Foundation
import ContractKit

/// Everything that can go wrong between the iPad and the Mac, in the shape the judging UI needs.
///
/// One type, three audiences:
/// - `code` is the machine-readable M2.1 code (docs/reference/wire.md, M2.1 wire contract, errors), for code that branches;
/// - `userMessage` is the docs/reference/client.md, state and errors wording shown to the user;
/// - the `needsReconnect` / `shouldRefreshList` / `requiresRejudge` booleans are the three
///   recovery actions the docs/reference/client.md, state and errors table assigns to 401 / 404 / 409. A 409 is **never**
///   treated as success: `map(status:body:)` always returns a `ClientError` for it.
public enum ClientError: Error, Equatable, Sendable, LocalizedError {
    /// 401 `unauthorized`: the token was missing or wrong.
    case unauthorized
    /// 404 `not_found`: the item (or route) is gone; refresh the list.
    case notFound
    /// 409 `source_changed`: the source was re-exported; judge it again (never a silent success).
    case sourceChanged
    /// 422 `source_unreadable`: not a Display P3 source (or otherwise unreadable); re-export.
    case sourceUnreadable
    /// 400 `invalid_recipe`: the Mac rejected the recipe fields; the draft is kept.
    case invalidRecipe(message: String)
    /// 400 `bad_request` (also the protocol-layer code): malformed request; the draft is kept.
    case badRequest(message: String)
    /// 500 `prepare_failed`: the Mac could not render the base; retry.
    case prepareFailed(message: String)
    /// 500 `internal_error`: unexpected server failure; retry.
    case internalError(message: String)
    /// 405 `method_not_allowed`: the Mac does not serve this route with this method.
    case methodNotAllowed
    /// The Mac could not be reached, or the connection dropped.
    case network(message: String)
    /// The Mac answered, but the payload is not what this build expects.
    case decoding(message: String)
    /// The host/port/token cannot form a usable request (checked before any network I/O).
    case invalidConfiguration(message: String)

    // MARK: - Machine-readable code

    /// The M2.1 error code this failure corresponds to, when it has one.
    ///
    /// Transport-level (`.network`, `.decoding`) and configuration failures have no server code.
    public var code: APIErrorCode? {
        switch self {
        case .unauthorized: return .unauthorized
        case .notFound: return .notFound
        case .sourceChanged: return .sourceChanged
        case .sourceUnreadable: return .sourceUnreadable
        case .invalidRecipe: return .invalidRecipe
        case .badRequest: return .badRequest
        case .prepareFailed: return .prepareFailed
        case .internalError: return .internalError
        case .methodNotAllowed: return .methodNotAllowed
        case .network, .decoding, .invalidConfiguration: return nil
        }
    }

    // MARK: - User-facing text (docs/reference/client.md, state and errors)

    /// The sentence the judging UI shows. Specific, actionable, and never a generic "error".
    public var userMessage: String {
        switch self {
        case .unauthorized:
            return "the token was not accepted — re-enter it in connection settings"
        case .notFound:
            return "that item is no longer in the batch — refresh the list"
        case .sourceChanged:
            return "the source was re-exported; judge it again"
        case .sourceUnreadable:
            return "not a Display P3 source; export P3 from Capture One"
        case let .invalidRecipe(message):
            return "the Mac rejected the recipe: \(message) — the draft was kept; fix the field and try again"
        case let .badRequest(message):
            return "the Mac rejected the request: \(message) — the draft was kept"
        case let .prepareFailed(message):
            return "the Mac could not prepare this item: \(message) — retry"
        case let .internalError(message):
            return "the Mac hit an internal error: \(message) — retry"
        case .methodNotAllowed:
            return "this request is not supported by the Mac's API (405); check the server build"
        case let .network(message):
            return "cannot reach the Mac: \(message) — check host, port and Wi-Fi, then retry"
        case let .decoding(message):
            return "the Mac returned a response this build cannot read: \(message)"
        case let .invalidConfiguration(message):
            return "invalid connection settings: \(message)"
        }
    }

    // MARK: - Recovery actions (docs/reference/client.md, state and errors)

    /// 401 → back to connection settings and re-enter the token. Also true for a locally invalid
    /// configuration, because the settings are just as unusable.
    public var needsReconnect: Bool {
        switch self {
        case .unauthorized, .invalidConfiguration: return true
        default: return false
        }
    }

    /// 404 → refresh the batch list (the item left the batch).
    public var shouldRefreshList: Bool {
        if case .notFound = self { return true }
        return false
    }

    /// 409 → re-prepare and re-judge; the recipe written for the old source must not be accepted.
    public var requiresRejudge: Bool {
        if case .sourceChanged = self { return true }
        return false
    }

    public var errorDescription: String? { userMessage }

    // MARK: - HTTP mapping

    /// Maps a non-2xx HTTP response to the client error the UI acts on.
    ///
    /// The JSON body's `code` wins (it is the machine-readable contract), with the status used as
    /// a fallback when the body is absent/malformed or carries a code this build does not know.
    /// Status 409 always maps to `.sourceChanged` — never to a success path.
    public static func map(status: Int, body: Data) -> ClientError {
        if let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: body) {
            return map(code: decoded.error.code, message: decoded.error.message)
        }
        switch status {
        case 400:
            return .badRequest(message: "the request was malformed (HTTP 400)")
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 405:
            return .methodNotAllowed
        case 408:
            return .network(message: "the request timed out (HTTP 408)")
        case 409:
            return .sourceChanged
        case 413:
            return .badRequest(message: "the request body was too large (HTTP 413)")
        case 422:
            return .sourceUnreadable
        case 429:
            return .network(message: "the Mac is busy (HTTP 429)")
        case 500...599:
            return .internalError(message: "the Mac reported an internal error (HTTP \(status))")
        case 400...499:
            return .badRequest(message: "the Mac rejected the request (HTTP \(status))")
        default:
            return .internalError(message: "unexpected HTTP status \(status)")
        }
    }

    /// The mapping for a decoded M2.1 error body. 400 `invalid_recipe`/`bad_request` keep the
    /// server's field-level message so the UI can show the actual problem.
    static func map(code: APIErrorCode, message: String) -> ClientError {
        switch code {
        case .unauthorized: return .unauthorized
        case .notFound: return .notFound
        case .methodNotAllowed: return .methodNotAllowed
        case .badRequest: return .badRequest(message: message)
        case .invalidRecipe: return .invalidRecipe(message: message)
        case .sourceChanged: return .sourceChanged
        case .sourceUnreadable: return .sourceUnreadable
        case .prepareFailed: return .prepareFailed(message: message)
        case .internalError: return .internalError(message: message)
        }
    }
}
