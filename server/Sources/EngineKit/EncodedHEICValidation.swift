import CoreGraphics
import Foundation
import ImageIO

/// What ImageIO reports about an encoded HEIC — the facts `EncodedHEICValidator` asserts on.
///
/// The numbers come from the *primary* image plus the ISO gain-map auxiliary data; nothing here
/// reads pixels, so this stays cheap enough to run on every `prepare` (review P0-1).
public struct EncodedHEICFacts: Equatable, Sendable {
    /// Size of the decoded SDR (primary) image.
    public let width: Int
    public let height: Int
    public let sdrBitsPerComponent: Int
    /// False when the SDR decode is 3-sample RGB; true for any alpha-carrying layout.
    public let sdrHasAlpha: Bool
    /// `kCGImageAuxiliaryDataTypeISOGainMap` is present on the primary image.
    public let isoGainMapPresent: Bool
    /// The auxiliary map's pixel dimensions (0 when absent). Half-res profiles are base/2.
    public let gainMapWidth: Int
    public let gainMapHeight: Int
    /// The auxiliary map's `PixelFormat` fourCC (0 when absent): `420f` RGB, `L008` mono.
    public let gainMapPixelFormat: Int
    /// `kCGImageSourceDecodeRequest = kCGImageSourceDecodeToHDR` returned an image.
    public let hdrDecoded: Bool
    /// `CGImage.contentHeadroom` of the HDR decode (0.0 = unknown).
    public let contentHeadroom: Double
    /// `CGImage.calculatedContentHeadroom` of the HDR decode (0.0 = unknown). The encoder's
    /// advertised headroom is not always the one ImageIO reports as `contentHeadroom`, so this
    /// is the fallback the validator accepts.
    public let calculatedContentHeadroom: Double
    /// `CGImage.bitsPerComponent` of the HDR decode (0 when the HDR decode failed).
    public let hdrBitsPerComponent: Int
    /// `CGImage.width` of the HDR decode (0 when the HDR decode failed). Added for the M4 report's
    /// `alpha` check (docs/reference/deliver.md, report schema 1), which asserts the HDR decode has no alpha as well as the SDR.
    public let hdrWidth: Int
    /// `CGImage.height` of the HDR decode (0 when the HDR decode failed).
    public let hdrHeight: Int
    /// `CGImage.alphaInfo.rawValue` of the HDR decode, or `-1` when the HDR decode failed. The M4
    /// report prints both decodes' alpha layouts; keeping the raw value here means the facts stay
    /// a plain `Equatable` value with no ImageIO types (`CGImageAlphaInfo` naming is a report
    /// concern, `DeliveryImageProbe.alphaInfoName`).
    public let hdrAlphaInfoRaw: Int
}

/// Read-back assertions for an encoded gain-map HEIC (the Core Image writer or the external oracle).
///
/// This is the fix for review P0-1: the external tool exits 0 even when the pair carries no
/// headroom (a legal P3 source + the default recipe can make the highlight mask all-zero), and
/// all it writes then is a plain SDR HEIC with no ISO gain map and `contentHeadroom == 1.0`.
/// The v2 writer throws instead, but "exit 0"/"no throw" is still never treated as "HDR
/// delivered": the delivery report asserts the container facts here, via ImageIO only (never
/// `sips` — it silently strips gain maps, docs/reference/container.md).
public enum EncodedHEICValidator {
    /// Below this authored peak the encoder has no headroom to advertise and silently degrades to
    /// a plain SDR HEIC. Measured: a peak-0.5 pair encodes with exit 0, no ISO aux, headroom 1.0.
    public static let minimumAuthoredPeak: Float = 1.05

    /// Relative tolerance for the advertised headroom (the same 5 % `verify-heic` uses).
    public static let headroomTolerance: Double = 0.05

    /// Reads the container facts without asserting anything.
    ///
    /// - Throws: `PhotonError.encoderOutputInvalid` when the file cannot be opened or the primary
    ///   image cannot be decoded (for a HEIC the encoder wrote, that already means failure).
    public static func inspect(_ url: URL) throws -> EncodedHEICFacts {
        let path = url.standardizedFileURL.path
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotonError.encoderOutputInvalid(
                path: path,
                reason: "ImageIO cannot open the file (missing, or not a recognised image)"
            )
        }
        return try inspect(source, path: path).facts
    }

    /// Decodes once and returns both the facts and the two `CGImage`s.
    ///
    /// The M4 delivery verifier needs the decoded pixels as well as the container facts (base
    /// ΔE, clipping diagnostics, the fallback comparison), and decoding a 24 Mpx HEIC twice would
    /// be pure waste; this internal overload keeps a single decode for both. `inspect(_:)` and
    /// `validate` keep their exact public behaviour and messages (M1 tests depend on them).
    static func inspect(
        _ source: CGImageSource,
        path: String
    ) throws -> (facts: EncodedHEICFacts, sdr: CGImage, hdr: CGImage?) {
        let auxInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeISOGainMap
        ) as? [CFString: Any]
        let isoGainMapPresent = auxInfo != nil
        var gainMapWidth = 0
        var gainMapHeight = 0
        var gainMapPixelFormat = 0
        if let description = auxInfo?[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] {
            gainMapWidth = (description[kCGImagePropertyWidth] as? NSNumber)?.intValue ?? 0
            gainMapHeight = (description[kCGImagePropertyHeight] as? NSNumber)?.intValue ?? 0
            gainMapPixelFormat = (description[kCGImagePropertyPixelFormat] as? NSNumber)?.intValue ?? 0
        }

        guard let sdrImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotonError.encoderOutputInvalid(path: path, reason: "ImageIO could not decode the SDR image")
        }
        let hdrImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary
        )

        let facts = EncodedHEICFacts(
            width: sdrImage.width,
            height: sdrImage.height,
            sdrBitsPerComponent: sdrImage.bitsPerComponent,
            sdrHasAlpha: hasAlpha(sdrImage),
            isoGainMapPresent: isoGainMapPresent,
            gainMapWidth: gainMapWidth,
            gainMapHeight: gainMapHeight,
            gainMapPixelFormat: gainMapPixelFormat,
            hdrDecoded: hdrImage != nil,
            contentHeadroom: Double(hdrImage?.contentHeadroom ?? 0),
            calculatedContentHeadroom: Double(hdrImage?.calculatedContentHeadroom ?? 0),
            hdrBitsPerComponent: hdrImage?.bitsPerComponent ?? 0,
            hdrWidth: hdrImage?.width ?? 0,
            hdrHeight: hdrImage?.height ?? 0,
            hdrAlphaInfoRaw: hdrImage.map { Int($0.alphaInfo.rawValue) } ?? -1
        )
        return (facts, sdrImage, hdrImage)
    }

    /// Inspects `url` and throws **one** `PhotonError.encoderOutputInvalid` carrying every failed
    /// structural check, joined with `"; "` — a truncated first failure is not a useful report.
    ///
    /// Gates: ISO gain-map auxiliary data present, SDR has no alpha, dimensions match
    /// `expectedSize` (when given), and the HDR decode succeeded.
    ///
    /// The advertised-headroom match is not part of this structural check: it needs the authored
    /// expectation, which only the delivery verifier holds. There it is a **gate** again — the v2
    /// Core Image writer advertises headroom accurately, so ADR-0012 reclaimed the 5 % match from
    /// the ADR-0011 warning. The structural ISO-aux check here already rejects the plain-SDR
    /// degradation this gate existed for (review P0-1).
    ///
    /// - Returns: the facts, for callers that also want the raw numbers (the M4 report).
    @discardableResult
    public static func validate(
        _ url: URL,
        expectedSize: PixelSize?
    ) throws -> EncodedHEICFacts {
        let path = url.standardizedFileURL.path
        let facts = try inspect(url)

        var failures: [String] = []
        if !facts.isoGainMapPresent {
            failures.append(
                "no ISO gain-map auxiliary data (kCGImageAuxiliaryDataTypeISOGainMap missing): "
                    + "the encoder wrote a plain SDR HEIC"
            )
        }
        if facts.sdrHasAlpha {
            failures.append(
                "the SDR image has an alpha channel (\(facts.sdrBitsPerComponent) bpc); the preserved base must be 3-sample RGB"
            )
        }
        if let expectedSize, facts.width != expectedSize.width || facts.height != expectedSize.height {
            failures.append("size \(facts.width)x\(facts.height) != expected \(expectedSize)")
        }
        if !facts.hdrDecoded {
            failures.append(
                "kCGImageSourceDecodeRequest=kCGImageSourceDecodeToHDR returned no image"
            )
        }

        if !failures.isEmpty {
            throw PhotonError.encoderOutputInvalid(path: path, reason: failures.joined(separator: "; "))
        }
        return facts
    }

    // MARK: - Helpers

    /// `alphaInfo` in {`.none`, `.noneSkipLast`, `.noneSkipFirst`} means the image has no alpha.
    /// The parameter is a non-optional `CGImage` on purpose: `.none` on an `Optional<CGImage>`
    /// resolves to `Optional.none`, which is the wrong question (and warns).
    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst:
            return false
        default:
            return true
        }
    }
}
