import Foundation
import EngineKit
import ContractKit
import XCTest
@testable import ServerKit

/// Router-level tests: auth, status-code mapping, JSON shapes and the "preview/meta prepare on a
/// cold cache" behaviour — all without files, network or the encoder (the fake store stands in).
final class APIRouterTests: XCTestCase {
    // MARK: - Fake store

    private final class FakeStore: ItemStoreProtocol {
        var items: [ItemSummary] = []
        var count = 0
        var preparedItem: ItemSummary?
        var preparedMeta: PreviewMetadata?
        var preparedCached = false
        var previewBytes = Data([0x89, 0x50, 0x4E, 0x47])
        /// `ftypheic` magic: the router must pass the store's bytes through untouched.
        var thumbnailBytes = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        var metaBytes = Data("{}".utf8)
        var recipes: [String: Data] = [:]
        var prepareCalls = 0
        var error: ItemStoreError?
        /// Failure the health probe should surface (P1-8: `itemCount()` errors are not swallowed).
        var countError: ItemStoreError?

        func itemCount() throws -> Int {
            if let countError { throw countError }
            return count
        }
        func listItems() throws -> [ItemSummary] { items }
        func item(id: String) throws -> ItemSummary {
            if let error { throw error }
            guard let found = items.first(where: { $0.id == id }) else { throw ItemStoreError.unknownItem(id: id) }
            return found
        }
        func prepare(id: String) throws -> PrepareResponse {
            prepareCalls += 1
            if let error { throw error }
            guard let preparedItem, let preparedMeta else { throw ItemStoreError.unknownItem(id: id) }
            return PrepareResponse(item: preparedItem, meta: preparedMeta, cached: preparedCached)
        }
        func metadataJSON(id: String) throws -> Data { metaBytes }
        func previewPNG(id: String) throws -> Data { previewBytes }
        func thumbnail(id: String) throws -> Data {
            if let error { throw error }
            return thumbnailBytes
        }
        func recipeJSON(id: String) throws -> Data? { recipes[id] }
        func storeRecipe(id: String, body: Data) throws -> RecipePostResponse {
            if let error { throw error }
            guard let item = items.first(where: { $0.id == id }) else { throw ItemStoreError.unknownItem(id: id) }
            let recipe = try JSONDecoder().decode(Recipe.self, from: body)
            try recipe.validate()
            recipes[id] = body
            return RecipePostResponse(item: item, recipe: recipe, renderKey: try recipe.renderKey())
        }
    }

    // MARK: - Fixtures

    private let token = "test-token"
    private let sha = String(repeating: "a1", count: 32)

    private func item(id: String = String(repeating: "a1", count: 32), state: ItemState = .pending) -> ItemSummary {
        ItemSummary(
            id: id,
            name: "R0003777-P3.tif",
            path: "/tmp/batch/R0003777-P3.tif",
            state: state,
            previewReady: state != .pending,
            hasRecipe: state == .recipeReceived,
            width: 6000,
            height: 4000
        )
    }

    private func recipe(id: String = String(repeating: "a1", count: 32)) -> Recipe {
        Recipe.defaults(
            sourcePath: "/tmp/batch/R0003777-P3.tif",
            sourceSHA256: id,
            width: 6000,
            height: 4000,
            encoderVersion: "5dba4e2",
            created: "2026-11-02T22:00:00+08:00"
        )
    }

    private func previewMeta(recipe: Recipe) -> PreviewMetadata {
        PreviewMetadata(
            source: .init(
                path: recipe.source.path, sha256: recipe.source.sha256,
                width: recipe.source.width, height: recipe.source.height,
                profileName: "Display P3", bitsPerComponent: 16
            ),
            base: .init(
                file: "preview-base.png", bytes: 3, sha256: sha, width: 2560, height: 1707,
                format: "png-16-p3", workingSpace: "linear-extended-DisplayP3-float32",
                profileName: "Display P3", longEdge: 2560
            ),
            recipeDefaults: recipe,
            appVersion: "0.2.0-m2",
            createdAt: "2026-11-02T22:00:00+08:00"
        )
    }

    private func request(
        _ method: HTTPMethod,
        _ path: String,
        authorized: Bool = true,
        body: Data = Data()
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if authorized, !token.isEmpty { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func makeRouter(_ store: FakeStore) -> APIRouter {
        APIRouter(store: store, token: token, appVersion: "0.2.0-m2")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        try JSONCoding.decode(type, from: response.body)
    }

    // MARK: - Health and auth

    func testHealthNeedsNoToken() throws {
        let store = FakeStore()
        store.count = 3
        let response = makeRouter(store).handle(request(.GET, "/api/health", authorized: false))
        XCTAssertEqual(response.status, 200)
        let health = try decode(HealthResponse.self, response)
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.itemCount, 3)
        XCTAssertEqual(health.version, "0.2.0-m2")
        XCTAssertTrue(health.authRequired, "a configured token means clients must authenticate")
    }

    /// P1-8: `authRequired` used to be a hard-coded `true`. The iPad decides from it whether to
    /// prompt for / send a token, so it must follow `!token.isEmpty`.
    func testHealthReportsAuthRequiredOnlyWhenATokenIsConfigured() throws {
        let store = FakeStore()
        store.count = 1

        let authenticated = APIRouter(store: store, token: "test-token", appVersion: "x")
        let withToken = try decode(
            HealthResponse.self,
            authenticated.handle(request(.GET, "/api/health", authorized: false))
        )
        XCTAssertTrue(withToken.authRequired)

        let open = APIRouter(store: store, token: "", appVersion: "x")
        let withoutToken = try decode(
            HealthResponse.self,
            open.handle(request(.GET, "/api/health", authorized: false))
        )
        XCTAssertFalse(withoutToken.authRequired, "no configured token means nothing is required")
        XCTAssertEqual(withoutToken.itemCount, 1)
    }

    /// P1-8: a failing `itemCount()` is a 500, not a silent `itemCount: 0` with `ok: true`.
    func testHealthDoesNotSwallowItemCountFailures() {
        let store = FakeStore()
        store.countError = .io(message: "cannot list batch directory")
        let response = makeRouter(store).handle(request(.GET, "/api/health", authorized: false))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .internalError)
    }

    func testEveryOtherRouteNeedsTheToken() {
        let store = FakeStore()
        store.items = [item()]
        let router = makeRouter(store)

        let probes: [(HTTPMethod, String)] = [
            (.GET, "/api/items"),
            (.GET, "/api/items/\(sha)"),
            (.GET, "/api/items/\(sha)/status"),
            (.POST, "/api/items/\(sha)/prepare"),
            (.GET, "/api/items/\(sha)/preview"),
            (.GET, "/api/items/\(sha)/thumbnail"),
            (.GET, "/api/items/\(sha)/meta"),
            (.GET, "/api/items/\(sha)/recipe"),
            (.POST, "/api/items/\(sha)/recipe"),
        ]
        for (method, path) in probes {
            let response = router.handle(request(method, path, authorized: false))
            XCTAssertEqual(response.status, 401, "\(method.rawValue) \(path)")
            let body = try? decode(APIErrorBody.self, response)
            XCTAssertEqual(body?.error.code, .unauthorized)
            XCTAssertEqual(response.headers["www-authenticate"], "Bearer")
        }
    }

    func testWrongTokenIsRejected() {
        let store = FakeStore()
        let router = APIRouter(store: store, token: "other", appVersion: "x")
        let response = router.handle(request(.GET, "/api/items"))
        XCTAssertEqual(response.status, 401)
    }

    func testXPhotonTokenHeaderIsAccepted() throws {
        let store = FakeStore()
        store.items = [item()]
        let router = makeRouter(store)
        let custom = HTTPRequest(method: .GET, path: "/api/items", headers: ["x-photon-token": token])
        XCTAssertEqual(router.handle(custom).status, 200)
    }

    // MARK: - Items

    func testListItems() throws {
        let store = FakeStore()
        store.items = [item(), item(id: String(repeating: "b2", count: 32), state: .previewReady)]
        let response = makeRouter(store).handle(request(.GET, "/api/items"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8")
        let list = try decode(ItemListResponse.self, response)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[1].state, .previewReady)
    }

    func testGetItemAndStatusShareTheShape() throws {
        let store = FakeStore()
        store.items = [item(state: .previewReady)]
        let router = makeRouter(store)
        for path in ["/api/items/\(sha)", "/api/items/\(sha)/status"] {
            let response = router.handle(request(.GET, path))
            XCTAssertEqual(response.status, 200)
            let summary = try decode(ItemSummary.self, response)
            XCTAssertEqual(summary.id, sha)
            XCTAssertEqual(summary.state, .previewReady)
        }
    }

    func testUnknownItemMapsTo404() {
        let store = FakeStore()
        let router = makeRouter(store)
        for path in ["/api/items/\(sha)", "/api/items/\(sha)/status", "/api/items/\(sha)/prepare"] {
            let method: HTTPMethod = path.hasSuffix("prepare") ? .POST : .GET
            let response = router.handle(request(method, path))
            XCTAssertEqual(response.status, 404, path)
            XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .notFound)
        }
    }

    // MARK: - Prepare / preview / meta

    func testPrepareReturnsMetaAndReportsCacheState() throws {
        let store = FakeStore()
        let recipe = recipe()
        store.items = [item(state: .previewReady)]
        store.preparedItem = store.items[0]
        store.preparedMeta = previewMeta(recipe: recipe)
        store.preparedCached = true
        let response = makeRouter(store).handle(request(.POST, "/api/items/\(sha)/prepare"))
        XCTAssertEqual(response.status, 200)
        let prepared = try decode(PrepareResponse.self, response)
        XCTAssertTrue(prepared.cached)
        XCTAssertEqual(prepared.meta.base.format, "png-16-p3")
        XCTAssertEqual(prepared.meta.source.sha256, sha)
        XCTAssertEqual(store.prepareCalls, 1)
    }

    func testPreviewPreparesThenServesPNG() throws {
        let store = FakeStore()
        let recipe = recipe()
        store.items = [item(state: .previewReady)]
        store.preparedItem = store.items[0]
        store.preparedMeta = previewMeta(recipe: recipe)
        let response = makeRouter(store).handle(request(.GET, "/api/items/\(sha)/preview"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "image/png")
        XCTAssertEqual(response.body, store.previewBytes)
        XCTAssertEqual(store.prepareCalls, 1)
    }

    func testMetaPreparesThenServesJSON() throws {
        let store = FakeStore()
        let recipe = recipe()
        store.items = [item(state: .previewReady)]
        store.preparedItem = store.items[0]
        store.preparedMeta = previewMeta(recipe: recipe)
        store.metaBytes = try JSONCoding.encode(store.preparedMeta!)
        let response = makeRouter(store).handle(request(.GET, "/api/items/\(sha)/meta"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8")
        let decoded = try JSONCoding.decode(PreviewMetadata.self, from: response.body)
        XCTAssertEqual(decoded.recipeDefaults.hdr.headroomCap, recipe.hdr.headroomCap)
        XCTAssertEqual(decoded.base.format, "png-16-p3")
        XCTAssertEqual(store.prepareCalls, 1)
    }

    // MARK: - Thumbnail (ADR-0013)

    /// The filmstrip's thumbnail is its own artifact: the route serves the store's HEIC bytes and
    /// must **not** call `prepare` — that coupling is exactly what ADR-0013 removes.
    func testThumbnailServesHEICWithoutPreparing() {
        let store = FakeStore()
        store.items = [item()]
        let response = makeRouter(store).handle(request(.GET, "/api/items/\(sha)/thumbnail"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "image/heic")
        XCTAssertEqual(response.body, store.thumbnailBytes)
        XCTAssertEqual(store.prepareCalls, 0, "a thumbnail must never prepare the preview base")
    }

    /// Thumbnail failures go through the same `ItemStoreError` → status table as every other route:
    /// a non-P3 source is the actionable 422, not a 500.
    func testThumbnailFailureUsesTheStoreErrorMapping() {
        let store = FakeStore()
        store.error = .sourceUnreadable(message: "unsupported source: not Display P3")
        let response = makeRouter(store).handle(request(.GET, "/api/items/\(sha)/thumbnail"))
        XCTAssertEqual(response.status, 422)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .sourceUnreadable)
    }

    func testPrepareFailureMapsTo500() {
        let store = FakeStore()
        store.preparedItem = item()
        store.preparedMeta = previewMeta(recipe: recipe())
        store.error = .prepareFailed(message: "encoder exploded")
        let response = makeRouter(store).handle(request(.POST, "/api/items/\(sha)/prepare"))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .prepareFailed)
    }

    /// P1-4 hand-off: a readable-but-unsupported source is a 422 `source_unreadable`, never a 500
    /// `prepare_failed` (the iPad re-exports; retrying the same file is pointless).
    func testUnsupportedSourceMapsTo422() {
        let store = FakeStore()
        store.error = .sourceUnreadable(message: "unsupported source: not Display P3")
        let response = makeRouter(store).handle(request(.POST, "/api/items/\(sha)/prepare"))
        XCTAssertEqual(response.status, 422)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .sourceUnreadable)
    }

    // MARK: - Recipe

    func testGetRecipeIs404WhenMissing() {
        let store = FakeStore()
        store.items = [item()]
        let response = makeRouter(store).handle(request(.GET, "/api/items/\(sha)/recipe"))
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .notFound)
    }

    func testPostRecipeRoundTrips() throws {
        let store = FakeStore()
        store.items = [item()]
        let posted = try JSONCoding.encode(recipe())
        let response = makeRouter(store).handle(request(.POST, "/api/items/\(sha)/recipe", body: posted))
        XCTAssertEqual(response.status, 200)
        let decoded = try decode(RecipePostResponse.self, response)
        XCTAssertEqual(decoded.recipe.hdr.liftStops, 1.4)
        XCTAssertEqual(decoded.renderKey.count, 64)

        let readBack = makeRouter(store).handle(request(.GET, "/api/items/\(sha)/recipe"))
        XCTAssertEqual(readBack.status, 200)
    }

    func testPostRecipeMapsSourceChangedTo409() {
        let store = FakeStore()
        store.items = [item()]
        store.error = .sourceChanged(expected: sha, actual: "deadbeef")
        let response = makeRouter(store).handle(
            request(.POST, "/api/items/\(sha)/recipe", body: try! JSONCoding.encode(recipe()))
        )
        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .sourceChanged)
    }

    func testPostInvalidRecipeMapsTo400() {
        let store = FakeStore()
        store.items = [item()]
        store.error = .invalidRecipe(message: "schema 7")
        let response = makeRouter(store).handle(
            request(.POST, "/api/items/\(sha)/recipe", body: try! JSONCoding.encode(recipe()))
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .invalidRecipe)
    }

    // MARK: - Errors and methods

    func testMethodNotAllowedCarriesAllowHeader() {
        let store = FakeStore()
        store.items = [item()]
        let router = makeRouter(store)
        let prepareAsGet = router.handle(request(.GET, "/api/items/\(sha)/prepare"))
        XCTAssertEqual(prepareAsGet.status, 405)
        XCTAssertEqual(prepareAsGet.headers["allow"], "POST")

        let itemsAsPost = router.handle(request(.POST, "/api/items"))
        XCTAssertEqual(itemsAsPost.status, 405)
        XCTAssertEqual(itemsAsPost.headers["allow"], "GET")

        let thumbnailAsPost = router.handle(request(.POST, "/api/items/\(sha)/thumbnail"))
        XCTAssertEqual(thumbnailAsPost.status, 405)
        XCTAssertEqual(thumbnailAsPost.headers["allow"], "GET")
    }

    func testUnknownRouteIs404() {
        let store = FakeStore()
        let response = makeRouter(store).handle(request(.GET, "/api/nope"))
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(try? decode(APIErrorBody.self, response).error.code, .notFound)
        let outsideAPI = makeRouter(store).handle(request(.GET, "/"))
        XCTAssertEqual(outsideAPI.status, 404)
    }

    func testResponsesAreNoStore() {
        let store = FakeStore()
        store.items = [item()]
        let response = makeRouter(store).handle(request(.GET, "/api/items"))
        XCTAssertEqual(response.headers["cache-control"], "no-store")
    }
}
