import CoreGraphics
import CoreImage
import Foundation

/// Everything the M4 delivery verifier needs, assembled by `DeliveryPipeline` after the encoder's
/// output has passed the read-back gate (`EncodedHEICValidator.validate`).
///
/// The verifier is deliberately an *analysis* layer: it reads the encoded HEIC back with ImageIO,
/// compares it with the in-memory buffers the pipeline still holds, and returns the named checks of
/// docs/reference/deliver.md, report schema 1. It never renders a second HDR grade, never touches the SDR base pixels and never
/// trusts the encoder's exit code.
public struct DeliveryVerificationInput: Sendable {
    /// The freshly encoded gain-map HEIC in the staging directory (not yet installed).
    public let encodedHEIC: URL
    /// Where the verifier must write the map-stripped SDR copy (ImageIO, never `sips`). The
    /// pipeline installs it as `{stem}-sdr.heic`; it is the file non-HDR viewers show.
    public let fallbackHEIC: URL
    /// The exact linear-P3 SDR base the encoder was handed this run (`ToneMapper` output). The
    /// `baseDeltaE` check compares the decoded delivered base against these pixels.
    public let sdrBase: LinearImage
    /// Authored rendition facts measured on the float pixels before encoding (`HDRRendition`).
    public let authoredPeak: Float
    public let fractionAboveOne: Double
    public let fractionAtCap: Double
    /// The preview-scale pair the pipeline rendered with the same recipe (`PreviewRenderer`), and
    /// the long edge it was rendered at (docs/reference/client.md, one maths, one parity gate: preview vs
    /// delivery, reported not hidden).
    public let preview: PreviewRenderer.Pair
    public let previewLongEdge: Int
    /// The recipe that produced the delivery (all fields validated before rendering).
    public let recipe: Recipe
    /// Decoded source identity/facts without the working buffer.
    public let source: DeliverySourceFacts
    /// The output profile this file was encoded with (bit depth, map resolution/kind, quality).
    public let profile: HEICEncodeOptions

    public init(
        encodedHEIC: URL,
        fallbackHEIC: URL,
        sdrBase: LinearImage,
        authoredPeak: Float,
        fractionAboveOne: Double,
        fractionAtCap: Double,
        preview: PreviewRenderer.Pair,
        previewLongEdge: Int,
        recipe: Recipe,
        source: DeliverySourceFacts,
        profile: HEICEncodeOptions
    ) {
        self.encodedHEIC = encodedHEIC
        self.fallbackHEIC = fallbackHEIC
        self.sdrBase = sdrBase
        self.authoredPeak = authoredPeak
        self.fractionAboveOne = fractionAboveOne
        self.fractionAtCap = fractionAtCap
        self.preview = preview
        self.previewLongEdge = previewLongEdge
        self.recipe = recipe
        self.source = source
        self.profile = profile
    }
}

/// The M4 verifier: `tools/verify-heic`'s discipline, folded into the delivery gate.
///
/// Returns the eight named checks of docs/reference/deliver.md, report schema 1 in `DeliveryReport.checkOrder`. A failed check is
/// a `FAIL` in the returned array (never a thrown error): the pipeline records every check in
/// `report.json`, installs nothing when any check fails, and names the failures. Throwing is
/// reserved for an unreadable file (`DeliveryImageProbe.decode` — the pipeline has already rejected
/// those at the read-back gate), and every other condition becomes a `.fail` check with the reason
/// in `detail`: a check that cannot be evaluated is never omitted.
public enum DeliveryVerifier {
    // MARK: - Frozen thresholds

    /// `baseDeltaE` gate — **the decoded-container rule, calibrated per profile bit depth.**
    ///
    /// docs/reference/deliver.md, report schema 1 states the *render* target "mean ΔE2000 < 1, p95 < 2 versus the Capture One
    /// TIFF". That target belongs to the 16-bit `c1_match_v1` base, which is a bit-exact pass-through
    /// (M1 measured it, ΔE 0.000); it is not reachable through the delivered container, which is a
    /// single YCbCr 4:2:0 HEVC re-encode of that base — chroma subsampling alone produces a long ΔE
    /// tail. Measured on the M0 trial image (6000×4000, the encoder's fixed `-d 8 -q 0.85` flags),
    /// delivered SDR decode vs the bit-identical 16-bit base rendered to linear Display P3:
    /// **ΔE2000 mean 1.4406, p95 4.1200, p99 6.54, max 28.34; 8-bit P3 LSB mean 1.475, p99 7** (the
    /// LSB numbers exactly reproduce M0's published 1.475/1/3/7,
    /// docs/archive/stage-1/05-encoder-verification.md §3.2 — the decoded data is
    /// right). A fresh ImageIO 8-bit HEIC written from the same base measures the same (ΔE mean
    /// 1.535 / p95 4.40), which pins the cause on the codec, not on the delivered file.
    ///
    /// The 8-bit gate is **mean ≤ 2.5 AND p95 ≤ 6.0** (M0 calibration, unchanged). The 10-bit gate
    /// is **mean ≤ 2.0 AND p95 ≤ 5.0**, calibrated 2026-11-09 on three real Capture One P3 exports
    /// encoded in-process: R0003777 1.061/3.250, FPL05190 0.597/1.600, IMG_0543 0.399/1.020. The
    /// worst case leaves 1.88× / 1.54× margin, the same order as the 8-bit 1.74× / 1.46×; the
    /// tighter limit reflects the smaller quantisation error of a 10-bit base, not a different
    /// colour pipeline. Half and full maps measure identically (the base encode does not depend on
    /// map resolution), so the limits key on bit depth only.
    ///
    /// Either limit is real margin over the measured codec loss, while a colour-management error, a
    /// wrong profile or a base re-grade lands far above it. The 8-bit gate is a documented deviation
    /// from docs/reference/deliver.md, report schema 1 (decision 2026-11-03, Lead), recorded with
    /// the measurement in `docs/archive/stage-1/evidence/m4/probe/calibration.md` "Threshold
    /// decision" and cited from docs/archive/stage-1/07-m4-m5-output-and-acceptance.md §10. The M5
    /// report must explain itself; this comment and the check `detail` are why.
    static func baseDeltaELimits(forBitDepth bitDepth: Int) -> (mean: Double, p95: Double) {
        switch bitDepth {
        case 8: return (mean: 2.5, p95: 6.0)
        case 10: return (mean: 2.0, p95: 5.0)
        // `HEICEncodeOptions.BitDepth` only has 8 and 10; an unknown depth gets the stricter pair.
        default: return (mean: 2.0, p95: 5.0)
        }
    }

    /// The gate itself: both limits must hold for the profile's bit depth.
    static func baseDeltaEPasses(mean: Double, p95: Double, bitDepth: Int) -> Bool {
        let limits = baseDeltaELimits(forBitDepth: bitDepth)
        return mean <= limits.mean && p95 <= limits.p95
    }

    /// The measured codec loss the limits leave margin over (R0003777, 6000×4000, in-process
    /// `CoreImageHEICEncoder`), quoted in the check `detail` so the report explains its own gate.
    private static func baseDeltaECodecLossReference(forBitDepth bitDepth: Int) -> String {
        switch bitDepth {
        case 8: return "mean 1.44 / p95 4.12"
        default: return "mean 1.06 / p95 3.25"
        }
    }

    /// `fallback` gate: the ImageIO map-stripped copy re-decoded versus the delivered SDR primary
    /// decode. Both sides are 8-bit HEVC output, so the only legitimate difference is a second
    /// 8-bit 4:2:0 encode of the same base pixels (no re-grade, no recipe). Calibrated on the M0
    /// deliverable (6000×4000): mean 0.627 LSB, p99 3 LSB, max 25; ΔE2000 mean 0.5268 / p95 1.71 /
    /// p99 2.63 — the thresholds sit several times above that, tight enough that a re-tone-mapped
    /// or edited base fails while a pristine copy passes.
    /// Evidence: `docs/archive/stage-1/evidence/m4/probe/calibration.md`.
    static let fallbackMeanAbsDiffLimit = 2.5
    static let fallbackP99AbsDiffLimit = 8
    /// v2: the fallback is 8-bit while the delivered SDR primary can be 10-bit. The bit-depth
    /// difference adds ~0.05 ΔE to the M0 0.5268 baseline, so the mean limit is 1.5 (the 8-bit
    /// LSB/p99 limits are unchanged). Measured on the 10-bit R0003777 profile: 1.055.
    static let fallbackDeltaEMeanLimit = 1.5

    /// `previewAgreement` gate: the same recipe rendered at preview scale (`input.preview`, the
    /// lossless float pair from `PreviewRenderer.downscale`) versus the delivered HDR decode
    /// downscaled with the same Lanczos path. This is deliberately a *gross* disagreement gate
    /// (wrong recipe / wrong file / wrong cap), not a pixel-level one: the documented sub-pixel
    /// highlight-edge difference between the 2560 px mask and the full-resolution mask
    /// (docs/reference/client.md, one maths, one parity gate; docs/reference/deliver.md, delivery contract) plus the
    /// 8-bit gain-map quantisation are expected and reported,
    /// never failed. Calibrated on the M0 pair: the lossless analogue (downscale
    /// the M0 HDR rendition (binary deleted; see docs/archive/stage-1/MANIFEST.md), clamp to the 2.5
    /// cap, versus the M0 full HEIC decode downscaled)
    /// measures ΔE2000 mean 1.1642, p95 3.30, p99 5.27, fractionAbove5 1.24 % — concentrated on
    /// highlight edges and codec noise. The limits below leave ~2× margin over that, while a wrong
    /// recipe (different mask/lift/cap) moves a large fraction of the frame by ΔE 10+.
    /// Evidence: `docs/archive/stage-1/evidence/m4/probe/calibration.md`.
    static let previewMeanDeltaELimit = 2.5
    static let previewP99DeltaELimit = 10.0
    static let previewFractionAbove5Limit = 0.05

    // MARK: - Entry point

    /// Runs every check and returns them in `DeliveryReport.checkOrder`.
    ///
    /// - Throws: only when `encodedHEIC` cannot be opened or its primary image cannot be decoded
    ///   (that is "the file is unreadable", not a check outcome). Every other failure — including a
    ///   non-HEIF file, a missing gain map, or a render error inside one check — becomes a `.fail`
    ///   `Check` with the reason in `detail`.
    public static func verify(_ input: DeliveryVerificationInput) throws -> [DeliveryReport.Check] {
        let decoded = try DeliveryImageProbe.decode(input.encodedHEIC)
        let context = DeliveryImageProbe.makeContext()

        // The ftyp read is needed by `container` only; a malformed container must be a failed
        // check, not a throw, so capture the outcome here.
        let ftyp: Result<DeliveryImageProbe.FTYP, Error>
        do {
            ftyp = .success(try DeliveryImageProbe.readFTYP(input.encodedHEIC))
        } catch {
            ftyp = .failure(error)
        }

        let checks = [
            evaluate("container") { try containerCheck(input, decoded, ftyp: ftyp) },
            evaluate("identity") { identityCheck(input, decoded) },
            evaluate("alpha") { alphaCheck(decoded) },
            evaluate("headroom") { headroomCheck(input, decoded) },
            evaluate("clipping") { try clippingCheck(input, decoded, context: context) },
            evaluate("baseDeltaE") { try baseDeltaECheck(input, decoded, context: context) },
            evaluate("fallback") { try fallbackCheck(input, decoded, context: context) },
            evaluate("previewAgreement") { try previewAgreementCheck(input, decoded, context: context) },
        ]
        assert(
            checks.map(\.name) == DeliveryReport.checkOrder,
            "the delivery verifier must return the documented checks in order"
        )
        return checks
    }

    /// Runs one check body; any thrown error becomes a `.fail` check (fail-closed, never omitted).
    private static func evaluate(
        _ name: String,
        _ body: () throws -> DeliveryReport.Check
    ) -> DeliveryReport.Check {
        do {
            let check = try body()
            guard check.name == name else {
                return failure(name, "internal: the verifier produced check '\(check.name)' where '\(name)' was expected")
            }
            return check
        } catch {
            return failure(name, "check could not be evaluated: \(error)")
        }
    }

    private static func failure(
        _ name: String,
        _ reason: String,
        measured: [String: DeliveryReport.Value] = [:],
        warnings: [String] = []
    ) -> DeliveryReport.Check {
        DeliveryReport.Check(
            name: name, pass: false, detail: reason, measured: measured, warnings: warnings
        )
    }

    private static func value(_ optional: Double?) -> DeliveryReport.Value? {
        guard let optional, optional.isFinite else { return nil }
        return .number(optional)
    }

    /// A fraction (0…1) as a percentage string, e.g. `1.23 %`.
    private static func percent(_ fraction: Double) -> String {
        String(format: "%.2f %%", fraction * 100)
    }

    // MARK: - container

    /// HEIF/ISO-BMFF byte structure, the ISO 21496-1 `tmap` compatible brand, and the ISO gain-map
    /// auxiliary image — ImageIO only. The failure detail names the sub-assertion that failed.
    private static func containerCheck(
        _ input: DeliveryVerificationInput,
        _ decoded: DeliveryImageProbe.DecodedDelivery,
        ftyp: Result<DeliveryImageProbe.FTYP, Error>
    ) throws -> DeliveryReport.Check {
        let half = input.profile.mapResolution == .half
        let expectedMapWidth = half ? max(1, decoded.facts.width / 2) : decoded.facts.width
        let expectedMapHeight = half ? max(1, decoded.facts.height / 2) : decoded.facts.height
        let isMono = decoded.facts.gainMapPixelFormat == 1278226488 // 'L008'
        var measured: [String: DeliveryReport.Value] = [
            "isoGainMapPresent": .boolean(decoded.facts.isoGainMapPresent),
            "sdrWidth": .integer(decoded.facts.width),
            "sdrHeight": .integer(decoded.facts.height),
            "gainMapWidth": .integer(decoded.facts.gainMapWidth),
            "gainMapHeight": .integer(decoded.facts.gainMapHeight),
            "gainMapPixelFormat": .integer(decoded.facts.gainMapPixelFormat),
            "profileBitDepth": .integer(input.profile.bitDepth.rawValue),
            "profileMapResolution": .text(input.profile.mapResolution.rawValue),
            "profileMapKind": .text(input.profile.mapKind.rawValue),
            "expectedMapWidth": .integer(expectedMapWidth),
            "expectedMapHeight": .integer(expectedMapHeight),
        ]
        var failures: [String] = []

        switch ftyp {
        case let .success(box):
            measured["majorBrand"] = .text(box.majorBrand)
            measured["compatibleBrands"] = .text(box.compatibleBrands.joined(separator: ","))
            measured["isHEIF"] = .boolean(box.isHEIF)
            measured["tmapBrand"] = .boolean(box.hasTMap)
            measured["ftypBoxSize"] = .integer(box.boxSize)
            if !box.isHEIF {
                failures.append(
                    "ISO-BMFF ftyp major brand '\(box.majorBrand)' is not a HEIF brand "
                        + "(\(DeliveryImageProbe.heifBrands.sorted().joined(separator: ", ")))"
                )
            }
            if !box.hasTMap {
                failures.append(
                    "ftyp compatible brands [\(box.compatibleBrands.joined(separator: ","))] "
                        + "do not include the ISO 21496-1 'tmap' brand"
                )
            }
        case let .failure(error):
            measured["majorBrand"] = .text("")
            measured["compatibleBrands"] = .text("")
            measured["isHEIF"] = .boolean(false)
            measured["tmapBrand"] = .boolean(false)
            failures.append("not an ISO-BMFF/HEIF file: \(error)")
        }

        if !decoded.facts.isoGainMapPresent {
            failures.append(
                "kCGImageAuxiliaryDataTypeISOGainMap is missing: the file carries no ISO gain-map auxiliary image"
            )
        } else {
            if decoded.facts.gainMapWidth != expectedMapWidth || decoded.facts.gainMapHeight != expectedMapHeight {
                failures.append(
                    "gain map is \(decoded.facts.gainMapWidth)x\(decoded.facts.gainMapHeight), expected "
                        + "\(expectedMapWidth)x\(expectedMapHeight) for the \(input.profile.mapResolution.rawValue) profile"
                )
            }
            if input.profile.mapKind == .isoMono && !isMono {
                failures.append("the \(input.profile.mapKind.rawValue) profile wrote a non-mono gain map")
            }
            if input.profile.mapKind == .isoRGB && isMono {
                failures.append("the \(input.profile.mapKind.rawValue) profile wrote a mono gain map")
            }
        }

        let detail = failures.isEmpty
            ? "ISO-BMFF/HEIF container with compatible brand tmap and the ISO gain-map auxiliary present "
                + "(\(decoded.facts.gainMapWidth)x\(decoded.facts.gainMapHeight), \(input.profile.mapKind.rawValue))."
            : "failed: " + failures.joined(separator: "; ")
        return DeliveryReport.Check(name: "container", pass: failures.isEmpty, detail: detail, measured: measured)
    }

    // MARK: - identity

    /// Decoded dimensions against the source and the recipe, and the source SHA-256 against the
    /// recipe's identity. `renderKey` deliberately does not appear here: the pipeline computed it
    /// from the validated recipe and records it in the report (docs/reference/deliver.md, report schema 1).
    private static func identityCheck(
        _ input: DeliveryVerificationInput,
        _ decoded: DeliveryImageProbe.DecodedDelivery
    ) -> DeliveryReport.Check {
        let expected = input.source.size
        let recipe = input.recipe.source
        let sourceSHA = input.source.sha256.lowercased()
        let recipeSHA = recipe.sha256.lowercased()
        let dimsMatchSource = decoded.facts.width == expected.width && decoded.facts.height == expected.height
        let dimsMatchRecipe = decoded.facts.width == recipe.width && decoded.facts.height == recipe.height
        let shaMatch = sourceSHA == recipeSHA
        let measured: [String: DeliveryReport.Value] = [
            "decodedWidth": .integer(decoded.facts.width),
            "decodedHeight": .integer(decoded.facts.height),
            "expectedWidth": .integer(expected.width),
            "expectedHeight": .integer(expected.height),
            "recipeWidth": .integer(recipe.width),
            "recipeHeight": .integer(recipe.height),
            "sourceSha256": .text(sourceSHA),
            "recipeSourceSha256": .text(recipeSHA),
            "sourceSha256Match": .boolean(shaMatch),
            "dimsMatchSource": .boolean(dimsMatchSource),
            "dimsMatchRecipe": .boolean(dimsMatchRecipe),
        ]
        var failures: [String] = []
        if !dimsMatchSource {
            failures.append(
                "decoded \(decoded.facts.width)x\(decoded.facts.height) != source \(expected)"
            )
        }
        if !dimsMatchRecipe {
            failures.append(
                "decoded \(decoded.facts.width)x\(decoded.facts.height) != recipe source \(recipe.width)x\(recipe.height)"
            )
        }
        if !shaMatch {
            failures.append("source sha256 \(sourceSHA) != recipe source.sha256 \(recipeSHA)")
        }
        let detail = failures.isEmpty
            ? "decoded \(decoded.facts.width)x\(decoded.facts.height) matches the source and the recipe, and the source sha256 matches the recipe identity."
            : "failed: " + failures.joined(separator: "; ")
        return DeliveryReport.Check(name: "identity", pass: failures.isEmpty, detail: detail, measured: measured)
    }

    // MARK: - alpha

    /// No alpha in the SDR **and** HDR decodes (docs/reference/deliver.md, report schema 1, alpha check). A missing HDR decode is
    /// a failure here because the HDR half of the assertion cannot be shown.
    private static func alphaCheck(_ decoded: DeliveryImageProbe.DecodedDelivery) -> DeliveryReport.Check {
        let sdrHasAlpha = decoded.facts.sdrHasAlpha
        let hdrAvailable = decoded.hdr != nil
        let hdrHasAlpha = DeliveryImageProbe.hasAlpha(rawValue: decoded.facts.hdrAlphaInfoRaw)
        let measured: [String: DeliveryReport.Value] = [
            "sdrAlphaInfo": .text(decoded.sdrAlphaInfoName),
            "hdrAlphaInfo": .text(decoded.hdrAlphaInfoName),
            "sdrHasAlpha": .boolean(sdrHasAlpha),
            "hdrHasAlpha": .boolean(hdrHasAlpha),
            "sdrBitsPerComponent": .integer(decoded.facts.sdrBitsPerComponent),
        ]
        var failures: [String] = []
        if sdrHasAlpha {
            failures.append("the SDR decode has an alpha channel (\(decoded.sdrAlphaInfoName))")
        }
        if !hdrAvailable {
            failures.append("the HDR decode is absent (no gain map), so the no-alpha assertion cannot be shown")
        } else if hdrHasAlpha {
            failures.append("the HDR decode has an alpha channel (\(decoded.hdrAlphaInfoName))")
        }
        let detail = failures.isEmpty
            ? "SDR alphaInfo \(decoded.sdrAlphaInfoName) and HDR alphaInfo \(decoded.hdrAlphaInfoName): neither decode carries alpha."
            : "failed: " + failures.joined(separator: "; ")
        return DeliveryReport.Check(name: "alpha", pass: failures.isEmpty, detail: detail, measured: measured)
    }

    // MARK: - headroom

    /// The advertised `contentHeadroom` against the expected linear headroom
    /// `min(recipe.hdr.headroom_cap, authoredPeak)`, within the documented 5 % tolerance;
    /// `calculatedContentHeadroom` is reported as the cross-check (docs/reference/verification.md: `contentHeadroom`
    /// is authoritative, the calculated one is pixel-derived). A missing gain map has no candidate
    /// above 1.0 and must fail; an unclamped authored peak is a clamp violation and must fail.
    ///
    /// The 5 % advertised-headroom match is a **gate** again: the v2 Core Image writer advertises
    /// the authored peak exactly (ADR-0012 recovered ADR-0011). The old external tool's
    /// small-highlight under-report (FPL05190) is an oracle-only caveat.
    private static func headroomCheck(
        _ input: DeliveryVerificationInput,
        _ decoded: DeliveryImageProbe.DecodedDelivery
    ) -> DeliveryReport.Check {
        let cap = input.recipe.hdr.headroomCap
        let authoredPeak = Double(input.authoredPeak)
        let expected = min(cap, authoredPeak)
        let tolerance = EncodedHEICValidator.headroomTolerance
        let clampViolated = authoredPeak > cap + 1e-6
        let capEngaged = authoredPeak >= cap - 1e-6

        // Which number is "the advertised headroom": `contentHeadroom` first (authoritative),
        // `calculatedContentHeadroom` only as a fallback when ImageIO reports nothing above 1.0.
        let content = decoded.facts.contentHeadroom
        let calculated = decoded.facts.calculatedContentHeadroom
        let advertised: Double?
        let measurementSource: String
        if content > 1.0 {
            advertised = content
            measurementSource = "contentHeadroom"
        } else if calculated > 1.0 {
            advertised = calculated
            measurementSource = "calculatedContentHeadroom (contentHeadroom unavailable)"
        } else {
            advertised = nil
            measurementSource = "none"
        }
        let relativeError = advertised.map { abs($0 / expected - 1.0) }
        let withinTolerance = relativeError.map { $0 <= tolerance }

        var measured: [String: DeliveryReport.Value] = [
            "contentHeadroom": .number(content),
            "calculatedContentHeadroom": .number(calculated),
            "expectedHeadroom": .number(expected),
            "headroomCap": .number(cap),
            "capEngaged": .boolean(capEngaged),
            "tolerance": .number(tolerance),
            "measurementSource": .text(measurementSource),
        ]
        if let relativeError, let value = Self.value(relativeError) { measured["relativeError"] = value }
        if let withinTolerance { measured["withinTolerance"] = .boolean(withinTolerance) }

        var failures: [String] = []
        if clampViolated {
            failures.append(
                "authored peak \(authoredPeak) exceeds the recipe cap \(cap) by more than 1e-6: HDRRendition did not clamp"
            )
        }
        if advertised == nil {
            failures.append(
                "no advertised headroom above 1.0 (contentHeadroom \(content), calculatedContentHeadroom \(calculated)): the file has no ISO gain map"
            )
        } else if let advertised, let relativeError, relativeError > tolerance {
            failures.append(
                "advertised \(measurementSource) \(advertised) differs from expected \(expected) by "
                    + Self.percent(relativeError) + " (> " + Self.percent(tolerance) + ")"
            )
        }

        let detail: String
        if !failures.isEmpty {
            detail = "failed: " + failures.joined(separator: "; ")
        } else if let advertised, let relativeError {
            detail = "\(measurementSource) \(advertised) is within \(Self.percent(tolerance)) of the expected \(expected) "
                + "(relative error \(Self.percent(relativeError))); calculatedContentHeadroom \(calculated) reported as cross-check."
        } else {
            detail = "no advertised headroom above 1.0"
        }
        return DeliveryReport.Check(name: "headroom", pass: failures.isEmpty, detail: detail, measured: measured)
    }

    // MARK: - clipping

    /// The authored clamp: `authoredPeak <= cap + 1e-6`, `authoredPeak >= 1.05` (the encoder's
    /// documented floor, re-asserted here), and a non-zero authored fraction above SDR white.
    /// The decode-side overshoot (rendered HDR peak and fractions above the cap / advertised
    /// headroom) is reported as a **diagnostic**, not a gate (docs/reference/verification.md).
    private static func clippingCheck(
        _ input: DeliveryVerificationInput,
        _ decoded: DeliveryImageProbe.DecodedDelivery,
        context: CIContext
    ) throws -> DeliveryReport.Check {
        let cap = input.recipe.hdr.headroomCap
        let authoredPeak = input.authoredPeak
        let clampOK = Double(authoredPeak) <= cap + 1e-6
        let floorOK = authoredPeak >= EncodedHEICValidator.minimumAuthoredPeak
        let fractionOK = input.fractionAboveOne > 0
        let authoredPeakStops = authoredPeak > 0 ? log2(Double(authoredPeak)) : 0

        var measured: [String: DeliveryReport.Value] = [
            "authoredPeak": .number(Double(authoredPeak)),
            "authoredPeakStops": .number(authoredPeakStops),
            "fractionAboveOne": .number(input.fractionAboveOne),
            "fractionAtCap": .number(input.fractionAtCap),
            "headroomCap": .number(cap),
            "minimumAuthoredPeak": .number(Double(EncodedHEICValidator.minimumAuthoredPeak)),
            "clampOK": .boolean(clampOK),
            "floorOK": .boolean(floorOK),
        ]

        // Decode-side diagnostics: the HDR decode may overshoot the cap at clipped speculars
        // because the SDR fallback itself can peak ~1.19 linear (8-bit chroma overshoot) and the
        // gain map multiplies it (docs/archive/stage-1/05-encoder-verification.md §3.2). Never a gate.
        if let hdr = decoded.hdr {
            let hdrSize = PixelSize(width: hdr.width, height: hdr.height)
            let stats = try DeliveryImageProbe.linearStats(
                candidate: CIImage(cgImage: hdr),
                size: hdrSize,
                cap: cap,
                contentHeadroom: decoded.facts.contentHeadroom > 1.0 ? decoded.facts.contentHeadroom : nil,
                context: context
            )
            measured["decodedPeak"] = .number(stats.peak)
            if let fraction = stats.fractionAboveCap {
                measured["decodedFractionAboveCap"] = .number(fraction)
            }
            if let fraction = stats.fractionAboveContentHeadroom {
                measured["decodedFractionAboveContentHeadroom"] = .number(fraction)
            }
            measured["decodedNonFiniteSamples"] = .integer(stats.nonFiniteCount)
        } else {
            measured["decodedPeak"] = .number(0)
        }

        var failures: [String] = []
        if !clampOK {
            failures.append(
                "authored peak \(authoredPeak) > cap \(cap) + 1e-6: the HDRRendition clamp did not engage"
            )
        }
        if !floorOK {
            failures.append(
                "authored peak \(authoredPeak) is below the encoder floor \(EncodedHEICValidator.minimumAuthoredPeak)"
            )
        }
        if !fractionOK {
            failures.append("the authored rendition has no sample above SDR white (fractionAboveOne == 0): no HDR was authored")
        }
        let detail = failures.isEmpty
            ? "authored peak \(authoredPeak) (\(String(format: "%.6f", authoredPeakStops)) stops) clamps to the \(cap) cap while \(String(format: "%.4f", input.fractionAboveOne * 100)) % of pixels are above 1.0 and \(String(format: "%.4f", input.fractionAtCap * 100)) % sit at the cap."
            : "failed: " + failures.joined(separator: "; ")
        return DeliveryReport.Check(name: "clipping", pass: failures.isEmpty, detail: detail, measured: measured)
    }

    // MARK: - baseDeltaE

    /// The Capture One match (docs/reference/deliver.md, report schema 1): the decoded delivered SDR base rendered to linear
    /// Display P3 float versus the `ToneMapper` base the pipeline still holds. ΔE2000 mean and p95
    /// gate at the profile's bit depth (8-bit mean ≤ 2.5 / p95 ≤ 6.0, 10-bit mean ≤ 2.0 / p95 ≤ 5.0);
    /// max/p99/fraction above 2 are diagnostics, and the 8-bit LSB distribution is the codec-sanity
    /// cross-check.
    private static func baseDeltaECheck(
        _ input: DeliveryVerificationInput,
        _ decoded: DeliveryImageProbe.DecodedDelivery,
        context: CIContext
    ) throws -> DeliveryReport.Check {
        let decodedSize = decoded.sdrSize
        guard input.sdrBase.size == decodedSize else {
            return failure(
                "baseDeltaE",
                "cannot compare: decoded SDR \(decodedSize) != the in-memory base \(input.sdrBase.size)"
            )
        }
        let candidate = CIImage(cgImage: decoded.sdr)
        let deltaE = try DeliveryImageProbe.deltaEStats(
            reference: input.sdrBase,
            candidate: candidate,
            context: context
        )
        let lsb = try DeliveryImageProbe.lsbStats(
            reference: input.sdrBase,
            candidate: candidate,
            context: context
        )
        let bitDepth = input.profile.bitDepth.rawValue
        let limits = baseDeltaELimits(forBitDepth: bitDepth)
        let passed = baseDeltaEPasses(mean: deltaE.mean, p95: deltaE.p95, bitDepth: bitDepth)
        var measured: [String: DeliveryReport.Value] = [
            "mean": .number(deltaE.mean),
            "p50": .number(deltaE.p50),
            "p95": .number(deltaE.p95),
            "p99": .number(deltaE.p99),
            "max": .number(deltaE.max),
            "fractionAbove2": .number(deltaE.fractionAbove2),
            "fractionAbove5": .number(deltaE.fractionAbove5),
            "meanAbsDiff8Bit": .number(lsb.meanAbsDiff),
            "p99AbsDiff8Bit": .integer(lsb.p99),
            "pixelCount": .integer(deltaE.pixelCount),
            "meanLimit": .number(limits.mean),
            "p95Limit": .number(limits.p95),
            "profileBitDepth": .integer(bitDepth),
            // The render target (docs/reference/deliver.md, report schema 1), reported for the M5 record — deliberately *not* the
            // gate: it is a 16-bit render target, not reachable through a 4:2:0 container.
            "renderTargetMean": .number(1.0),
            "renderTargetP95": .number(2.0),
        ]
        if deltaE.nonFiniteCount > 0 {
            measured["nonFiniteCount"] = .integer(deltaE.nonFiniteCount)
        }
        let detail: String
        if passed {
            detail = "decoded SDR base vs the Capture One base: ΔE2000 mean \(String(format: "%.4f", deltaE.mean)) "
                + "(<= \(limits.mean)), p95 \(String(format: "%.4f", deltaE.p95)) (<= \(limits.p95)); "
                + "max \(String(format: "%.2f", deltaE.max)), 8-bit mean \(String(format: "%.3f", lsb.meanAbsDiff)) LSB "
                + "— the render target (mean < 1 / p95 < 2, docs/reference/deliver.md, report schema 1) applies to the bit-exact 16-bit base, "
                + "not to a decoded \(bitDepth)-bit 4:2:0 HEVC container whose measured codec loss on R0003777 is "
                + "\(baseDeltaECodecLossReference(forBitDepth: bitDepth))."
        } else {
            detail = "failed: ΔE2000 mean \(String(format: "%.4f", deltaE.mean)) / p95 "
                + "\(String(format: "%.4f", deltaE.p95)) exceed the \(bitDepth)-bit decoded-container limits mean <= \(limits.mean) "
                + "and p95 <= \(limits.p95); the delivered base has drifted from the Capture One export "
                + "beyond \(bitDepth)-bit 4:2:0 codec loss (suspected colour-management/profile or base re-grade)."
        }
        return DeliveryReport.Check(name: "baseDeltaE", pass: passed, detail: detail, measured: measured)
    }

    // MARK: - fallback

    /// Inspects the engine's 8-bit SDR fallback (`input.fallbackHEIC`; HEIF, no ISO gain map, same
    /// dimensions) and compares its decode against the delivered SDR primary decode. This proves
    /// the file non-HDR viewers see is the Capture One base. The fallback is written once per
    /// delivery by the encoder, not re-created here.
    private static func fallbackCheck(
        _ input: DeliveryVerificationInput,
        _ decoded: DeliveryImageProbe.DecodedDelivery,
        context: CIContext
    ) throws -> DeliveryReport.Check {
        let copyURL = input.fallbackHEIC
        guard FileManager.default.fileExists(atPath: copyURL.path) else {
            return failure(
                "fallback",
                "the 8-bit SDR fallback '\(copyURL.lastPathComponent)' is missing"
            )
        }
        let copyFacts = try EncodedHEICValidator.inspect(copyURL)
        guard let copySource = CGImageSourceCreateWithURL(copyURL as CFURL, nil),
              let copyImage = CGImageSourceCreateImageAtIndex(copySource, 0, nil)
        else {
            return failure("fallback", "the map-stripped copy '\(copyURL.lastPathComponent)' cannot be decoded by ImageIO")
        }
        let copySize = PixelSize(width: copyImage.width, height: copyImage.height)
        let deliveredSize = decoded.sdrSize
        let copyFTYP = try? DeliveryImageProbe.readFTYP(copyURL)
        let copySHA = try DeliveryImageProbe.sha256(ofFileAt: copyURL)
        let copyBytes = DeliveryImageProbe.fileBytes(copyURL) ?? 0

        var measured: [String: DeliveryReport.Value] = [
            "copySha256": .text(copySHA),
            "copyBytes": .integer(copyBytes),
            "copyIsoGainMapPresent": .boolean(copyFacts.isoGainMapPresent),
            "copyWidth": .integer(copySize.width),
            "copyHeight": .integer(copySize.height),
            "deliveredWidth": .integer(deliveredSize.width),
            "deliveredHeight": .integer(deliveredSize.height),
            "meanAbsDiffLimit": .number(fallbackMeanAbsDiffLimit),
            "p99AbsDiffLimit": .integer(fallbackP99AbsDiffLimit),
            "deltaEMeanLimit": .number(fallbackDeltaEMeanLimit),
        ]
        if let copyFTYP {
            measured["copyMajorBrand"] = .text(copyFTYP.majorBrand)
            measured["copyCompatibleBrands"] = .text(copyFTYP.compatibleBrands.joined(separator: ","))
            measured["copyIsHEIF"] = .boolean(copyFTYP.isHEIF)
            measured["copyTmapBrand"] = .boolean(copyFTYP.hasTMap)
        }

        var failures: [String] = []
        if copyFacts.sdrBitsPerComponent != 8 {
            failures.append(
                "the SDR fallback is \(copyFacts.sdrBitsPerComponent)-bit; the contract is 8-bit"
            )
        }
        if copyFacts.isoGainMapPresent {
            failures.append("the SDR fallback still carries an ISO gain-map auxiliary image")
        }
        if let copyFTYP {
            if !copyFTYP.isHEIF {
                failures.append("the map-stripped copy is not a HEIF file (major brand '\(copyFTYP.majorBrand)')")
            }
            if copyFTYP.hasTMap {
                failures.append("the map-stripped copy still declares the tmap brand")
            }
        } else {
            failures.append("the map-stripped copy has no readable ftyp box")
        }
        if copySize != deliveredSize {
            failures.append("the copy is \(copySize) but the delivered SDR primary is \(deliveredSize)")
        }

        // The comparison is only meaningful at equal dimensions; skip it otherwise.
        if copySize == deliveredSize {
            let deliveredCI = CIImage(cgImage: decoded.sdr)
            let copyCI = CIImage(cgImage: copyImage)
            let lsb = try DeliveryImageProbe.lsbStats(deliveredCI, copyCI, size: deliveredSize, context: context)
            let deltaE = try DeliveryImageProbe.deltaEStats(deliveredCI, copyCI, size: deliveredSize, context: context)
            measured["meanAbsDiff"] = .number(lsb.meanAbsDiff)
            measured["p99AbsDiff"] = .integer(lsb.p99)
            measured["maxAbsDiff"] = .integer(lsb.max)
            measured["p50AbsDiff"] = .integer(lsb.p50)
            measured["fractionNonZero8Bit"] = .number(lsb.fractionNonZero)
            measured["deltaEMean"] = .number(deltaE.mean)
            measured["deltaEP95"] = .number(deltaE.p95)
            measured["deltaEP99"] = .number(deltaE.p99)
            measured["deltaEMax"] = .number(deltaE.max)
            if lsb.meanAbsDiff > fallbackMeanAbsDiffLimit {
                failures.append(
                    "copy vs delivered SDR: mean absolute difference \(String(format: "%.3f", lsb.meanAbsDiff)) LSB > \(fallbackMeanAbsDiffLimit) LSB"
                )
            }
            if lsb.p99 > fallbackP99AbsDiffLimit {
                failures.append(
                    "copy vs delivered SDR: p99 absolute difference \(lsb.p99) LSB > \(fallbackP99AbsDiffLimit) LSB"
                )
            }
            if deltaE.mean > fallbackDeltaEMeanLimit {
                failures.append(
                    "copy vs delivered SDR: ΔE2000 mean \(String(format: "%.3f", deltaE.mean)) > \(fallbackDeltaEMeanLimit)"
                )
            }
        }

        let detail: String
        if failures.isEmpty {
            let lsbMean = measured["meanAbsDiff"]?.numberValue ?? 0
            let lsbP99 = measured["p99AbsDiff"]?.numberValue ?? 0
            let deltaEMean = measured["deltaEMean"]?.numberValue ?? 0
            detail = "8-bit SDR fallback \(copyBytes) B (sha256 \(String(copySHA.prefix(12)))) is a HEIF without an ISO gain map "
                + "and matches the delivered SDR primary: mean \(String(format: "%.3f", lsbMean)) LSB, p99 "
                + "\(Int(lsbP99)) LSB, ΔE2000 mean \(String(format: "%.4f", deltaEMean))."
        } else {
            detail = "failed: " + failures.joined(separator: "; ")
        }
        return DeliveryReport.Check(name: "fallback", pass: failures.isEmpty, detail: detail, measured: measured)
    }

    // MARK: - previewAgreement

    /// The same recipe at preview scale versus the delivered HDR decode downscaled with the same
    /// Lanczos path (`clampedToExtent` + `CILanczosScaleTransform` + crop, then rendered to
    /// linear P3). The residual is reported, never fixed up (docs/reference/deliver.md, delivery contract); the gate only catches
    /// gross disagreement, see the threshold comment above.
    private static func previewAgreementCheck(
        _ input: DeliveryVerificationInput,
        _ decoded: DeliveryImageProbe.DecodedDelivery,
        context: CIContext
    ) throws -> DeliveryReport.Check {
        guard let hdr = decoded.hdr else {
            return failure(
                "previewAgreement",
                "cannot compare at preview scale: the delivered file has no HDR decode (no gain map)"
            )
        }
        let target = input.preview.size
        guard target.width > 0, target.height > 0 else {
            return failure("previewAgreement", "the preview pair has a zero-sized preview (\(target))")
        }
        guard input.preview.hdr.size == target else {
            return failure(
                "previewAgreement",
                "the preview pair is inconsistent: reported \(target), hdr buffer \(input.preview.hdr.size)"
            )
        }
        let hdrSize = PixelSize(width: hdr.width, height: hdr.height)
        let hdrCI = CIImage(cgImage: hdr)
        let scaled: CIImage
        if hdrSize == target {
            scaled = hdrCI
        } else {
            scaled = PreviewRenderer.lanczos(hdrCI, to: target)
        }
        let deliveredPreview = try PreviewRenderer.render(scaled, size: target, context: context)
        let deltaE = DeliveryImageProbe.deltaEStats(deliveredPreview, input.preview.hdr)
        let half = input.profile.mapResolution == .half
        let fractionFailLimit = half ? 0.20 : previewFractionAbove5Limit
        let fractionWarningLimit = half ? 0.10 : previewFractionAbove5Limit
        let passed = deltaE.mean < previewMeanDeltaELimit
            && deltaE.p99 < previewP99DeltaELimit
            && deltaE.fractionAbove5 <= fractionFailLimit
        var warnings: [String] = []
        if half && deltaE.fractionAbove5 > fractionWarningLimit && deltaE.fractionAbove5 <= fractionFailLimit {
            warnings.append(
                "half-res gain map: \(Self.percent(deltaE.fractionAbove5)) of pixels above ΔE 5 (10–20 % band)"
            )
        }

        let measured: [String: DeliveryReport.Value] = [
            "mean": .number(deltaE.mean),
            "p50": .number(deltaE.p50),
            "p95": .number(deltaE.p95),
            "p99": .number(deltaE.p99),
            "max": .number(deltaE.max),
            "fractionAbove2": .number(deltaE.fractionAbove2),
            "fractionAbove3": .number(deltaE.fractionAbove3),
            "fractionAbove5": .number(deltaE.fractionAbove5),
            "previewWidth": .integer(target.width),
            "previewHeight": .integer(target.height),
            "previewLongEdge": .integer(input.previewLongEdge),
            "meanLimit": .number(previewMeanDeltaELimit),
            "p99Limit": .number(previewP99DeltaELimit),
            "fractionAbove5Limit": .number(fractionFailLimit),
            "fractionAbove5WarningLimit": .number(fractionWarningLimit),
            "profileMapResolution": .text(input.profile.mapResolution.rawValue),
            "pixelCount": .integer(deltaE.pixelCount),
        ]
        let detail: String
        if passed {
            detail = "preview-scale render vs the delivered HDR decode downscaled to \(target): ΔE2000 mean "
                + "\(String(format: "%.4f", deltaE.mean)), p95 \(String(format: "%.4f", deltaE.p95)), p99 "
                + "\(String(format: "%.4f", deltaE.p99)), "
                + "\(String(format: "%.3f", deltaE.fractionAbove5 * 100)) % of pixels above ΔE 5 (expected at highlight edges only)."
        } else {
            detail = "failed: preview vs delivered ΔE2000 mean \(String(format: "%.4f", deltaE.mean)), p99 "
                + "\(String(format: "%.4f", deltaE.p99)), fractionAbove5 \(String(format: "%.4f", deltaE.fractionAbove5)) "
                + "exceed the gross-disagreement limits (mean < \(previewMeanDeltaELimit), p99 < \(previewP99DeltaELimit), "
                + "fractionAbove5 <= \(fractionFailLimit)): the preview and the delivery disagree beyond the documented scale difference."
        }
        return DeliveryReport.Check(
            name: "previewAgreement",
            pass: passed,
            detail: detail,
            measured: measured,
            warnings: warnings
        )
    }
}
