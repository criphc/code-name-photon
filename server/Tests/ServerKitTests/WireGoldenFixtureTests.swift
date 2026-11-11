import Foundation
import ContractKit
import XCTest
@testable import ServerKit

/// Cross-end guard for the schema-0 wire bytes (ADR-0004).
///
/// The golden fixtures live in exactly one place — the contract package resource at
/// `contract/Tests/ContractKitTests/Fixtures/schema-0/` — and the client tests read the same files
/// by relative path (`ClientKitTests/TestSupport.wireFixtureData`). `ContractKitTests` already
/// decodes all seven fixtures; this test asks a different question: does the **server** still emit
/// those bytes? It drives the real `APIRouter` (routing + `JSONCoding` encoder) over the decoded
/// golden payload and requires the response body to be JSON-equal to the checked-in
/// `server/health.json` and `server/items.json`. A renamed, dropped or newly-added response field
/// breaks here instead of silently drifting away from the old bytes.
final class WireGoldenFixtureTests: XCTestCase {
    // MARK: - Fixtures

    /// Repository root, derived from this file's path: `<repo>/server/Tests/ServerKitTests/WireGoldenFixtureTests.swift`.
    ///
    /// The fixture is a contract package resource, not a server one: the test reads it by relative
    /// path instead of growing a second copy (or a second `Bundle.module`).
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ServerKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // server
            .deletingLastPathComponent() // repo root
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.repositoryRoot
            .appendingPathComponent("contract/Tests/ContractKitTests/Fixtures/schema-0/server/\(name).json"))
    }

    // MARK: - Fake store

    /// Only `itemCount`/`listItems` are reached: the two golden endpoints under test.
    private final class GoldenStore: ItemStoreProtocol {
        var items: [ItemSummary] = []

        func itemCount() throws -> Int { items.count }
        func listItems() throws -> [ItemSummary] { items }

        func item(id: String) throws -> ItemSummary { throw ItemStoreError.unknownItem(id: id) }
        func prepare(id: String) throws -> PrepareResponse { throw ItemStoreError.unknownItem(id: id) }
        func metadataJSON(id: String) throws -> Data { throw ItemStoreError.unknownItem(id: id) }
        func previewPNG(id: String) throws -> Data { throw ItemStoreError.unknownItem(id: id) }
        func thumbnail(id: String) throws -> Data { throw ItemStoreError.unknownItem(id: id) }
        func recipeJSON(id: String) throws -> Data? { throw ItemStoreError.unknownItem(id: id) }
        func storeRecipe(id: String, body: Data) throws -> RecipePostResponse { throw ItemStoreError.unknownItem(id: id) }
    }

    // MARK: - Test

    func testRouterReproducesSchema0ServerBytes() throws {
        let goldenHealthData = try fixture("health")
        let goldenItemsData = try fixture("items")

        let goldenHealth = try JSONDecoder().decode(HealthResponse.self, from: goldenHealthData)
        let store = GoldenStore()
        store.items = try JSONDecoder().decode(ItemListResponse.self, from: goldenItemsData).items

        // The archived bytes were served with a token configured (`authRequired: true`) and that
        // exact app version; reproduce that state so the comparison is about the wire shape only.
        let token = "schema-0-token"
        let router = APIRouter(store: store, token: token, appVersion: goldenHealth.version)

        let health = router.handle(HTTPRequest(method: .GET, path: "/api/health"))
        XCTAssertEqual(health.status, 200)
        try assertSameJSON(health.body, as: goldenHealthData, "server/health.json")

        let items = router.handle(HTTPRequest(
            method: .GET,
            path: "/api/items",
            headers: ["authorization": "Bearer \(token)"]
        ))
        XCTAssertEqual(items.status, 200)
        try assertSameJSON(items.body, as: goldenItemsData, "server/items.json")
    }

    // MARK: - Helpers

    private func assertSameJSON(_ actual: Data, as expected: Data, _ label: String) throws {
        let actualObject = try JSONSerialization.jsonObject(with: actual) as? [String: Any]
        let expectedObject = try JSONSerialization.jsonObject(with: expected) as? [String: Any]
        let actualDictionary = NSDictionary(dictionary: try XCTUnwrap(actualObject, "\(label): response body is not a JSON object"))
        let expectedDictionary = NSDictionary(dictionary: try XCTUnwrap(expectedObject, "\(label): fixture is not a JSON object"))
        XCTAssertEqual(actualDictionary, expectedDictionary, "\(label): the server no longer produces the schema-0 bytes")
    }
}
