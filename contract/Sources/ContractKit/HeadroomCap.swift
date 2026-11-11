import Foundation

/// The absolute linear clamp that is the *only* control of delivered headroom.
///
/// M0 measured that `-R` is inert in the `-b` encoder path and the advertised headroom follows
/// the authored peak (docs/reference/encoder.md): the cap must be applied to HDR pixels, not passed
/// to the tool. The same clamp is applied after Lanczos downscaling for the preview, because
/// Lanczos overshoots (M0 measured peaks above the cap on the 2560 px preview).
public enum HeadroomCap {
    /// Clamps every R/G/B sample to `cap`, keeps alpha, preserves every value that is <= cap.
    ///
    /// The operation is a pure upper clamp: there is no lower clamp (a negative sample stays
    /// negative), values at or below `cap` are returned bit-exactly, and clamping twice is
    /// identical to clamping once.
    ///
    /// - Parameter cap: linear headroom ceiling, `cap >= 1`. The *recipe* range is 1…8
    ///   (`Recipe.validate()`); this helper accepts anything `>= 1` because it is also used by
    ///   the preview path, which passes the recipe's cap through unchanged.
    /// - Throws: `PhotonError.invalidRecipe` (field `hdr.headroom_cap`) if `cap` is not finite or
    ///   below 1; `PhotonError.invalidImage` if the buffer contains a non-finite sample.
    public static func clamp(_ image: LinearImage, cap: Float) throws -> LinearImage {
        guard cap.isFinite, cap >= 1 else {
            throw PhotonError.invalidRecipe(
                field: "hdr.headroom_cap",
                reason: "must be a finite value >= 1 (recipe range 1...8), got \(cap)"
            )
        }

        // Copy-then-clamp in place: the copy also gives value semantics for the result.
        var samples = image.pixels
        var containsNonFinite = false
        samples.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let r = buffer[index]
                let g = buffer[index + 1]
                let b = buffer[index + 2]
                let a = buffer[index + 3]
                if !(r.isFinite && g.isFinite && b.isFinite && a.isFinite) {
                    containsNonFinite = true
                    return
                }
                if r > cap { buffer[index] = cap }
                if g > cap { buffer[index + 1] = cap }
                if b > cap { buffer[index + 2] = cap }
                // Alpha is never touched.
                index += 4
            }
        }
        if containsNonFinite {
            throw PhotonError.invalidImage(reason: "headroom clamp received a non-finite sample")
        }
        return try LinearImage(size: image.size, pixels: samples)
    }
}
