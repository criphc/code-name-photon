import Foundation

/// Resolves the bearer token `appctl serve` runs with (contract: docs/reference/wire.md, M2 server).
///
/// The server must always have a non-empty token. An empty one used to reach
/// `APIRouter.isAuthorized`, whose empty-token branch treats the API as open; the CLI now resolves
/// the value before `ServerConfig` is built:
///
/// - an explicit `--token` wins; an empty or whitespace-containing value is an error (a typo must
///   not silently fall back to the environment);
/// - an empty `$PHOTON_TOKEN` is treated as unset (the common `export PHOTON_TOKEN=` case) and a
///   token is generated;
/// - a non-empty but invalid `$PHOTON_TOKEN` is an error;
/// - when neither source yields a token, a random one is generated and printed by the caller.
public enum ServeToken {
    /// Resolves the token from the CLI flag and the environment variable.
    ///
    /// A valid token is non-empty and contains no whitespace (a bearer token cannot carry one
    /// through `Authorization: Bearer <token>`); values are used verbatim, never trimmed, so a
    /// stray space is an error instead of a silently different secret.
    public static func resolve(explicit: String?, environment: String?) throws -> String {
        if let explicit {
            guard isValid(explicit) else { throw ServeTokenError.invalidExplicitToken }
            return explicit
        }
        if let environment, !environment.isEmpty {
            guard isValid(environment) else { throw ServeTokenError.invalidEnvironmentToken }
            return environment
        }
        return generate()
    }

    /// `true` iff `token` is exactly what a client can present: non-empty, with no surrounding or
    /// embedded whitespace. `ServerConfig` uses this as its invariant; `resolve` returns a value
    /// that passes it.
    public static func isValid(_ token: String) -> Bool {
        !token.isEmpty && !token.contains(where: { $0.isWhitespace })
    }

    /// A random 32-character hex token (the printed fallback).
    static func generate() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Why a serve token could not be resolved. The CLI turns each case into a usage error.
public enum ServeTokenError: Swift.Error, Equatable {
    /// `--token` was given but is empty or contains whitespace.
    case invalidExplicitToken
    /// `$PHOTON_TOKEN` is set (non-empty) but is not a valid token.
    case invalidEnvironmentToken
}
