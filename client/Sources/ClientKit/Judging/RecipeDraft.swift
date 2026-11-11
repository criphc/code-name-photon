import Foundation
import ContractKit

/// The editable recipe draft: the metadata template plus the three creative controls and the
/// delivery ceiling.
///
/// Contract (docs/reference/client.md, control model and state/errors; docs/reference/recipe.md, recipe schema 0):
/// - the draft is built from `PreviewMetadata.recipeDefaults`; the control ranges/defaults come
///   from the recipe schema, never from a second hard-coded set;
/// - the editable fields are the three controls (`start`, `liftStops`, `transition`) plus
///   `hdr.headroomCap`; the cap is stored linearly like the wire field and the UI presents it in
///   stops (docs/reference/client.md, control model);
/// - posting changes **only** `hdr` and `created`; `source` (including the provenance-only path,
///   the sha256 and the authored width/height), `base`, `encoder`, `versions` and `schema` are
///   preserved byte-for-byte;
/// - the recipe is validated locally before it is returned/POSTed.
///
/// A 409 `source_changed` response is not handled here: the UI owns re-prepare/re-judge
/// (docs/reference/client.md, state and errors); this type only guarantees that a draft can never silently alter the identity
/// of the source it was authored for.
public struct RecipeDraft: Equatable, Sendable {
    /// Control ranges from the recipe schema (docs/reference/client.md, control model).
    public static let startRange: ClosedRange<Double> = 0...1
    public static let liftStopsRange: ClosedRange<Double> = 0...4
    public static let transitionRange: ClosedRange<Double> = 0.001...1
    public static let headroomCapRange: ClosedRange<Double> = 1...8

    /// The `PreviewMetadata.recipeDefaults` this draft was built from. Never mutated.
    public let template: Recipe

    /// Mask threshold on linear Rec.709 luma; ride `Recipe.HDR.start`.
    public var start: Double
    /// Gain at full mask, in stops above SDR white; rides `Recipe.HDR.liftStops`.
    public var liftStops: Double
    /// Roll-off width above `start`; rides `Recipe.HDR.transition`.
    public var transition: Double
    /// Delivery ceiling as the schema's linear multiplier; rides `Recipe.HDR.headroomCap`.
    /// The UI edits `log2(headroomCap)` in stops, but the wire value stays linear.
    public var headroomCap: Double

    /// Builds a pristine draft from the server-provided defaults.
    public init(defaults: Recipe) {
        self.template = defaults
        self.start = defaults.hdr.start
        self.liftStops = defaults.hdr.liftStops
        self.transition = defaults.hdr.transition
        self.headroomCap = defaults.hdr.headroomCap
    }

    /// True when any editable field differs from the template it was built from.
    ///
    /// This is the "no POST yet" half of the editor baseline (docs/reference/client.md, state and errors "baseline = defaults or
    /// the last post"); after a POST the app compares the draft against the posted snapshot instead.
    public var isDirty: Bool {
        start != template.hdr.start
            || liftStops != template.hdr.liftStops
            || transition != template.hdr.transition
            || headroomCap != template.hdr.headroomCap
    }

    /// Builds the Recipe to POST: only `hdr` (three controls + cap) and `created`
    /// change; everything else is copied from the template, then the whole recipe is validated.
    ///
    /// - Parameter created: RFC 3339 timestamp for the metadata-only `created` field.
    /// - Throws: `PhotonError.invalidRecipe` if the controls (or any preserved template field)
    ///   are outside the Recipe v0 contract.
    public func recipe(created: String = Recipe.currentTimestamp()) throws -> Recipe {
        let recipe = assembled(created: created)
        try recipe.validate()
        return recipe
    }

    /// Validates the current draft without building a recipe the caller keeps.
    ///
    /// - Throws: `PhotonError.invalidRecipe` with the offending field and reason.
    public func validate() throws {
        try assembled(created: template.created).validate()
    }

    /// The recipe with the current controls, *before* validation, so `recipe(created:)` can call
    /// `validate()` itself and `validate()` need not recurse.
    private func assembled(created: String) -> Recipe {
        Recipe(
            schema: template.schema,
            source: template.source,
            base: template.base,
            hdr: Recipe.HDR(
                start: start,
                liftStops: liftStops,
                transition: transition,
                headroomCap: headroomCap
            ),
            encoder: template.encoder,
            versions: template.versions,
            created: created
        )
    }
}
