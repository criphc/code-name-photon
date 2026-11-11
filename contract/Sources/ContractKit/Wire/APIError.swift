import Foundation

/// Stable machine-readable error codes. The client switches on `code`, never on prose.
public enum APIErrorCode: String, Codable, CaseIterable, Sendable, Equatable {
    case unauthorized
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case badRequest = "bad_request"
    case invalidRecipe = "invalid_recipe"
    case sourceChanged = "source_changed"
    case sourceUnreadable = "source_unreadable"
    case prepareFailed = "prepare_failed"
    case internalError = "internal_error"
}

/// The JSON error body: `{"error":{"code":"…","message":"…"}}`.
public struct APIErrorBody: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public let code: APIErrorCode
        public let message: String

        public init(code: APIErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    public let error: Detail

    public init(code: APIErrorCode, message: String) {
        self.error = Detail(code: code, message: message)
    }

    /// The machine-readable code, for call sites that only care about the branch.
    public var code: APIErrorCode { error.code }
}
