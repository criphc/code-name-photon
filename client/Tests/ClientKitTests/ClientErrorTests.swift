@testable import ClientKit
import ContractKit
import Foundation
import XCTest

/// Pins `ClientError.map(status:body:)` to the M2.1 status/code table and the docs/reference/client.md, state and errors
/// recovery actions. A 409 must never look like success.
final class ClientErrorTests: XCTestCase {
    // MARK: - Helpers

    private func body(_ code: APIErrorCode, _ message: String = "server prose") -> Data {
        (try? JSONEncoder().encode(APIErrorBody(code: code, message: message))) ?? Data()
    }

    private func mapped(_ status: Int, _ code: APIErrorCode, message: String = "server prose") -> ClientError {
        ClientError.map(status: status, body: body(code, message))
    }

    // MARK: - The documented status/code matrix

    func testUnauthorizedWantsTheTokenReentered() {
        let error = mapped(401, .unauthorized)
        XCTAssertEqual(error, .unauthorized)
        XCTAssertEqual(error.code, .unauthorized)
        XCTAssertTrue(error.needsReconnect)
        XCTAssertFalse(error.shouldRefreshList)
        XCTAssertFalse(error.requiresRejudge)
        XCTAssertTrue(error.userMessage.contains("token"), error.userMessage)
        XCTAssertTrue(error.userMessage.contains("re-enter"), error.userMessage)
    }

    func testNotFoundRefreshesTheList() {
        let error = mapped(404, .notFound)
        XCTAssertEqual(error, .notFound)
        XCTAssertEqual(error.code, .notFound)
        XCTAssertFalse(error.needsReconnect)
        XCTAssertTrue(error.shouldRefreshList)
        XCTAssertFalse(error.requiresRejudge)
        XCTAssertTrue(error.userMessage.contains("batch"), error.userMessage)
        XCTAssertTrue(error.userMessage.contains("refresh"), error.userMessage)
    }

    func testMethodNotAllowedIsReportedAndNotRetriedAsAWrite() {
        let error = mapped(405, .methodNotAllowed)
        XCTAssertEqual(error, .methodNotAllowed)
        XCTAssertEqual(error.code, .methodNotAllowed)
        XCTAssertFalse(error.needsReconnect)
        XCTAssertFalse(error.shouldRefreshList)
        XCTAssertFalse(error.requiresRejudge)
        XCTAssertTrue(error.userMessage.contains("405"), error.userMessage)
    }

    func testSourceChangedForcesRejudgeAndIsNeverSuccess() {
        let error = mapped(409, .sourceChanged, message: "re-export detected")
        XCTAssertEqual(error, .sourceChanged)
        XCTAssertEqual(error.code, .sourceChanged)
        XCTAssertFalse(error.needsReconnect)
        XCTAssertFalse(error.shouldRefreshList)
        XCTAssertTrue(error.requiresRejudge)
        // The exact docs/reference/client.md, state and errors wording for the 409 banner.
        XCTAssertEqual(error.userMessage, "the source was re-exported; judge it again")
    }

    func testSourceUnreadableIsReportedWithoutRejudge() {
        let error = mapped(422, .sourceUnreadable, message: "source 'a.tif' is not Display P3")
        XCTAssertEqual(error, .sourceUnreadable)
        XCTAssertEqual(error.code, .sourceUnreadable)
        XCTAssertFalse(error.requiresRejudge)
    }

    func testInvalidRecipeKeepsTheServerMessageAndTheDraft() {
        let error = mapped(
            400,
            .invalidRecipe,
            message: "invalid recipe field 'hdr.start': must be in 0.0...1.0, got 1.5"
        )
        guard case let .invalidRecipe(message) = error else {
            return XCTFail("expected .invalidRecipe, got \(error)")
        }
        XCTAssertTrue(message.contains("hdr.start"), message)
        XCTAssertEqual(error.code, .invalidRecipe)
        XCTAssertFalse(error.requiresRejudge)
        XCTAssertTrue(error.userMessage.contains("draft"), error.userMessage)
        XCTAssertTrue(error.userMessage.contains("hdr.start"), error.userMessage)
    }

    func testBadRequestKeepsTheDraftAndTheMessage() {
        let error = mapped(400, .badRequest, message: "unexpected key 'hdr.foo'")
        guard case let .badRequest(message) = error else {
            return XCTFail("expected .badRequest, got \(error)")
        }
        XCTAssertTrue(message.contains("hdr.foo"), message)
        XCTAssertEqual(error.code, .badRequest)
        XCTAssertTrue(error.userMessage.contains("draft"), error.userMessage)
    }

    func testPrepareFailedIsSpecificAndRetryable() {
        let error = mapped(500, .prepareFailed, message: "decoder failed: unsupported orientation 6")
        guard case let .prepareFailed(message) = error else {
            return XCTFail("expected .prepareFailed, got \(error)")
        }
        XCTAssertTrue(message.contains("orientation"), message)
        XCTAssertEqual(error.code, .prepareFailed)
        XCTAssertTrue(error.userMessage.contains("retry"), error.userMessage)
        XCTAssertTrue(error.userMessage.contains("orientation"), error.userMessage)
    }

    func testInternalErrorIsSpecificAndRetryable() {
        let error = mapped(500, .internalError, message: "unexpected error: disk full")
        guard case let .internalError(message) = error else {
            return XCTFail("expected .internalError, got \(error)")
        }
        XCTAssertTrue(message.contains("disk full"), message)
        XCTAssertEqual(error.code, .internalError)
        XCTAssertTrue(error.userMessage.contains("retry"), error.userMessage)
    }

    // MARK: - Malformed / unknown bodies fall back to the status

    func testMalformedBodyOn409StillMapsToSourceChanged() {
        let error = ClientError.map(status: 409, body: Data("not json at all".utf8))
        XCTAssertEqual(error, .sourceChanged)
        XCTAssertTrue(error.requiresRejudge)
        XCTAssertEqual(
            ClientError.map(status: 409, body: Data()).code,
            .sourceChanged,
            "an empty 409 body must still be a re-export, never a success"
        )
    }

    func testMalformedBodiesFallBackToStatus() {
        let malformed = Data(#"{"error":{"code":42}}"#.utf8)
        XCTAssertEqual(ClientError.map(status: 401, body: malformed), .unauthorized)
        XCTAssertEqual(ClientError.map(status: 404, body: malformed), .notFound)
        XCTAssertEqual(ClientError.map(status: 405, body: malformed), .methodNotAllowed)
        XCTAssertEqual(ClientError.map(status: 422, body: malformed), .sourceUnreadable)
        guard case let .badRequest(message) = ClientError.map(status: 400, body: malformed) else {
            return XCTFail("400 with a malformed body must be .badRequest")
        }
        XCTAssertTrue(message.contains("400"), message)
        guard case let .internalError(message500) = ClientError.map(status: 500, body: malformed) else {
            return XCTFail("500 with a malformed body must be .internalError")
        }
        XCTAssertTrue(message500.contains("500"), message500)
    }

    func testUnexpectedStatusesNeverBecomeSuccess() {
        guard case .badRequest = ClientError.map(status: 418, body: Data()) else {
            return XCTFail("an unknown 4xx must be a client-side .badRequest")
        }
        guard case let .internalError(message) = ClientError.map(status: 503, body: Data()) else {
            return XCTFail("a 5xx must be .internalError")
        }
        XCTAssertTrue(message.contains("503"), message)
        guard case .internalError = ClientError.map(status: 200, body: Data()) else {
            return XCTFail("map() must never return success; even a stray 200 is an error")
        }
    }

    func testCodeWinsOverStatusWhenBothArePresent() {
        // The machine-readable code is the contract (docs/reference/wire.md, M2.1 wire contract, errors), so it decides.
        let error = ClientError.map(status: 400, body: body(.sourceChanged))
        XCTAssertEqual(error, .sourceChanged)
        XCTAssertTrue(error.requiresRejudge)
    }

    // MARK: - Transport-level errors have no server code

    func testTransportErrorsHaveNoCodeAndNoReconnectActions() {
        let cases: [ClientError] = [
            .network(message: "connection refused"),
            .decoding(message: "unexpected JSON"),
            .invalidConfiguration(message: "the host is empty"),
        ]
        XCTAssertNil(cases[0].code)
        XCTAssertNil(cases[1].code)
        XCTAssertEqual(cases[2].code, nil)
        XCTAssertFalse(cases[0].needsReconnect)
        XCTAssertFalse(cases[0].shouldRefreshList)
        XCTAssertFalse(cases[0].requiresRejudge)
        XCTAssertFalse(cases[1].needsReconnect)
        XCTAssertFalse(cases[1].shouldRefreshList)
        XCTAssertFalse(cases[1].requiresRejudge)
        XCTAssertTrue(cases[2].needsReconnect, "an unusable configuration sends the user to settings")
        XCTAssertTrue(cases[0].userMessage.contains("retry"), cases[0].userMessage)
        XCTAssertFalse(cases[1].userMessage.isEmpty)
        XCTAssertFalse(cases[2].userMessage.isEmpty)
    }
}
