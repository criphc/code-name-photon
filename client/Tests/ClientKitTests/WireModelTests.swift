@testable import ClientKit
import ContractKit
import Foundation
import XCTest

/// Pins the client DTOs to the M2.1 wire JSON (docs/reference/wire.md, M2.1 wire contract; docs/reference/client.md,
/// architecture).
///
/// The payloads are not duplicated here: they are the schema-0 golden fixtures under
/// `contract/Tests/ContractKitTests/Fixtures/schema-0/`, which the server-side tests and the
/// contract package read too. This file keeps only client-specific behaviour assertions (state
/// raw values, unknown values failing loudly, explicit JSON nulls).
final class WireModelTests: XCTestCase {
    private let sourceSHA = "bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116"

    private func decode<T: Decodable>(_ type: T.Type, side: String, name: String) throws -> T {
        try JSONDecoder().decode(type, from: try TestSupport.wireFixtureData(side, name))
    }

    // MARK: - ItemState / ItemSummary / ItemListResponse

    func testItemStateRawValuesMatchTheServer() {
        XCTAssertEqual(ItemState.pending.rawValue, "pending")
        XCTAssertEqual(ItemState.previewReady.rawValue, "preview_ready")
        XCTAssertEqual(ItemState.recipeReceived.rawValue, "recipe_received")
        XCTAssertEqual(ItemState.failed.rawValue, "failed")
        XCTAssertEqual(ItemState.allCases.count, 4)
    }

    func testItemListDecodesTheGoldenFixture() throws {
        let list = try decode(ItemListResponse.self, side: "server", name: "items")
        XCTAssertEqual(list.items.count, 6)
        XCTAssertEqual(Set(list.items.map(\.state)), [.pending, .recipeReceived, .failed])

        let failed = try XCTUnwrap(list.items.first { $0.state == .failed })
        XCTAssertFalse(failed.previewReady)
        XCTAssertFalse(failed.hasRecipe)
        XCTAssertNotNil(failed.error)
        XCTAssertTrue(failed.error?.contains("Display P3") == true)

        let item = try XCTUnwrap(list.items.first { $0.id.hasPrefix("bd486ca6") })
        XCTAssertEqual(item.id, sourceSHA)
        XCTAssertEqual(item.name, "R0003777-P3.tif")
        XCTAssertEqual(item.state, .recipeReceived)
        XCTAssertTrue(item.previewReady)
        XCTAssertTrue(item.hasRecipe)
        XCTAssertEqual(item.width, 6000)
        XCTAssertEqual(item.height, 4000)
        XCTAssertNil(item.error)
    }

    func testItemSummaryDecodesExplicitNulls() throws {
        let json = """
        {
          "id": "aaa", "name": "A-P3.tif", "path": "/batch/A-P3.tif",
          "state": "failed", "previewReady": false, "hasRecipe": false,
          "width": null, "height": null, "error": null
        }
        """
        let item = try JSONDecoder().decode(ItemSummary.self, from: Data(json.utf8))
        XCTAssertNil(item.width)
        XCTAssertNil(item.height)
        XCTAssertNil(item.error, "an explicit JSON null must decode as nil")
    }

    func testUnknownItemStateFailsLoudly() {
        let json = #"{"id":"a","name":"A","path":"/a","state":"reticulating","previewReady":false,"hasRecipe":false}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ItemSummary.self, from: Data(json.utf8)))
    }

    // MARK: - HealthResponse

    func testHealthResponseDecodesTheGoldenFixture() throws {
        let health = try decode(HealthResponse.self, side: "server", name: "health")
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.name, "photon")
        XCTAssertEqual(health.version, "0.3.0-m21")
        XCTAssertEqual(health.itemCount, 6)
        XCTAssertTrue(health.authRequired)
    }

    // MARK: - PreviewMetadata

    func testPreviewMetadataDecodesTheGoldenFixture() throws {
        let meta = try decode(PreviewMetadata.self, side: "server", name: "preview-meta")
        XCTAssertEqual(PreviewMetadata.currentSchema, 0)
        XCTAssertEqual(meta.schema, 0)
        XCTAssertEqual(meta.appVersion, "0.3.0-m21")

        XCTAssertEqual(meta.source.sha256, sourceSHA)
        XCTAssertEqual(meta.source.width, 6000)
        XCTAssertEqual(meta.source.height, 4000)
        XCTAssertEqual(meta.source.profileName, "Display P3")
        XCTAssertEqual(meta.source.bitsPerComponent, 16)

        XCTAssertEqual(meta.base.file, "preview-base.png")
        XCTAssertEqual(meta.base.format, "png-16-p3")
        XCTAssertEqual(meta.base.workingSpace, "linear-extended-DisplayP3-float32")
        XCTAssertEqual(meta.base.width, 2560)
        XCTAssertEqual(meta.base.height, 1707)
        XCTAssertEqual(meta.base.longEdge, 2560)

        let recipe = meta.recipeDefaults
        XCTAssertEqual(recipe.schema, 0)
        XCTAssertEqual(recipe.source.sha256, sourceSHA)
        XCTAssertEqual(recipe.base.profile, "DisplayP3")
        XCTAssertEqual(recipe.base.toneMap, "c1_match_v1")
        XCTAssertEqual(recipe.hdr.start, 0.62)
        XCTAssertEqual(recipe.hdr.liftStops, 1.4)
        XCTAssertEqual(recipe.hdr.transition, 0.28)
        XCTAssertEqual(recipe.hdr.headroomCap, 2.5)
        XCTAssertEqual(recipe.encoder.tool, "toGainMapHDR")
        XCTAssertEqual(recipe.encoder.quality, 0.85)
        XCTAssertEqual(recipe.encoder.depth, 8)
        XCTAssertFalse(recipe.encoder.subsample)
        XCTAssertEqual(recipe.encoder.map, "iso-rgb")
        XCTAssertEqual(recipe.versions.recipe, 0)
        XCTAssertEqual(recipe.versions.toneMap, 1)
        XCTAssertEqual(recipe.versions.encoder, "5dba4e2")
        XCTAssertNoThrow(try recipe.validate())
    }

    func testPreviewMetadataDecodesNullProfileNames() throws {
        let sourceJSON = """
        { "path": "a.tif", "sha256": "\(sourceSHA)", "width": 1, "height": 1,
          "profileName": null, "bitsPerComponent": 16 }
        """
        let baseJSON = """
        { "file": "preview-base.png", "bytes": 1, "sha256": "\(sourceSHA)",
          "width": 1, "height": 1, "format": "png-16-p3",
          "workingSpace": "linear-extended-DisplayP3-float32",
          "profileName": null, "longEdge": 1 }
        """
        let source = try JSONDecoder().decode(PreviewMetadata.SourceInfo.self, from: Data(sourceJSON.utf8))
        let base = try JSONDecoder().decode(PreviewMetadata.BaseInfo.self, from: Data(baseJSON.utf8))
        XCTAssertNil(source.profileName)
        XCTAssertNil(base.profileName)
    }

    // MARK: - PrepareResponse / RecipePostResponse / APIErrorBody

    func testPrepareResponseDecodesTheGoldenFixture() throws {
        let prepare = try decode(PrepareResponse.self, side: "client", name: "prepare-response")
        XCTAssertEqual(prepare.item.id, sourceSHA)
        XCTAssertEqual(prepare.item.state, .recipeReceived)
        XCTAssertEqual(prepare.meta.base.width, 2560)
        XCTAssertFalse(prepare.cached)
        XCTAssertEqual(prepare.meta.recipeDefaults.hdr.start, 0.62)
    }

    func testRecipePostResponseDecodesTheGoldenFixture() throws {
        let response = try decode(RecipePostResponse.self, side: "client", name: "recipe-post-response")
        XCTAssertEqual(response.item.state, .recipeReceived)
        XCTAssertEqual(response.renderKey, "0bb774682c9d178c852f085b3badf2813397485c422dc50e79efc3e0be5fb747")
        XCTAssertEqual(response.recipe.hdr.transition, 1.0)
        XCTAssertGreaterThan(response.recipe.hdr.liftStops, 1.4, "the archived posted recipe authored a stronger lift")
        XCTAssertNoThrow(try response.recipe.validate())
    }

    func testAPIErrorBodyDecodesTheGoldenFixture() throws {
        let body = try decode(APIErrorBody.self, side: "client", name: "api-error")
        XCTAssertEqual(body.code, .sourceChanged)
        XCTAssertFalse(body.error.message.isEmpty)
    }

    func testAPIErrorBodyDecodesEveryCode() throws {
        for code in APIErrorCode.allCases {
            let json = #"{"error":{"code":"\#(code.rawValue)","message":"detail for \#(code.rawValue)"}}"#
            let body = try JSONDecoder().decode(APIErrorBody.self, from: Data(json.utf8))
            XCTAssertEqual(body.code, code)
            XCTAssertEqual(body.error.message, "detail for \(code.rawValue)")
        }
    }

    func testErrorBodyWithUnknownCodeFailsToDecode() {
        let json = #"{"error":{"code":"rate_limited","message":"slow down"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(APIErrorBody.self, from: Data(json.utf8)))
    }
}
