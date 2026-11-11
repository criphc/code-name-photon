import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the two intermediate images the encoder consumes.
///
/// M0 measured two hard requirements that live here:
/// - the SDR base is a 16-bit Display P3 TIFF with **3 samples, no alpha** (the tool reuses it verbatim);
/// - the HDR input must be a **4-channel `RGBAf`** float TIFF in linear extended Display P3 —
///   a 3-channel float TIFF is silently misread by ImageIO/Core Image, and the tool then exits 0
///   with a wrong gain map.
public enum TIFFWriter {
    /// 16-bit, ICC Display P3, 3 samples, no alpha, orientation 1. The image carries linear values
    /// and the writer applies the P3 transfer when encoding.
    ///
    /// The 16-bit Display P3 encoding only has room for 0…1, so samples outside that range are
    /// clamped by the format itself — this is the one place Stage 1 has to quantise/clamp, and it
    /// only affects the SDR *deliverable*, never the working buffer or the HDR rendition. (For the
    /// supported sources, a Capture One P3 export decoded back into P3, values are in range; a
    /// small ColorSync overshoot at the very top is pinned to white rather than wrapped.)
    ///
    /// The sample layout comes from `SDRBaseCGImage`, shared with the M2.1 PNG writer (P1-11);
    /// `SDRQuantiser` owns the transfer + quantisation. Neither writer may grow its own copy.
    public static func writeSDRBase(_ image: LinearImage, to url: URL) throws {
        let cgImage = try SDRBaseCGImage.make(from: image)
        try writeTIFF(cgImage, to: url)
    }

    /// 32-bit float, 4 samples, extended linear Display P3 ("Display P3 Linear" ICC),
    /// values above 1.0 preserved exactly, alpha 1.0.
    ///
    /// The route is the one M0 verified as the *only* float TIFF route ImageIO/Core Image reads
    /// back correctly: `CIContext.writeTIFFRepresentation(.RGBAf, extendedLinearDisplayP3)`.
    /// It writes 4 channels plus the "Display P3 Linear" ICC profile, and round-trips values
    /// exactly (a 3-channel float TIFF is silently misread, docs/reference/encoder.md).
    ///
    /// The `CIImage` comes from `ImageBuffers`, the shared provider-backed ownership chain, so the
    /// float pixels outlive the write and no extra full-frame copy is made (review P1-3: this used
    /// to be the last bitmap-data call in the package, the pattern docs/reference/encoder.md forbids).
    public static func writeHDR(_ image: LinearImage, to url: URL) throws {
        guard SampleMath.allFinite(image.pixels) else {
            throw PhotonError.invalidImage(reason: "cannot write a TIFF with NaN or infinite samples")
        }
        guard image.size.width > 0, image.size.height > 0 else {
            throw PhotonError.invalidImage(reason: "cannot write a zero-sized TIFF (\(image.size))")
        }
        let ciImage = try ImageBuffers.ciImage(image)
        let context = CIContext(options: [
            .workingColorSpace: ImageBuffers.linearP3,
            .outputColorSpace: ImageBuffers.linearP3,
            .cacheIntermediates: false,
        ])
        do {
            try context.writeTIFFRepresentation(
                of: ciImage,
                to: url,
                format: .RGBAf,
                colorSpace: ImageBuffers.linearP3,
                options: [:]
            )
        } catch {
            throw PhotonError.writeFailed(path: url.path, reason: "CIContext float TIFF write failed: \(error)")
        }
    }

    // MARK: - Helpers

    /// One-image TIFF via `CGImageDestination`, explicit orientation 1, no alpha (the CGImage
    /// decides the sample layout). Deterministic: the same CGImage writes identical bytes.
    private static func writeTIFF(_ cgImage: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot create a TIFF destination")
        }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotonError.writeFailed(path: url.path, reason: "TIFF destination finalize failed")
        }
    }
}
