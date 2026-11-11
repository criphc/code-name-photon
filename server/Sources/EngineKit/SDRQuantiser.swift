import Foundation

/// Shared 16-bit Display P3 quantisation for the SDR base.
///
/// Both the 16-bit TIFF base (M1 pipeline / M4 delivery) and the 16-bit PNG base sent to the iPad
/// must encode linear P3 exactly the same way, so the transfer function lives here once.
public enum SDRQuantiser {
    /// Display P3's transfer function (the sRGB piecewise curve) applied to one linear sample,
    /// quantised to 16 bits. Values outside 0…1 cannot be represented and are clamped.
    ///
    /// Since P1-4 the decoder accepts Display P3 sources only (`SourceDecoder` refuses Adobe RGB /
    /// sRGB / untagged instead of feeding them through here), so this clamp is a format guard, not
    /// a gamut policy: the trial Capture One P3 export decodes to exactly 0.0…1.0 in linear P3, so
    /// the clamp does not fire in normal operation. It only pins a sub-LSB ColorSync overshoot or a
    /// generated/intermediate buffer the pipeline passes in — never a non-P3 primary that would
    /// otherwise lose its colour silently.
    ///
    /// `@_transparent` forces inlining even in the debug builds the pipeline runs as; `pow` itself
    /// remains the libm call, so this is still the canonical definition of the transfer curve.
    @_transparent
    public static func encoded16(_ linear: Float) -> UInt16 {
        let clamped = min(max(Double(linear), 0.0), 1.0)
        let encoded: Double
        if clamped <= 0.0031308 {
            encoded = 12.92 * clamped
        } else {
            encoded = 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }
        let quantised = (min(max(encoded, 0.0), 1.0) * 65535.0).rounded()
        return UInt16(quantised)
    }

    /// Packed 3-channel RGB 16-bit samples (row-major) for a linear-P3 image, alpha dropped.
    ///
    /// Unsafe-buffer loop: a plain array loop costs several seconds per full image in a debug
    /// build; this keeps the same scalar `Double` maths and is bit-identical to `encoded16` per
    /// sample.
    public static func encodedSamples(_ image: LinearImage) -> [UInt16] {
        let source = image.pixels
        var encoded = [UInt16](repeating: 0, count: image.size.pixelCount * 3)
        source.withUnsafeBufferPointer { sourceBuffer in
            encoded.withUnsafeMutableBufferPointer { destinationBuffer in
                var sourceIndex = 0
                var destinationIndex = 0
                while sourceIndex < sourceBuffer.count {
                    destinationBuffer[destinationIndex] = encoded16(sourceBuffer[sourceIndex])
                    destinationBuffer[destinationIndex + 1] = encoded16(sourceBuffer[sourceIndex + 1])
                    destinationBuffer[destinationIndex + 2] = encoded16(sourceBuffer[sourceIndex + 2])
                    sourceIndex += 4
                    destinationIndex += 3
                }
            }
        }
        return encoded
    }
}
