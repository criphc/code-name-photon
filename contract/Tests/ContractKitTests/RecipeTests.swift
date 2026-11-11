import Foundation
import XCTest
@testable import ContractKit

/// Contract tests for the recipe: the JSON shape is fixed by docs/reference/recipe.md (recipe schema 0), the validation rules
/// are binding, and two identical recipes must resolve to the same render key regardless of `created`.
final class RecipeTests: XCTestCase {
    private let sourceSHA = String(repeating: "ab", count: 32)

    private func makeRecipe() -> Recipe {
        Recipe.defaults(
            sourcePath: "samples/sources/R0003777-P3.tif",
            sourceSHA256: sourceSHA,
            width: 6000,
            height: 4000,
            encoderVersion: "5dba4e2",
            created: "2026-11-02T20:52:00+08:00"
        )
    }

    // MARK: - JSON shape (docs/reference/recipe.md, recipe schema 0)

    private let documentedJSON = """
    {
      "schema": 0,
      "source":   { "path": "samples/sources/R0003777-P3.tif", "sha256": "abababababababababababababababababababababababababababababababab", "width": 6000, "height": 4000 },
      "base":     { "profile": "DisplayP3", "tone_map": "c1_match_v1" },
      "hdr":      { "start": 0.62, "lift_stops": 1.4, "transition": 0.28, "headroom_cap": \(Recipe.HDR.defaultHeadroomCap) },
      "encoder":  { "tool": "coreimage", "quality": 0.85, "depth": 10, "subsample": true, "map": "iso-rgb" },
      "versions": { "recipe": 0, "tone_map": 1, "encoder": "5dba4e2" },
      "created":  "2026-11-02T20:52:00+08:00"
    }
    """

    func testDecodesDocumentedJSON() throws {
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(documentedJSON.utf8))
        XCTAssertNoThrow(try recipe.validate())
        XCTAssertEqual(recipe, makeRecipe())
    }

    func testEncodesDocumentedKeys() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try makeRecipe().canonicalJSON()) as? [String: Any]
        )
        XCTAssertEqual((object["hdr"] as? [String: Any])?["lift_stops"] as? Double, 1.4)
        XCTAssertEqual((object["hdr"] as? [String: Any])?["headroom_cap"] as? Double, Recipe.HDR.defaultHeadroomCap)
        XCTAssertEqual((object["base"] as? [String: Any])?["tone_map"] as? String, "c1_match_v1")
        XCTAssertEqual((object["versions"] as? [String: Any])?["tone_map"] as? Int, 1)
        XCTAssertEqual((object["encoder"] as? [String: Any])?["map"] as? String, "iso-rgb")
    }

    func testCanonicalJSONIsStable() throws {
        let first = try makeRecipe().canonicalJSON()
        let second = try makeRecipe().canonicalJSON()
        XCTAssertEqual(first, second)
        // sorted keys => "base" before "created" before "encoder" …
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"base\"")).lowerBound, try XCTUnwrap(text.range(of: "\"encoder\"")).lowerBound)
    }

    // MARK: - Render key

    func testRenderKeyIgnoresCreated() throws {
        var later = makeRecipe()
        later = Recipe(
            source: later.source,
            base: later.base,
            hdr: later.hdr,
            encoder: later.encoder,
            versions: later.versions,
            created: "2027-01-01T00:00:00+08:00"
        )
        XCTAssertEqual(try makeRecipe().renderKey(), try later.renderKey())
        XCTAssertNotEqual(try makeRecipe().canonicalJSON(), try later.canonicalJSON())
    }

    func testRenderKeyChangesWhenAnyRenderFieldChanges() throws {
        let base = try makeRecipe().renderKey()
        var variants: [Recipe] = []
        variants.append(Recipe(source: makeRecipe().source, hdr: .init(start: 0.7), versions: makeRecipe().versions, created: makeRecipe().created))
        variants.append(Recipe(source: makeRecipe().source, hdr: .init(liftStops: 1.5), versions: makeRecipe().versions, created: makeRecipe().created))
        variants.append(Recipe(source: makeRecipe().source, hdr: .init(transition: 0.3), versions: makeRecipe().versions, created: makeRecipe().created))
        variants.append(Recipe(source: makeRecipe().source, hdr: .init(headroomCap: 2.0), versions: makeRecipe().versions, created: makeRecipe().created))
        // Encoder params select the delivered bytes too, so they must move the key. The variants
        // flip away from the v2 defaults (10/half) so each differs from the base recipe.
        variants.append(Recipe(source: makeRecipe().source, encoder: .init(quality: 0.9), versions: makeRecipe().versions, created: makeRecipe().created))
        variants.append(Recipe(source: makeRecipe().source, encoder: .init(depth: 8), versions: makeRecipe().versions, created: makeRecipe().created))
        variants.append(Recipe(source: makeRecipe().source, encoder: .init(subsample: false), versions: makeRecipe().versions, created: makeRecipe().created))
        variants.append(Recipe(source: makeRecipe().source, versions: .init(encoder: "deadbee"), created: makeRecipe().created))
        var keys = Set<String>()
        for recipe in variants { keys.insert(try recipe.renderKey()) }
        XCTAssertEqual(keys.count, variants.count)
        XCTAssertFalse(keys.contains(base))
    }

    // MARK: - Render key: source identity in, provenance out (review P1-6)

    /// The recipe's `source.path` is provenance: it never reaches `renderKey()`, so the same bytes
    /// keep the same cache key no matter how the repository or the export is addressed.
    func testRenderKeyIgnoresSourcePath() throws {
        let base = try makeRecipe().renderKey()
        let baseJSON = try makeRecipe().canonicalJSON()
        let knownPath = "samples/sources/R0003777-P3.tif"
        let paths = [
            knownPath,                                                              // repo-relative
            "/Users/someone/Sites/llm-photon/samples/sources/R0003777-P3.tif",       // absolute
            "../elsewhere/R0003777-P3.tif",                                         // different dir
            "archive/2026/11/03/R0003777-P3-copy.tif",                              // moved/renamed
        ]
        for path in paths {
            let variant = Recipe(
                source: .init(path: path, sha256: sourceSHA, width: 6000, height: 4000),
                versions: makeRecipe().versions,
                created: makeRecipe().created
            )
            XCTAssertEqual(
                try variant.renderKey(), base,
                "source.path is provenance and must not enter the render key (path: \(path))"
            )
            // The full recipe JSON still records it — provenance is not thrown away.
            if path != knownPath {
                XCTAssertNotEqual(
                    try variant.canonicalJSON(), baseJSON,
                    "canonicalJSON must keep the provenance path (path: \(path))"
                )
            }
        }
    }

    /// The render JSON's `source` object is identity only: exactly sha256/width/height, no path.
    func testCanonicalRenderJSONKeepsOnlySourceIdentity() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try makeRecipe().canonicalRenderJSON()) as? [String: Any]
        )
        let source = try XCTUnwrap(object["source"] as? [String: Any])
        XCTAssertEqual(Set(source.keys), ["sha256", "width", "height"])
        XCTAssertNil(source["path"], "source.path must not be part of the render key")
        XCTAssertNil(object["created"], "created must not be part of the render key")
    }

    /// Everything that identifies the source bytes still moves the key, even with the path excluded.
    func testRenderKeyChangesWithSourceIdentity() throws {
        let base = try makeRecipe().renderKey()
        let path = "samples/sources/R0003777-P3.tif"
        let variants: [Recipe.Source] = [
            .init(path: path, sha256: String(repeating: "cd", count: 32), width: 6000, height: 4000),
            .init(path: path, sha256: sourceSHA, width: 6001, height: 4000),
            .init(path: path, sha256: sourceSHA, width: 6000, height: 3999),
        ]
        var keys = Set<String>()
        for source in variants {
            let key = try Recipe(source: source, versions: makeRecipe().versions, created: makeRecipe().created).renderKey()
            XCTAssertFalse(keys.contains(key), "two different source identities collided on one render key")
            keys.insert(key)
            XCTAssertNotEqual(key, base, "sha256/width/height must move the render key")
        }
        XCTAssertEqual(keys.count, variants.count)
    }

    // MARK: - Validation

    private func assertInvalid(_ recipe: Recipe, field: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try recipe.validate(), file: file, line: line) { error in
            guard case let PhotonError.invalidRecipe(name, _)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(name, field, file: file, line: line)
        }
    }

    private func replacing(
        schema: Int? = nil,
        hdr: Recipe.HDR? = nil,
        encoder: Recipe.EncoderParams? = nil,
        base: Recipe.Base? = nil,
        versions: Recipe.Versions? = nil
    ) -> Recipe {
        let recipe = makeRecipe()
        return Recipe(
            schema: schema ?? recipe.schema,
            source: recipe.source,
            base: base ?? recipe.base,
            hdr: hdr ?? recipe.hdr,
            encoder: encoder ?? recipe.encoder,
            versions: versions ?? recipe.versions,
            created: recipe.created
        )
    }

    func testRejectsUnknownSchema() {
        assertInvalid(replacing(schema: 1), field: "schema")
    }

    func testRejectsOutOfRangeHDRFields() {
        assertInvalid(replacing(hdr: .init(start: 1.5)), field: "hdr.start")
        assertInvalid(replacing(hdr: .init(liftStops: 9)), field: "hdr.lift_stops")
        assertInvalid(replacing(hdr: .init(transition: 0)), field: "hdr.transition")
        assertInvalid(replacing(hdr: .init(headroomCap: 0.9)), field: "hdr.headroom_cap")
        assertInvalid(replacing(hdr: .init(headroomCap: 8.5)), field: "hdr.headroom_cap")
    }

    func testAcceptsHeadroomCapUpToTheUpperBound() {
        XCTAssertNoThrow(try replacing(hdr: .init(headroomCap: 8)).validate())
    }

    func testRejectsUnsupportedBase() {
        assertInvalid(replacing(base: .init(profile: "AdobeRGB")), field: "base.profile")
        assertInvalid(replacing(base: .init(toneMap: "film_v2")), field: "base.tone_map")
    }

    func testRejectsUnsafeEncoderFields() {
        assertInvalid(replacing(encoder: .init(depth: 12)), field: "encoder.depth")
        assertInvalid(replacing(encoder: .init(map: "apple-mono")), field: "encoder.map")
        assertInvalid(replacing(encoder: .init(quality: 1.5)), field: "encoder.quality")
        assertInvalid(replacing(encoder: .init(tool: "libheif")), field: "encoder.tool")
    }

    func testAcceptsTheV2EncoderProfiles() throws {
        // v2: half-resolution maps and ISO mono are delivery profiles, not the old `-H` trap.
        XCTAssertNoThrow(try replacing(encoder: .init(subsample: true)).validate())
        XCTAssertNoThrow(try replacing(encoder: .init(map: Recipe.EncoderParams.isoMonoMap)).validate())
        XCTAssertNoThrow(try replacing(encoder: .init(tool: Recipe.EncoderParams.coreImageToolName)).validate())
        XCTAssertNoThrow(try replacing(encoder: .init(depth: 10, subsample: true)).validate())
    }

    func testRejectsVersionMismatch() {
        assertInvalid(replacing(versions: .init(recipe: 1, encoder: "5dba4e2")), field: "versions.recipe")
        assertInvalid(replacing(versions: .init(toneMap: 2, encoder: "5dba4e2")), field: "versions.tone_map")
        assertInvalid(replacing(versions: .init(encoder: "")), field: "versions.encoder")
    }

    func testRejectsBadSourceIdentity() {
        let badSHA = Recipe.Source(path: "x.tif", sha256: "not-a-hash", width: 1, height: 1)
        assertInvalid(Recipe(source: badSHA, versions: makeRecipe().versions, created: makeRecipe().created), field: "source.sha256")
        let badDims = Recipe.Source(path: "x.tif", sha256: sourceSHA, width: 0, height: 1)
        assertInvalid(Recipe(source: badDims, versions: makeRecipe().versions, created: makeRecipe().created), field: "source.width/height")
        let badPath = Recipe.Source(path: "", sha256: sourceSHA, width: 1, height: 1)
        assertInvalid(Recipe(source: badPath, versions: makeRecipe().versions, created: makeRecipe().created), field: "source.path")
    }

    func testDefaultsMatchDocumentedValues() throws {
        let recipe = makeRecipe()
        XCTAssertEqual(recipe.hdr.start, 0.62)
        XCTAssertEqual(recipe.hdr.liftStops, 1.4)
        XCTAssertEqual(recipe.hdr.transition, 0.28)
        XCTAssertEqual(recipe.hdr.headroomCap, pow(2.0, 2.0), accuracy: 1e-12)
        XCTAssertEqual(recipe.encoder.tool, "coreimage")
        XCTAssertEqual(recipe.encoder.quality, 0.85)
        XCTAssertEqual(recipe.encoder.depth, 10)
        XCTAssertTrue(recipe.encoder.subsample)
        XCTAssertEqual(recipe.encoder.map, "iso-rgb")
        XCTAssertEqual(recipe.base.toneMap, "c1_match_v1")
        XCTAssertNoThrow(try recipe.validate())
    }
}
