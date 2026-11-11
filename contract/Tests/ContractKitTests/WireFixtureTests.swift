import Foundation
import Testing
@testable import ContractKit

/// The wire contract is pinned to the stage-1 schema-0 bytes, which live in exactly one place:
/// `Fixtures/schema-0/` as a package resource. Server and client code now share these types, so a
/// decode of the old bytes proves the migration did not change the JSON shape (ADR-0004).
@Suite("schema-0 golden fixtures")
struct WireFixtureTests {
    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let path): return "missing fixture \(path)"
            }
        }
    }

    private func data(_ side: String, _ name: String) throws -> Data {
        let relative = "Fixtures/schema-0/\(side)/\(name).json"
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/schema-0/\(side)"
        ) else {
            throw FixtureError.missing(relative)
        }
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ side: String, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(side, name))
    }

    /// Decode → encode → decode must be lossless, and the encoded JSON must have the same key/value
    /// shape as the stage-1 bytes (formatting may differ).
    private func assertRoundTripAndShape<T: Codable & Equatable>(_ type: T.Type, _ side: String, _ name: String) throws {
        let originalData = try data(side, name)
        let original = try JSONDecoder().decode(T.self, from: originalData)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(T.self, from: encoded)
        #expect(decoded == original, "\(side)/\(name) must survive a decode→encode→decode round trip")
        let originalObject = try JSONSerialization.jsonObject(with: originalData)
        let encodedObject = try JSONSerialization.jsonObject(with: encoded)
        #expect(
            NSDictionary(dictionary: try #require(originalObject as? [String: Any]))
                == NSDictionary(dictionary: try #require(encodedObject as? [String: Any])),
            "\(side)/\(name) must encode back to the same JSON shape"
        )
    }

    @Test func healthDecodesRealServerBytes() throws {
        let health = try decode(HealthResponse.self, "server", "health")
        #expect(health.ok)
        #expect(health.name == "photon")
        #expect(health.version == "0.3.0-m21")
        #expect(health.itemCount == 6)
        #expect(health.authRequired)
        try assertRoundTripAndShape(HealthResponse.self, "server", "health")
    }

    @Test func itemsDecodeRealServerBytes() throws {
        let list = try decode(ItemListResponse.self, "server", "items")
        #expect(list.items.count == 6)
        #expect(Set(list.items.map(\.id)).count == 6)
        #expect(list.items.allSatisfy { $0.id.count == 64 && $0.id.allSatisfy(\.isHexDigit) })
        // The archived final listing has pending, recipe_received and failed items; preview_ready
        // is exercised by the client tests that post before a recipe.
        #expect(Set(list.items.map(\.state)) == [.pending, .recipeReceived, .failed])

        let failed = try #require(list.items.first { $0.state == .failed })
        #expect(failed.previewReady == false)
        #expect(failed.hasRecipe == false)
        #expect(failed.error?.contains("Display P3") == true, "the failed item carries the actionable reason")

        let item = try #require(list.items.first { $0.id.hasPrefix("bd486ca6") })
        #expect(item.name == "R0003777-P3.tif")
        #expect(item.state == .recipeReceived)
        #expect(item.previewReady)
        #expect(item.hasRecipe)
        #expect(item.width == 6000)
        #expect(item.height == 4000)
        #expect(item.error == nil)
        try assertRoundTripAndShape(ItemListResponse.self, "server", "items")
    }

    @Test func previewMetadataDecodesRealServerBytes() throws {
        let meta = try decode(PreviewMetadata.self, "server", "preview-meta")
        #expect(meta.schema == PreviewMetadata.currentSchema)
        #expect(meta.appVersion == "0.3.0-m21")
        #expect(meta.source.sha256 == "bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116")
        #expect(meta.source.width == 6000)
        #expect(meta.source.height == 4000)
        #expect(meta.source.profileName == "Display P3")
        #expect(meta.source.bitsPerComponent == 16)
        #expect(meta.base.file == "preview-base.png")
        #expect(meta.base.format == "png-16-p3")
        #expect(meta.base.workingSpace == "linear-extended-DisplayP3-float32")
        #expect(meta.base.width == 2560)
        #expect(meta.base.longEdge == 2560)
        #expect(meta.recipeDefaults.hdr.start == 0.62)
        #expect(meta.recipeDefaults.hdr.headroomCap == 2.5)
        try meta.recipeDefaults.validate()
        try assertRoundTripAndShape(PreviewMetadata.self, "server", "preview-meta")
    }

    @Test func postedRecipeDecodesRealServerBytes() throws {
        let recipe = try decode(Recipe.self, "server", "recipe")
        #expect(recipe.schema == 0)
        #expect(recipe.source.sha256 == "bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116")
        #expect(recipe.source.width == 6000)
        #expect(recipe.source.height == 4000)
        #expect(recipe.hdr.headroomCap == 2.5)
        #expect(recipe.hdr.liftStops > 1.4, "this archived recipe authored a stronger lift")
        try recipe.validate()
        try assertRoundTripAndShape(Recipe.self, "server", "recipe")
    }

    @Test func prepareResponseDecodesRealPayloads() throws {
        let response = try decode(PrepareResponse.self, "client", "prepare-response")
        #expect(response.cached == false)
        #expect(response.item.id == "bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116")
        #expect(response.meta.base.width == 2560)
        #expect(response.meta.recipeDefaults.hdr.transition == 0.28)
        try response.meta.recipeDefaults.validate()
        try assertRoundTripAndShape(PrepareResponse.self, "client", "prepare-response")
    }

    @Test func recipePostResponseDecodesRealPayloads() throws {
        let response = try decode(RecipePostResponse.self, "client", "recipe-post-response")
        #expect(response.item.state == .recipeReceived)
        #expect(response.renderKey == "0bb774682c9d178c852f085b3badf2813397485c422dc50e79efc3e0be5fb747")
        #expect(response.recipe.hdr.headroomCap == 2.5)
        try response.recipe.validate()
        try assertRoundTripAndShape(RecipePostResponse.self, "client", "recipe-post-response")
    }

    @Test func apiErrorDecodesAndEncodesEveryCode() throws {
        let body = try decode(APIErrorBody.self, "client", "api-error")
        #expect(body.code == .sourceChanged)
        #expect(body.error.message.contains("re-exported"))
        try assertRoundTripAndShape(APIErrorBody.self, "client", "api-error")

        for code in APIErrorCode.allCases {
            let encoded = try JSONEncoder().encode(APIErrorBody(code: code, message: "detail"))
            let decoded = try JSONDecoder().decode(APIErrorBody.self, from: encoded)
            #expect(decoded.code == code)
        }
    }
}
