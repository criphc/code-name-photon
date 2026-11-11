import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the 16-bit Display P3 PNG that M2 sends to the iPad as the judging base.
///
/// Why PNG and not the gain-map HEIC: the iPad applies Start HDR / Highlight lift / Transition in
/// its own shader, so it needs the *SDR base*, not a rendition with one recipe baked in. 16-bit
/// P3 keeps the base's precision and embeds the ICC profile (verified: ImageIO writes iCCP and
/// ImageIO reads the profile back as "Display P3"); 8-bit HEIC would be 30× smaller but would fold
/// the HDR maths into 8-bit quantisation.
public enum PNGWriter {
    /// 16-bit RGB, no alpha, ICC Display P3. Input is linear extended Display P3 float32.
    ///
    /// The sample layout comes from `SDRBaseCGImage`, shared with the M1/M4 16-bit TIFF base
    /// (P1-11): `SDRQuantiser` owns the transfer + quantisation, `SDRBaseCGImage` owns the CGImage
    /// assembly, so the PNG sent to the iPad and the delivered TIFF cannot drift apart.
    public static func writeSDRBase(_ image: LinearImage, to url: URL) throws {
        let cgImage = try SDRBaseCGImage.make(from: image)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot create a PNG destination")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotonError.writeFailed(path: url.path, reason: "PNG encode failed")
        }
    }
}
