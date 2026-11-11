import XCTest
@testable import ServerKit

/// `ServeToken.resolve` is the CLI's guard against an empty or malformed bearer token; `ServerConfig`
/// repeats the invariant so no other caller can build an open server by accident.
final class ServeTokenTests: XCTestCase {
    // MARK: - --token

    func testExplicitTokenAcceptsAValidValueAndRejectsEveryInvalidForm() throws {
        XCTAssertEqual(try ServeToken.resolve(explicit: "s3cret", environment: nil), "s3cret")

        // Surrounding whitespace, empty (must not fall back to the environment), whitespace-only,
        // embedded whitespace: every one is an explicit-token error.
        let rejected: [(input: String, environment: String?)] = [
            ("  s3cret  ", nil),
            ("", "env-token"),
            ("   ", nil),
            ("a b", nil),
        ]
        for variant in rejected {
            let label = "explicit \(variant.input.debugDescription), "
                + "environment \(variant.environment.map { $0.debugDescription } ?? "nil")"
            try XCTContext.runActivity(named: label) { _ in
                XCTAssertThrowsError(
                    try ServeToken.resolve(explicit: variant.input, environment: variant.environment)
                ) { error in
                    XCTAssertEqual(error as? ServeTokenError, .invalidExplicitToken)
                }
            }
        }
    }

    // MARK: - $PHOTON_TOKEN

    func testEnvironmentTokenAcceptsAValidValueAndRejectsEveryInvalidForm() throws {
        XCTAssertEqual(try ServeToken.resolve(explicit: nil, environment: "env-token"), "env-token")

        // Surrounding whitespace, whitespace-only, embedded whitespace.
        let rejected = ["  env-token  ", "   ", "a b"]
        for value in rejected {
            try XCTContext.runActivity(named: "environment \(value.debugDescription)") { _ in
                XCTAssertThrowsError(try ServeToken.resolve(explicit: nil, environment: value)) { error in
                    XCTAssertEqual(error as? ServeTokenError, .invalidEnvironmentToken)
                }
            }
        }
    }

    /// The pair of "unset" forms: an empty `$PHOTON_TOKEN` (the `export PHOTON_TOKEN=` case) and no
    /// input at all both generate a printable token instead of an error.
    func testEmptyOrMissingInputGeneratesAToken() {
        let environments: [String?] = [nil, ""]
        for environment in environments {
            let label = environment.map { "environment \($0.debugDescription)" } ?? "no environment"
            XCTContext.runActivity(named: label) { _ in
                do {
                    let token = try ServeToken.resolve(explicit: nil, environment: environment)
                    XCTAssertTrue(ServeToken.isValid(token), "generated token \(token) is not valid")
                    XCTAssertEqual(token.count, 32, "a generated token is a UUID without hyphens")
                    XCTAssertFalse(token.contains("-"))
                } catch {
                    XCTFail("expected a generated token, got \(error)")
                }
            }
        }
    }

    // MARK: - ServerConfig invariant

    func testServerConfigRejectsAnInvalidToken() {
        let url = URL(fileURLWithPath: "/tmp/photon-serve-token-test")
        XCTAssertThrowsError(
            try ServerConfig(batchDirectory: url, workDirectory: url, token: "", encoderVersion: "v")
        ) { error in
            XCTAssertEqual(error as? ServerConfigError, .invalidToken)
        }
        XCTAssertThrowsError(
            try ServerConfig(batchDirectory: url, workDirectory: url, token: "  ", encoderVersion: "v")
        ) { error in
            XCTAssertEqual(error as? ServerConfigError, .invalidToken)
        }
        XCTAssertNoThrow(
            try ServerConfig(batchDirectory: url, workDirectory: url, token: "t", encoderVersion: "v")
        )
    }
}
