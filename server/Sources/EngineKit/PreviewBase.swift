import Foundation

/// The 16-bit PNG SDR base that M2 sends to the iPad.
public struct PreviewBase: Sendable {
    public let url: URL
    public let size: PixelSize
    public let bytes: Int
    public let sha256: String
    /// Wire format tag, e.g. `png-16-p3`.
    public let format: String
    public let profileName: String?

    public init(url: URL, size: PixelSize, bytes: Int, sha256: String, format: String, profileName: String?) {
        self.url = url
        self.size = size
        self.bytes = bytes
        self.sha256 = sha256
        self.format = format
        self.profileName = profileName
    }
}

/// Outcome of preparing an item's preview base (M2's only render).
public struct PreviewBaseResult: Sendable {
    public let sourceURL: URL
    public let sourceSHA256: String
    public let sourceSize: PixelSize
    public let profileName: String?
    public let bitsPerComponent: Int
    public let base: PreviewBase
    /// M3's shader must linearise the PNG before applying the mask/gain; recorded for the contract.
    public let workingSpace: String
    public let longEdge: Int

    public init(
        sourceURL: URL,
        sourceSHA256: String,
        sourceSize: PixelSize,
        profileName: String?,
        bitsPerComponent: Int,
        base: PreviewBase,
        workingSpace: String,
        longEdge: Int
    ) {
        self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256
        self.sourceSize = sourceSize
        self.profileName = profileName
        self.bitsPerComponent = bitsPerComponent
        self.base = base
        self.workingSpace = workingSpace
        self.longEdge = longEdge
    }
}

/// Builds the SDR base preview: decode → linear P3 → identity SDR base → Lanczos downscale →
/// 16-bit Display P3 PNG.
///
/// This is deliberately **not** the M1 pipeline: M2 transports the base and the iPad authors HDR
/// (docs/reference/wire.md, M2.1 wire contract), so the default-recipe HDR rendition + gain-map HEIC are a development
/// artifact produced by `appctl prep`, never by `appctl serve`.
public enum PreviewBaseRenderer {
    public static let fileName = "preview-base.png"
    public static let format = "png-16-p3"
    public static let workingSpace = "linear-extended-DisplayP3-float32"
    public static let profileName = "Display P3"

    /// Renders `preview-base.png` into `outputDirectory` (created if needed) and returns its facts.
    ///
    /// The PNG is written to a sibling temp file and `rename(2)`-ed over the final name
    /// (`AtomicFile.replace`, review P1-7), so a concurrent reader (the iPad downloading the base,
    /// or `ItemStore` preparing the same item) never sees a half-written PNG. A re-render replaces
    /// the old file in one step; `base.url` is always the final `preview-base.png`, and
    /// `base.bytes`/`base.sha256` are measured on that final file.
    ///
    /// - Parameters:
    ///   - sourceURL: the Capture One export (SDR, orientation 1, ICC profile).
    ///   - longEdge: target long edge; never upscales.
    ///   - outputDirectory: usually `work/<source sha256>/`.
    public static func render(
        sourceURL: URL,
        longEdge: Int = 2560,
        to outputDirectory: URL,
        toneMap: ToneMapKind = .c1MatchV1
    ) throws -> PreviewBaseResult {
        guard longEdge > 0 else {
            throw PhotonError.invalidImage(reason: "preview long edge must be positive, got \(longEdge)")
        }
        let decoded = try SourceDecoder.decode(url: sourceURL)
        let base = try ToneMapper.sdrBase(from: decoded.linear, toneMap: toneMap)
        let scaled = try PreviewRenderer.downscaleBase(base, longEdge: longEdge)

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw PhotonError.writeFailed(
                path: outputDirectory.path,
                reason: "cannot create the preview directory: \(error)"
            )
        }
        let url = outputDirectory.appendingPathComponent(fileName)
        try writeAtomically(scaled, to: url)

        let bytes: Int
        do {
            bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
        } catch {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot stat the written PNG: \(error)")
        }
        let sha256 = try SourceDecoder.sha256(ofFileAt: url)
        let baseInfo = PreviewBase(
            url: url,
            size: scaled.size,
            bytes: bytes,
            sha256: sha256,
            format: format,
            profileName: Self.profileName
        )
        return PreviewBaseResult(
            sourceURL: decoded.url,
            sourceSHA256: decoded.sha256,
            sourceSize: decoded.size,
            profileName: decoded.profileName,
            bitsPerComponent: decoded.bitsPerComponent,
            base: baseInfo,
            workingSpace: workingSpace,
            longEdge: longEdge
        )
    }

    /// Writes the PNG into a sibling temporary file, then renames it over `preview-base.png`
    /// (`AtomicFile.replace`, docs/reference/operations.md "write temp + atomic rename"). The temp file is hidden and
    /// carries the final `.tmp` suffix; it is in the same directory, so the rename is same-volume
    /// and replaces any previous base in one step. Any failure removes the temp file (review P1-7).
    private static func writeAtomically(_ image: LinearImage, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString).png.tmp")
        do {
            try PNGWriter.writeSDRBase(image, to: temporary)
            try AtomicFile.replace(temporary, with: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let photonError = error as? PhotonError { throw photonError }
            throw PhotonError.writeFailed(path: url.path, reason: "cannot write \(fileName): \(error)")
        }
    }
}
