@testable import ClientKit
import ContractKit
import Foundation
import XCTest

/// Pins the M3.5 recipe draft rules (docs/reference/client.md, control model and state/errors;
/// docs/reference/recipe.md, recipe schema 0):
/// only `hdr` + `created` may change, everything else is preserved, and the local validation is
/// the contract's `Recipe.validate()` (no second hard-coded set of ranges).
final class RecipeDraftTests: XCTestCase {
    private static let sourceSHA = "bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116"
    private static let sourcePath = "samples/sources/R0003777-P3.tif"
    private static let templateCreated = "2026-11-02T20:52:00+08:00"
    private static let postedCreated = "2026-11-03T10:31:00+08:00"

    private func makeTemplate(hdr: Recipe.HDR = Recipe.HDR()) -> Recipe {
        Recipe(
            source: Recipe.Source(
                path: Self.sourcePath,
                sha256: Self.sourceSHA,
                width: 6000,
                height: 4000
            ),
            hdr: hdr,
            versions: Recipe.Versions(encoder: "5dba4e2"),
            created: Self.templateCreated
        )
    }

    // MARK: - Defaults and dirtiness

    func testDraftStartsAtTheTemplateDefaults() {
        let template = makeTemplate()
        let draft = RecipeDraft(defaults: template)
        XCTAssertEqual(draft.start, 0.62)
        XCTAssertEqual(draft.liftStops, 1.4)
        XCTAssertEqual(draft.transition, 0.28)
        XCTAssertEqual(draft.headroomCap, Recipe.HDR.defaultHeadroomCap)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.template, template)
    }

    func testDraftTakesItsValuesFromTheTemplateNotFromTheSchemaDefaults() {
        let template = makeTemplate(
            hdr: Recipe.HDR(start: 0.8, liftStops: 0.5, transition: 0.1, headroomCap: 2.2)
        )
        let draft = RecipeDraft(defaults: template)
        XCTAssertEqual(draft.start, 0.8)
        XCTAssertEqual(draft.liftStops, 0.5)
        XCTAssertEqual(draft.transition, 0.1)
        XCTAssertEqual(draft.headroomCap, 2.2)
        XCTAssertFalse(draft.isDirty)
    }

    func testEachEditMarksTheDraftDirty() {
        var draft = RecipeDraft(defaults: makeTemplate())
        draft.start = 0.7
        XCTAssertTrue(draft.isDirty)
        draft.start = 0.62
        XCTAssertFalse(draft.isDirty)

        draft.liftStops = 2
        XCTAssertTrue(draft.isDirty)
        draft.liftStops = 1.4
        XCTAssertFalse(draft.isDirty)

        draft.transition = 0.4
        XCTAssertTrue(draft.isDirty)
        draft.transition = 0.28
        XCTAssertFalse(draft.isDirty)

        draft.headroomCap = 2
        XCTAssertTrue(draft.isDirty)
        draft.headroomCap = Recipe.HDR.defaultHeadroomCap
        XCTAssertFalse(draft.isDirty)

        // An explicit equal-to-default assignment is not a change.
        draft.start = 0.62
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - Recipe assembly: only hdr + created change

    func testRecipeChangesOnlyHDRAndCreated() throws {
        let template = makeTemplate()
        var draft = RecipeDraft(defaults: template)
        draft.start = 0.75
        draft.liftStops = 2.25
        draft.transition = 0.12

        let posted = try draft.recipe(created: Self.postedCreated)
        let expected = Recipe(
            schema: template.schema,
            source: template.source,
            base: template.base,
            hdr: Recipe.HDR(start: 0.75, liftStops: 2.25, transition: 0.12, headroomCap: Recipe.HDR.defaultHeadroomCap),
            encoder: template.encoder,
            versions: template.versions,
            created: Self.postedCreated
        )

        // Byte-for-byte canonical equality is the strongest form of "only hdr + created".
        XCTAssertEqual(try posted.canonicalJSON(), try expected.canonicalJSON())

        // And spell out the preserved fields the wire contract calls out.
        XCTAssertEqual(posted.schema, template.schema)
        XCTAssertEqual(posted.source, template.source, "source.path/sha256/width/height are provenance + identity")
        XCTAssertEqual(posted.source.path, Self.sourcePath)
        XCTAssertEqual(posted.base, template.base)
        XCTAssertEqual(posted.encoder, template.encoder)
        XCTAssertEqual(posted.versions, template.versions)
        XCTAssertEqual(posted.created, Self.postedCreated)
        XCTAssertNoThrow(try posted.validate())
    }

    func testHeadroomCapIsEditableAndPosts() throws {
        let template = makeTemplate(
            hdr: Recipe.HDR(start: 0.5, liftStops: 1, transition: 0.2, headroomCap: 2.2)
        )
        var draft = RecipeDraft(defaults: template)
        draft.headroomCap = 4
        XCTAssertTrue(draft.isDirty)
        let posted = try draft.recipe(created: Self.postedCreated)
        XCTAssertEqual(posted.hdr.headroomCap, 4, "the cap is an authoring control and must be posted")
        XCTAssertEqual(draft.template.hdr.headroomCap, 2.2, "editing the draft never mutates the template")
    }

    func testHeadroomCapAboveTheSchemaUpperBoundFailsLocalValidation() {
        var draft = RecipeDraft(defaults: makeTemplate())
        draft.headroomCap = 8.1
        XCTAssertThrowsError(try draft.validate()) { error in
            guard case let PhotonError.invalidRecipe(field, _) = error else {
                return XCTFail("expected PhotonError.invalidRecipe, got \(error)")
            }
            XCTAssertEqual(field, "hdr.headroom_cap")
        }
    }

    // MARK: - Validation edge cases (docs/reference/client.md, control model)

    func testStartAtOneAndLiftAtZeroAreLegal() throws {
        var draft = RecipeDraft(defaults: makeTemplate())
        draft.start = 1
        draft.liftStops = 0
        draft.transition = 0.28
        XCTAssertNoThrow(try draft.validate())
        let posted = try draft.recipe(created: Self.postedCreated)
        XCTAssertEqual(posted.hdr.start, 1)
        XCTAssertEqual(posted.hdr.liftStops, 0)
    }

    func testAnInvalidTemplateIsRefusedWhenBuildingTheRecipe() {
        // A template with an unsupported schema is not saveable even if the controls are fine.
        let bad = Recipe(
            schema: 7,
            source: Recipe.Source(path: Self.sourcePath, sha256: Self.sourceSHA, width: 6000, height: 4000),
            versions: Recipe.Versions(encoder: "5dba4e2"),
            created: Self.templateCreated
        )
        let draft = RecipeDraft(defaults: bad)
        XCTAssertFalse(draft.isDirty)
        XCTAssertThrowsError(try draft.recipe(created: Self.postedCreated)) { error in
            guard case let PhotonError.invalidRecipe(field, _) = error else {
                return XCTFail("expected PhotonError.invalidRecipe, got \(error)")
            }
            XCTAssertEqual(field, "schema")
        }
    }

    func testPreservedSourceIdentityCannotBeChangedByTheControls() throws {
        // The draft has no API to touch source/base/encoder/versions; the only way to change the
        // identity is a mutation on the struct, which cannot alter the template's stored Recipe.
        let template = makeTemplate()
        var draft = RecipeDraft(defaults: template)
        draft.start = 0.1
        let posted = try draft.recipe(created: Self.postedCreated)
        XCTAssertEqual(posted.source.sha256, Self.sourceSHA, "the draft must never re-identify the source")
        XCTAssertEqual(posted.versions, template.versions)
        XCTAssertEqual(draft.template, template, "building a recipe does not mutate the template")
    }
}
