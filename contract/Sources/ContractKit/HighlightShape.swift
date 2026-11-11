import Foundation

/// The three creative controls plus the delivery cap, as pure maths.
///
/// Semantics (binding, from docs/reference/recipe.md, maths):
/// - `mask(luma) = smoothstep(start, start + transition, luma)`, where `luma` is the Rec.709
///   luma of the linear working buffer (`RGBA.rec709Luma`);
/// - `gain(luma) = 2^(liftStops * mask(luma))`, the same gain for all three channels;
/// - the resulting HDR pixel is `base * gain`, then each channel is clamped to `headroomCap`.
/// The SDR base is never modified by any of this.
public struct HighlightShape: Equatable, Sendable {
    public let start: Float
    public let liftStops: Float
    public let transition: Float
    public let headroomCap: Float

    /// Validates the ranges from docs/reference/recipe.md (start 0…1, liftStops 0…4, transition 0.001…1, cap 1…8).
    public init(start: Float, liftStops: Float, transition: Float, headroomCap: Float) throws {
        try Self.validate(start, in: 0...1, field: "hdr.start")
        try Self.validate(liftStops, in: 0...4, field: "hdr.lift_stops")
        try Self.validate(transition, in: 0.001...1, field: "hdr.transition")
        try Self.validate(headroomCap, in: 1...8, field: "hdr.headroom_cap")
        self.start = start
        self.liftStops = liftStops
        self.transition = transition
        self.headroomCap = headroomCap
    }

    /// Convenience initializer from the validated recipe fields.
    public init(recipe: Recipe.HDR) throws {
        try self.init(
            start: Float(recipe.start),
            liftStops: Float(recipe.liftStops),
            transition: Float(recipe.transition),
            headroomCap: Float(recipe.headroomCap)
        )
    }

    /// 0 below `start`, 1 at/above `start + transition`, C¹ smoothstep in between.
    ///
    /// `t = clamp((luma - start) / transition, 0, 1)`, `mask = t²(3 - 2t)`.
    /// The curve meets 0 at `start` with zero slope and 1 at `start + transition` with zero
    /// slope, so there is no visible seam at either end of the roll-off.
    ///
    /// Defensive on silly inputs — the function never returns NaN and never returns a value
    /// outside 0…1:
    /// - NaN and negative luma are "below any threshold" ⇒ 0 (`start >= 0` is validated);
    /// - `+infinity` is "above any threshold" ⇒ 1;
    /// - luma beyond `start + transition` is 1.
    @inline(__always)
    public func mask(luma: Float) -> Float {
        guard luma.isFinite else { return luma > 0 ? 1 : 0 } // NaN > 0 is false ⇒ 0
        if luma <= start { return 0 }
        let top = start + transition
        if luma >= top { return 1 }
        let t = (luma - start) / transition
        return t * t * (3 - 2 * t)
    }

    /// `2^(liftStops * mask(luma))`; exactly 1.0 where the mask is 0.
    ///
    /// Monotone non-decreasing in `luma`, finite for every finite luma (the lift is validated to
    /// 0…4 stops and the mask to 0…1, so the gain is always in 1…16).
    @inline(__always)
    public func gain(luma: Float) -> Float {
        let mask = mask(luma: luma)
        if mask == 0 { return 1 }
        return exp2(liftStops * mask)
    }

    // MARK: - Helpers

    private static func validate(_ value: Float, in range: ClosedRange<Float>, field: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw PhotonError.invalidRecipe(
                field: field,
                reason: "must be in \(range.lowerBound)...\(range.upperBound), got \(value)"
            )
        }
    }
}
