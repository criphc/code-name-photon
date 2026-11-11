import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

/// A decoded source image, already converted into the Stage-1 working space.
///
/// M0 established the contract this type embodies: convert the embedded ICC profile into
/// **linear extended Display P3, float32, no clipping**, and require orientation 1.
/// The source itself is SDR (Capture One export): values are expected in 0…1.
///
/// The source must be a **Display P3** SDR export: `SourceDecoder` refuses any other embedded
/// profile (Adobe RGB, sRGB, untagged) instead of colour-managing it into P3 and letting the
/// 16-bit base clamp whatever fell outside the P3 gamut (review P1-4, docs/reference/colour.md).
/// Because the profile is now part of the input contract, this buffer is never asked to represent
/// a colour the delivered SDR base cannot carry.
public struct DecodedSource: Sendable {
    public let url: URL
    public let size: PixelSize
    /// Embedded profile name as ImageIO reports it (e.g. "Display P3"), for meta.json and error
    /// messages. Display-only: the colour contract is checked against the decoded `CGImage`'s
    /// colour space, not this string.
    public let profileName: String?
    public let bitsPerComponent: Int
    /// Lowercase hex SHA-256 of the file bytes (the source identity used by recipes/caches).
    public let sha256: String
    public let linear: LinearImage

    public init(url: URL, size: PixelSize, profileName: String?, bitsPerComponent: Int, sha256: String, linear: LinearImage) {
        self.url = url
        self.size = size
        self.profileName = profileName
        self.bitsPerComponent = bitsPerComponent
        self.sha256 = sha256
        self.linear = linear
    }
}

/// Decodes a Capture One **Display P3** SDR TIFF (16-bit) into the linear P3 working buffer.
///
/// Stage 1 accepts Display P3 sources only (docs/reference/colour.md, review P1-4): the `-P3` Capture
/// One export is the input, and a source tagged with any other profile — Adobe RGB (1998), sRGB,
/// untagged, or a linear variant — is refused with `PhotonError.unsupportedSource` rather than
/// colour-managed into P3. The Adobe RGB export is rejected deliberately: its saturated green is
/// outside P3 (linear P3 r ≈ −0.15), so the 16-bit SDR base would silently clamp it to 0 and change
/// the authoritative Capture One look with no warning. The fix is a Display P3 re-export, so the
/// error says exactly that.
public enum SourceDecoder {
    /// Reads `url` through ImageIO, validates the Display P3 source contract, applies the embedded
    /// ICC profile, and returns linear extended Display P3 float32 RGBA with alpha = 1.
    ///
    /// Requirements: an embedded **Display P3** profile (else `PhotonError.unsupportedSource`);
    /// orientation 1 (else `PhotonError.unsupportedOrientation`); alpha is tolerated on input but
    /// flattened. Decoding itself does NOT clip — the ICC render into `extendedLinearDisplayP3` is
    /// allowed to produce values outside 0…1, and the trial Capture One P3 export decodes to exactly
    /// 0.0…1.0 (the 16-bit base write is where clamping belongs). The decode must be deterministic
    /// for one file on one machine.
    public static func decode(url: URL) throws -> DecodedSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotonError.sourceUnreadable(
                path: url.path,
                reason: "ImageIO cannot open the file (missing, or not a recognised image)"
            )
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        // Stage 1 requires an unrotated export: a rotated source must be fixed in Capture One.
        // (ImageIO reports the TIFF/EXIF orientation here; the decoded CGImage is not rotated.)
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            throw PhotonError.unsupportedOrientation(orientation)
        }

        let profileName = properties[kCGImagePropertyProfileName] as? String

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotonError.sourceUnreadable(path: url.path, reason: "ImageIO could not decode the image data")
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw PhotonError.unsupportedSource(reason: "decoded image has zero size (\(width)x\(height))")
        }
        let size = PixelSize(width: width, height: height)

        // Stage-1 colour contract (review P1-4, docs/reference/colour.md): only Display P3 sources are
        // colour-managed into the working space. Checked BEFORE the render so a non-P3 export is a
        // clear error, never a silently clamped base.
        try validateDisplayP3Source(cgImage: cgImage, profileName: profileName, url: url)

        // Colour-manage the embedded ICC profile into linear extended Display P3, float32 RGBA.
        // This is the route M0 verified (0.12 s for 6000x4000): ImageIO CGImage -> CIImage ->
        // CIContext render to `.RGBAf` in `extendedLinearDisplayP3`, no clipping by the renderer.
        let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIRender.sharedContext
        let ciImage = CIImage(cgImage: cgImage)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        // Checked render: a fresh GPU context can silently leave the destination zeroed
        // (docs/plans/preview-agreement-investigation.md); `CIRender` waits and throws instead.
        try CIRender.render(
            ciImage,
            toBitmap: &pixels,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf,
            colorSpace: linearP3,
            context: context
        )

        // Stage 1 works opaque: alpha is tolerated on input but forced to 1.0 here so every
        // later stage can rely on it (docs/reference/deliver.md, report schema 1: the deliverable carries no alpha).
        // Capture One exports have no alpha; for a hypothetical alpha source the RGB samples are
        // taken as decoded and the alpha channel is dropped rather than composited.
        // (Unsafe-buffer loop: a plain array loop costs ~1 s per full image in a debug build.)
        pixels.withUnsafeMutableBufferPointer { buffer in
            var index = 3
            while index < buffer.count {
                buffer[index] = 1.0
                index += 4
            }
        }

        let linear = try LinearImage(size: size, pixels: pixels)
        guard SampleMath.allFinite(linear.pixels) else {
            throw PhotonError.invalidImage(reason: "decoder produced non-finite samples for \(url.lastPathComponent)")
        }

        return DecodedSource(
            url: url,
            size: size,
            profileName: profileName,
            bitsPerComponent: cgImage.bitsPerComponent,
            sha256: try sha256(ofFileAt: url),
            linear: linear
        )
    }

    /// Enforces the Stage-1 colour contract: the decoded source must be tagged Display P3.
    ///
    /// The check is on the **decoded** colour space (`cgImage.colorSpace`), because that is the
    /// space the colour-managed render below actually uses. `kCGImagePropertyProfileName` is
    /// display-only — it can be missing (untagged) or a vendor description — so it is used only to
    /// name the offending profile in the error. Capture One's `-P3` exports resolve to
    /// `kCGColorSpaceDisplayP3` (verified on the three trial sources), and so does a 16-bit
    /// Display P3 TIFF written by this package.
    ///
    /// Rejection is the user decision for P1-4: converting Adobe RGB / sRGB into the working space
    /// would clamp the out-of-gamut part (Adobe RGB's saturated green lands at linear P3 r ≈ −0.15)
    /// and silently alter the authoritative SDR base. The error tells the user how to fix it.
    static func validateDisplayP3Source(cgImage: CGImage, profileName: String?, url: URL) throws {
        let displayP3Name = CGColorSpace(name: CGColorSpace.displayP3)?.name as String?
        let decodedName = cgImage.colorSpace?.name as String?
        guard let displayP3Name, decodedName == displayP3Name else {
            let exported = profileName ?? "none (untagged)"
            throw PhotonError.unsupportedSource(
                reason: "'\(url.lastPathComponent)' has embedded colour profile '\(exported)', "
                    + "which is not Display P3; export the SDR base as Display P3 from Capture One "
                    + "(docs/08 §4)"
            )
        }
    }

    /// Streaming SHA-256 of the file bytes, lowercase hex. Used for the recipe source identity.
    ///
    /// Sources are ~150 MB, so the file is hashed in 8 MB chunks rather than loaded into memory.
    public static func sha256(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw PhotonError.sourceUnreadable(path: url.path, reason: "cannot open the file for hashing")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw PhotonError.sourceUnreadable(path: url.path, reason: "read failed while hashing: \(error)")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
