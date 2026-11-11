import Accelerate
import Foundation

/// The SDR tone map named by `recipe.base.tone_map`.
public enum ToneMapKind: Equatable, Sendable {
    /// `c1_match_v1` — identity pass-through: the Capture One export IS the SDR base.
    case c1MatchV1

    /// Resolves a recipe string to a supported tone map, or throws `PhotonError.invalidRecipe`.
    public static func named(_ name: String) throws -> ToneMapKind {
        switch name {
        case "c1_match_v1":
            return .c1MatchV1
        default:
            throw PhotonError.invalidRecipe(
                field: "base.tone_map",
                reason: "unknown tone map '\(name)' (stage 1 knows 'c1_match_v1')"
            )
        }
    }

    public var name: String {
        switch self {
        case .c1MatchV1: return "c1_match_v1"
        }
    }
}

/// Renders the authoritative SDR base from the decoded working buffer.
public enum ToneMapper {
    /// Returns the SDR base in the same linear extended Display P3 float32 space.
    ///
    /// For `.c1MatchV1` this is pixel-identical to the input (value-wise; a new buffer).
    /// Must not clip, must not alter colour, alpha stays 1.
    public static func sdrBase(from source: LinearImage, toneMap: ToneMapKind) throws -> LinearImage {
        guard SampleMath.allFinite(source.pixels) else {
            throw PhotonError.invalidImage(reason: "SDR base input contains NaN or infinite samples")
        }
        switch toneMap {
        case .c1MatchV1:
            // Identity: the Capture One export is the authoritative SDR rendition.
            // A fresh LinearImage (new buffer) keeps the value-semantics contract: callers may
            // mutate the result without touching the decoded source.
            return try LinearImage(size: source.size, pixels: source.pixels)
        }
    }
}

/// Shared sample-buffer validation, internal to EngineKit (used by the decoder, the tone mapper
/// and both TIFF writers).
///
/// This exists because the pipeline runs as a **debug** build (`swift run` / `swift test`), where
/// a per-element Swift `for` loop over a 6000x4000 RGBA buffer costs ~6 s; the vectorised check
/// below costs ~9 ms. Do not replace it with `LinearImage.isFinite` on a hot path.
internal enum SampleMath {
    /// True when every sample in the buffer is finite.
    ///
    /// `vDSP_svesq` sums the squares of the samples with IEEE arithmetic: NaN propagates as NaN and
    /// ±Infinity as +Infinity, so a finite sum proves every sample finite. Stage-1 samples are
    /// bounded (SDR ≤ ~1.2, authored HDR ≤ 4.0), so the sum cannot overflow for valid buffers.
    static func allFinite(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var sumOfSquares: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            vDSP_svesq(buffer.baseAddress!, 1, &sumOfSquares, vDSP_Length(buffer.count))
        }
        return sumOfSquares.isFinite
    }
}
