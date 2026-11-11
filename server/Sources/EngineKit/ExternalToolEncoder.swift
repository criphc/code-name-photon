import ContractKit
import Foundation

/// The external `tools/toGainMapHDR` writer as a `HEICEncoder` — the migration oracle, not the
/// production path (docs/plans/v2-plan.md). It exists so the new engine can be compared against the
/// old one on the same source/recipe; it is selected only by `appctl deliver --encoder <path>`.
///
/// It writes the two intermediate TIFFs the tool consumes and moves the tool's output to the
/// requested path. The SDR fallback is the tool's own 8-bit HEIC with the map stripped by ImageIO.
public struct ExternalToolEncoder: HEICEncoder {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public var identity: EncoderIdentity {
        EncoderIdentity(tool: Recipe.EncoderParams.toolName, executable: executableURL.path)
    }

    public func encode(_ request: HEICEncodeRequest) throws -> HEICEncodeResult {
        let start = Date()
        let directory = request.hdrOutputURL.deletingLastPathComponent()
        let stem = request.hdrOutputURL.deletingPathExtension().lastPathComponent
        let hdrTIFF = directory.appendingPathComponent("\(stem)-hdr.tif")
        let sdrTIFF = directory.appendingPathComponent("\(stem)-sdr.tif")
        try TIFFWriter.writeSDRBase(request.sdrBase, to: sdrTIFF)
        try TIFFWriter.writeHDR(request.hdrRendition, to: hdrTIFF)

        let configuration = try EncoderConfiguration(
            executableURL: executableURL,
            quality: request.options.quality,
            depth: request.options.bitDepth.rawValue
        )
        let encoded = try Encoder(configuration: configuration).encode(
            hdrTIFF: hdrTIFF,
            baseTIFF: sdrTIFF,
            outputDirectory: directory,
            headroomCap: Double(request.authoredPeak)
        )
        if encoded.standardizedFileURL != request.hdrOutputURL.standardizedFileURL {
            try AtomicFile.replace(encoded, with: request.hdrOutputURL)
        }
        try? FileManager.default.removeItem(at: hdrTIFF)
        try? FileManager.default.removeItem(at: sdrTIFF)

        let facts = try EncodedHEICValidator.validate(
            request.hdrOutputURL,
            expectedSize: request.sdrBase.size
        )
        var sdrHEIC: URL?
        if let sdrOutputURL = request.sdrOutputURL {
            try DeliveryImageProbe.makeMapStrippedCopy(of: request.hdrOutputURL, to: sdrOutputURL)
            if let sourceURL = request.sourceURL {
                let directory = sdrOutputURL.deletingLastPathComponent()
                let temporary = directory.appendingPathComponent(
                    ".\(sdrOutputURL.lastPathComponent).\(UUID().uuidString).tmp.heic"
                )
                try MetadataTemplate.rewrap(encodedURL: sdrOutputURL, sourceURL: sourceURL, to: temporary)
                try AtomicFile.replace(temporary, with: sdrOutputURL)
            }
            sdrHEIC = sdrOutputURL
        }
        let total = Date().timeIntervalSince(start)
        return HEICEncodeResult(
            hdrHEIC: request.hdrOutputURL,
            sdrHEIC: sdrHEIC,
            facts: facts,
            gainMapWidth: facts.gainMapWidth,
            gainMapHeight: facts.gainMapHeight,
            gainMapKind: request.options.mapKind,
            timings: HEICEncodeResult.Timings(
                gainMapSeconds: 0,
                encodeSeconds: total,
                rewrapSeconds: 0,
                fallbackSeconds: 0,
                totalSeconds: total
            )
        )
    }
}
