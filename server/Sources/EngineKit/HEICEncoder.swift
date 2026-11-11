import ContractKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// One encode request: the already-rendered SDR base and HDR rendition, the profile, the source
/// (for the EXIF/GPS/orientation rewrap) and the two output paths.
///
/// The pipeline builds the base/HDR once per item and calls the encoder once per profile; the
/// encoder never decodes the source or re-renders the grade.
public struct HEICEncodeRequest: Sendable {
    public let sdrBase: LinearImage
    public let hdrRendition: LinearImage
    public let authoredPeak: Float
    public let options: HEICEncodeOptions
    /// The source TIFF, read only for its EXIF/TIFF/GPS metadata; nil skips the rewrap.
    public let sourceURL: URL?
    public let hdrOutputURL: URL
    /// The shared 8-bit SDR fallback. `nil` for the profiles after the first: one fallback per
    /// delivery, written once.
    public let sdrOutputURL: URL?

    public init(
        sdrBase: LinearImage,
        hdrRendition: LinearImage,
        authoredPeak: Float,
        options: HEICEncodeOptions,
        sourceURL: URL?,
        hdrOutputURL: URL,
        sdrOutputURL: URL?
    ) {
        self.sdrBase = sdrBase
        self.hdrRendition = hdrRendition
        self.authoredPeak = authoredPeak
        self.options = options
        self.sourceURL = sourceURL
        self.hdrOutputURL = hdrOutputURL
        self.sdrOutputURL = sdrOutputURL
    }
}

/// What one profile produced. `facts` is the ImageIO read-back of the HDR file (the same
/// structural gate the external tool's output went through).
public struct HEICEncodeResult: Sendable {
    public let hdrHEIC: URL
    public let sdrHEIC: URL?
    public let facts: EncodedHEICFacts
    public let gainMapWidth: Int
    public let gainMapHeight: Int
    public let gainMapKind: HEICEncodeOptions.MapKind
    public let timings: Timings

    public struct Timings: Sendable {
        public let gainMapSeconds: Double
        public let encodeSeconds: Double
        public let rewrapSeconds: Double
        public let fallbackSeconds: Double
        public let totalSeconds: Double

        public init(
            gainMapSeconds: Double,
            encodeSeconds: Double,
            rewrapSeconds: Double,
            fallbackSeconds: Double,
            totalSeconds: Double
        ) {
            self.gainMapSeconds = gainMapSeconds
            self.encodeSeconds = encodeSeconds
            self.rewrapSeconds = rewrapSeconds
            self.fallbackSeconds = fallbackSeconds
            self.totalSeconds = totalSeconds
        }
    }
}

/// The writer's identity, recorded in `meta.json`'s `encoder` block: the tool family plus the
/// executable as it was selected (a file path for the external oracle, `coreimage` for the
/// in-process writer). `Pipeline` records what actually ran; it never hard-codes it.
public struct EncoderIdentity: Sendable, Equatable {
    public let tool: String
    public let executable: String

    public init(tool: String, executable: String) {
        self.tool = tool
        self.executable = executable
    }
}

/// The container writer. One implementation per engine generation; the delivery pipeline depends
/// on this protocol, not on `tools/toGainMapHDR`.
public protocol HEICEncoder: Sendable {
    var identity: EncoderIdentity { get }

    func encode(_ request: HEICEncodeRequest) throws -> HEICEncodeResult
}

/// Path A: `CIContext.writeHEIF10Representation` / `writeHEIFRepresentation` with
/// `.hdrGainMapImage` + `.hdrGainMapAsRGB`, then a `CGImageDestinationCopyImageSource` rewrap for
/// EXIF/GPS/orientation.
///
/// Measured 2026-11-09 (docs/plans/engine-spike-report.md): 10-bit and 8-bit bases, half/full
/// RGB/mono maps, ISO aux and correct headroom; the rewrap preserves the aux. Path B's raw-aux
/// `CGImageDestinationAddAuxiliaryDataInfo` failed finalize on macOS 27.
public struct CoreImageHEICEncoder: HEICEncoder {
    public init() {}

    public var identity: EncoderIdentity {
        EncoderIdentity(tool: Recipe.EncoderParams.coreImageToolName, executable: "coreimage")
    }

    public func encode(_ request: HEICEncodeRequest) throws -> HEICEncodeResult {
        let start = Date()
        let context = CIRender.sharedContext
        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

        let gainMapStart = Date()
        let gainMap = try GainMap.make(
            base: request.sdrBase,
            hdr: request.hdrRendition,
            resolution: request.options.mapResolution,
            authoredPeak: request.authoredPeak
        )
        let gainMapSeconds = Date().timeIntervalSince(gainMapStart)

        let metadata = try MetadataTemplate.isoGainMap(authoredPeak: request.authoredPeak)
        // A 3-sample base: an RGBA input makes `writeHEIFRepresentation` write an alpha channel,
        // which the delivery's `alpha` check rejects.
        let baseImage: CIImage
        switch request.options.bitDepth {
        case .ten:
            baseImage = CIImage(cgImage: try SDRBaseCGImage.make(from: request.sdrBase))
        case .eight:
            baseImage = CIImage(cgImage: try SDRBaseCGImage.make8Bit(from: request.sdrBase))
        }
        let mapImage = CIImage(cgImage: gainMap.cgImage).settingProperties([
            "kCGImageAuxiliaryDataInfoMetadata": metadata,
        ])
        let encodeOptions: [CIImageRepresentationOption: Any] = [
            .hdrGainMapImage: mapImage,
            .hdrGainMapAsRGB: request.options.mapKind == .isoRGB,
            CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            ): request.options.quality,
        ]

        // Write the container to a hidden temp beside the final path: the rewrap (or the atomic
        // move) is the only step that creates the final file.
        let directory = request.hdrOutputURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(request.hdrOutputURL.lastPathComponent).\(UUID().uuidString).tmp.heic"
        )
        let encodeStart = Date()
        do {
            switch request.options.bitDepth {
            case .ten:
                try context.writeHEIF10Representation(
                    of: baseImage,
                    to: temporary,
                    colorSpace: displayP3,
                    options: encodeOptions
                )
            case .eight:
                try context.writeHEIFRepresentation(
                    of: baseImage,
                    to: temporary,
                    format: .RGBA8,
                    colorSpace: displayP3,
                    options: encodeOptions
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PhotonError.writeFailed(
                path: request.hdrOutputURL.path,
                reason: "Core Image HEIF write failed: \(error)"
            )
        }
        let encodeSeconds = Date().timeIntervalSince(encodeStart)

        let rewrapStart = Date()
        if let sourceURL = request.sourceURL {
            try MetadataTemplate.rewrap(encodedURL: temporary, sourceURL: sourceURL, to: request.hdrOutputURL)
            try? FileManager.default.removeItem(at: temporary)
        } else {
            do {
                try AtomicFile.replace(temporary, with: request.hdrOutputURL)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        let rewrapSeconds = Date().timeIntervalSince(rewrapStart)

        // The fallback is the 8-bit SDR base with no auxiliary data (the file non-HDR viewers see).
        // One per delivery: the pipeline passes the shared URL for the first profile only.
        let fallbackStart = Date()
        if let sdrOutputURL = request.sdrOutputURL {
            do {
                try context.writeHEIFRepresentation(
                    of: baseImage,
                    to: sdrOutputURL,
                    format: .RGBA8,
                    colorSpace: displayP3,
                    options: [
                        CIImageRepresentationOption(
                            rawValue: kCGImageDestinationLossyCompressionQuality as String
                        ): request.options.quality,
                    ]
                )
            } catch {
                throw PhotonError.writeFailed(
                    path: sdrOutputURL.path,
                    reason: "Core Image SDR fallback write failed: \(error)"
                )
            }
            // The fallback is the file non-HDR viewers see; it carries the same filtered capture
            // metadata as the HDR file.
            if let sourceURL = request.sourceURL {
                let directory = sdrOutputURL.deletingLastPathComponent()
                let temporary = directory.appendingPathComponent(
                    ".\(sdrOutputURL.lastPathComponent).\(UUID().uuidString).tmp.heic"
                )
                try MetadataTemplate.rewrap(encodedURL: sdrOutputURL, sourceURL: sourceURL, to: temporary)
                do {
                    try AtomicFile.replace(temporary, with: sdrOutputURL)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            }
        }
        let fallbackSeconds = Date().timeIntervalSince(fallbackStart)

        let facts = try EncodedHEICValidator.validate(
            request.hdrOutputURL,
            expectedSize: request.sdrBase.size
        )
        return HEICEncodeResult(
            hdrHEIC: request.hdrOutputURL,
            sdrHEIC: request.sdrOutputURL,
            facts: facts,
            gainMapWidth: gainMap.width,
            gainMapHeight: gainMap.height,
            gainMapKind: request.options.mapKind,
            timings: HEICEncodeResult.Timings(
                gainMapSeconds: gainMapSeconds,
                encodeSeconds: encodeSeconds,
                rewrapSeconds: rewrapSeconds,
                fallbackSeconds: fallbackSeconds,
                totalSeconds: Date().timeIntervalSince(start)
            )
        )
    }

}
