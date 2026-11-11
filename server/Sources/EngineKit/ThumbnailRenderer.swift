import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Facts about a rendered filmstrip thumbnail.
public struct ThumbnailResult: Sendable {
    /// The final `thumbnail-<height>-<tag>.heic` on disk.
    public let url: URL
    /// The size ImageIO actually produced (aspect ratio preserved, height = `ThumbnailRenderer.height`
    /// for any source at least that tall).
    public let size: PixelSize
    public let bytes: Int
    /// Lowercase hex SHA-256 of the HEIC bytes.
    public let sha256: String
    /// Wire format tag, e.g. `heic-10-p3`.
    public let format: String

    public init(url: URL, size: PixelSize, bytes: Int, sha256: String, format: String) {
        self.url = url
        self.size = size
        self.bytes = bytes
        self.sha256 = sha256
        self.format = format
    }
}

/// Builds the 512-high Display P3 HEIC the iPad's filmstrip shows (ADR-0013).
///
/// Deliberately **not** `PreviewBaseRenderer`: browsing needs 512 px of display data, judging needs
/// the 2560 px 16-bit base, and the two have no reason to share a path. This renderer is ImageIO
/// only — `CGImageSourceCreateThumbnailAtIndex` decodes at the target size and `CGImageDestination`
/// writes HEIC — because the cost of the Core Image route is the full-size decode, and the project
/// has already been burned once by a GPU render that silently skipped its destination buffer
/// (docs/decisions/0013-thumbnail-api.md "为什么不走 Core Image").
///
/// Sizing is **by height**, not by long edge: `maxPixelSize = ceil(512 * max(1, width / height))`,
/// so a 3:2 landscape comes out 768×512 instead of 512×341. That matches the client's
/// `ThumbnailCache.maxPixelHeight`. A panorama is capped at `maximumPixelSize` wide: the old path
/// (downscaling the 2560 px preview base) could never produce more than 2560 px of width, so the
/// cap keeps that behaviour instead of letting a 20:1 source become a 10240-wide HEIC.
///
/// The source contract is the same as the decoder's: orientation 1 and a Display P3 profile, both
/// checked from the image properties / the thumbnail's colour space **before** anything is written.
/// A source smaller than 512 px tall is not upscaled (ImageIO treats the size as a maximum), so its
/// thumbnail is smaller than 512 — real Capture One exports are far larger.
public enum ThumbnailRenderer {
    /// Target height in pixels. Also part of the file name, so changing it invalidates every cache.
    public static let height = 512
    /// Bump when the rendering itself changes (filter, quality, sizing): the file name carries it.
    public static let rendererTag = "v1"
    /// Wire format tag for the HEIC (10-bit base + Display P3, as ImageIO writes it).
    public static let format = "heic-10-p3"
    /// `kCGImageDestinationLossyCompressionQuality`.
    public static let quality = 0.8
    /// Widest thumbnail this renderer will produce. The old path (downscaling the 2560 px preview
    /// base) physically could not exceed 2560 px, so a panorama keeps that bound instead of
    /// producing a 10240-wide HEIC.
    static let maximumPixelSize = 2560

    /// `thumbnail-512-v1.heic` — height and renderer tag are the cache key's file-name half.
    public static func fileName(height: Int = height) -> String {
        "thumbnail-\(height)-\(rendererTag).heic"
    }

    /// Renders `sourceURL` into `outputDirectory` (created if needed) and returns the HEIC's facts.
    ///
    /// Validation happens before the write: a rotated or non-P3 source throws and leaves no file
    /// behind. The HEIC is written to a sibling temp file and `rename(2)`-ed over the final name
    /// (`AtomicFile.replace`), so a concurrent reader never sees a partial thumbnail
    /// (docs/reference/operations.md "write temp + atomic rename").
    public static func render(sourceURL: URL, to outputDirectory: URL) throws -> ThumbnailResult {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw PhotonError.sourceUnreadable(
                path: sourceURL.path,
                reason: "ImageIO cannot open the file (missing, or not a recognised image)"
            )
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw PhotonError.sourceUnreadable(
                path: sourceURL.path,
                reason: "ImageIO cannot read the image properties (not a recognised image)"
            )
        }

        // Same contract as the decoder: a rotated source must be fixed at export, and the thumbnail
        // is never rotated (kCGImageSourceCreateThumbnailWithTransform is off below).
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
           orientation != 1 {
            throw PhotonError.unsupportedOrientation(orientation)
        }
        guard let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0
        else {
            throw PhotonError.unsupportedSource(
                reason: "'\(sourceURL.lastPathComponent)' has no usable pixel dimensions"
            )
        }

        // Height first: a 3:2 landscape must be 768×512, not 512×341. The width cap keeps a
        // panorama from turning into an enormous HEIC (the old 2560 px base could never exceed it).
        let maxPixelSize = min(
            Int((Double(height) * max(1, Double(pixelWidth) / Double(pixelHeight))).rounded(.up)),
            maximumPixelSize
        )
        let thumbnailOptions: [CFString: Any] = [
            // Always downsample from the full image: an embedded EXIF thumbnail is not the source.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // The source contract is orientation 1, so no rotation is applied (and none is wanted).
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw PhotonError.sourceUnreadable(
                path: sourceURL.path,
                reason: "ImageIO could not downsample the image"
            )
        }
        // Colour contract, checked on the thumbnail's own colour space before any bytes are written
        // (docs/reference/colour.md): a non-P3 export is refused, never colour-managed into P3.
        try SourceDecoder.validateDisplayP3Source(
            cgImage: thumbnail,
            profileName: properties[kCGImagePropertyProfileName] as? String,
            url: sourceURL
        )

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw PhotonError.writeFailed(
                path: outputDirectory.path,
                reason: "cannot create the thumbnail directory: \(error)"
            )
        }
        let url = outputDirectory.appendingPathComponent(fileName())
        try writeAtomically(thumbnail, to: url)

        let bytes: Int
        do {
            bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .intValue ?? -1
        } catch {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot stat the written HEIC: \(error)")
        }
        return ThumbnailResult(
            url: url,
            size: PixelSize(width: thumbnail.width, height: thumbnail.height),
            bytes: bytes,
            sha256: try SourceDecoder.sha256(ofFileAt: url),
            format: format
        )
    }

    /// Writes the HEIC into a sibling temp file, then renames it over the final name
    /// (`AtomicFile.replace`). Any failure removes the temp file.
    private static func writeAtomically(_ image: CGImage, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName()).\(UUID().uuidString).heic.tmp")
        do {
            guard let destination = CGImageDestinationCreateWithURL(
                temporary as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                throw PhotonError.writeFailed(
                    path: temporary.path,
                    reason: "cannot create a HEIC destination"
                )
            }
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality,
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw PhotonError.writeFailed(
                    path: temporary.path,
                    reason: "HEIC destination finalize failed"
                )
            }
            try AtomicFile.replace(temporary, with: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let photonError = error as? PhotonError { throw photonError }
            throw PhotonError.writeFailed(
                path: url.path,
                reason: "cannot write \(fileName()): \(error)"
            )
        }
    }
}
