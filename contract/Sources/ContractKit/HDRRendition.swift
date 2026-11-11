import Foundation

/// Builds the authored HDR rendition from the SDR base and the highlight shape.
public enum HDRRendition {
    /// The rendered HDR image plus the numbers the metadata/verification need.
    public struct Result: Sendable {
        public let image: LinearImage
        /// Largest R/G/B sample in linear light; should sit at `shape.headroomCap` when any
        /// pixel reached the cap.
        public let authoredPeak: Float
        /// Fraction of pixels whose largest channel is above 1.0.
        public let fractionAboveOne: Double
        /// Fraction of pixels whose largest channel sits at the cap.
        public let fractionAtCap: Double

        public init(image: LinearImage, authoredPeak: Float, fractionAboveOne: Double, fractionAtCap: Double) {
            self.image = image
            self.authoredPeak = authoredPeak
            self.fractionAboveOne = fractionAboveOne
            self.fractionAtCap = fractionAtCap
        }
    }

    /// Tolerance used by `fractionAtCap`: a sample this close to the cap counts as "at cap".
    /// M0's renderer used the same `cap - 1e-6` test
    /// (docs/archive/stage-1/05-encoder-verification.md §3.2) and it keeps the statistic
    /// meaningful after the Float32 multiply, without counting values that are merely near the
    /// cap after the lift.
    public static let atCapTolerance: Float = 1e-6

    /// `hdr = base * 2^(lift * mask(Rec.709 luma))`, each channel clamped to `headroomCap`.
    ///
    /// No clipping below the cap (values 1.0…cap are kept exactly), alpha copied, no NaN.
    /// - Throws: `PhotonError.invalidImage` if the base contains a non-finite sample (a malformed
    ///   base must never be rescued by the cap) or if the lift overflows to a non-finite sample.
    ///
    /// Statistics (all per *pixel*, using the pixel's largest R/G/B sample):
    /// - `authoredPeak` = max over all R/G/B samples of the rendered rendition;
    /// - `fractionAboveOne` counts pixels with `max(r,g,b) > 1.0` — strictly above SDR white;
    /// - `fractionAtCap` counts pixels with `max(r,g,b) >= headroomCap - 1e-6` — i.e. pixels
    ///   whose brightest channel is the cap (the clamp engaged, or landed within 1e-6 of it).
    ///
    /// Performance: one pass, no per-pixel `RGBA` construction and no intermediate collections.
    /// Measured: a 6000×4000 (24 Mpx) Float32 buffer renders in 0.23 s in a release build.
    public static func render(base: LinearImage, shape: HighlightShape) throws -> Result {
        let sampleCount = base.pixels.count
        var output = [Float](repeating: 0, count: sampleCount)

        let start = shape.start
        let transition = shape.transition
        let top = start + transition
        let liftStops = shape.liftStops
        let cap = shape.headroomCap
        let capThreshold = cap - atCapTolerance

        var authoredPeak: Float = 0
        var pixelsAboveOne = 0
        var pixelsAtCap = 0
        var containsNonFinite = false

        base.pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var index = 0
                while index < sampleCount {
                    let r = source[index]
                    let g = source[index + 1]
                    let b = source[index + 2]
                    let alpha = source[index + 3]

                    // A base buffer holding NaN/∞ is a decode bug, not an image: refuse it
                    // instead of letting the cap silently turn an ∞ sample into a plausible 2.5.
                    if !(r.isFinite && g.isFinite && b.isFinite && alpha.isFinite) {
                        containsNonFinite = true
                        return
                    }

                    // Same expression as `RGBA.rec709Luma`, inlined to keep this loop free of
                    // per-pixel value construction. One luma, therefore one gain for R/G/B.
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                    let mask: Float
                    if luma <= start {
                        mask = 0
                    } else if luma >= top {
                        mask = 1
                    } else {
                        let t = (luma - start) / transition
                        mask = t * t * (3 - 2 * t)
                    }
                    // mask == 0 ⇒ gain is exactly 1 (no libm call, so `base` passes through
                    // untouched below the threshold).
                    let gain = mask == 0 ? 1 : exp2(liftStops * mask)

                    var hr = r * gain
                    var hg = g * gain
                    var hb = b * gain
                    if hr > cap {
                        hr = cap
                    }
                    if hg > cap {
                        hg = cap
                    }
                    if hb > cap {
                        hb = cap
                    }

                    if !(hr.isFinite && hg.isFinite && hb.isFinite && alpha.isFinite) {
                        containsNonFinite = true
                        return
                    }

                    destination[index] = hr
                    destination[index + 1] = hg
                    destination[index + 2] = hb
                    destination[index + 3] = alpha

                    let pixelPeak = max(hr, max(hg, hb))
                    if pixelPeak > authoredPeak { authoredPeak = pixelPeak }
                    if pixelPeak > 1.0 { pixelsAboveOne += 1 }
                    if pixelPeak >= capThreshold { pixelsAtCap += 1 }

                    index += 4
                }
            }
        }

        if containsNonFinite {
            throw PhotonError.invalidImage(reason: "HDR rendition received or produced a non-finite sample")
        }

        let image = try LinearImage(size: base.size, pixels: output)
        let pixelCount = base.size.pixelCount
        guard pixelCount > 0 else {
            return Result(image: image, authoredPeak: authoredPeak, fractionAboveOne: 0, fractionAtCap: 0)
        }
        let scale = 1.0 / Double(pixelCount)
        return Result(
            image: image,
            authoredPeak: authoredPeak,
            fractionAboveOne: Double(pixelsAboveOne) * scale,
            fractionAtCap: Double(pixelsAtCap) * scale
        )
    }
}
