// M4.3 real-data calibration probe.
//
// Measures the distributions the M4 delivery verifier's thresholds are frozen against, on the
// already-produced M0 full-resolution deliverable (6000×4000 gain-map HEIC) and the M0 16-bit
// base / authored HDR / 2560 px preview. It links the *real* PhotonCore sources (no copy of the
// maths), so the numbers it prints are produced by exactly the code `photon deliver` runs:
//
//   a. baseDeltaE: delivered HEIC SDR decode vs work/m0/real/sdr.tif (and vs the SourceDecoder
//      base buffer the verifier compares against), both rendered to linear extended P3 float.
//   b. the ImageIO map-stripped fallback copy: made twice, byte-identity checked, then compared
//      with the delivered SDR primary and with sdr.tif (8-bit P3 LSB + ΔE2000).
//   c. previewAgreement: M0 2560 preview HEIC HDR decode vs the full-resolution M0 HEIC HDR
//      decode downscaled with the same Lanczos path; plus the lossless authored comparison
//      (downscaled work/m0/real/hdr.tif, clamped to the recipe cap) that the real verifier sees.
//   d. timings (release: this file and PhotonCore are built with swiftc -O) and the real
//      `DeliveryVerifier.verify` run on the M0 file, which is also the check-level smoke test.
//
// Build/run: see work/m4/probe/notes.md (build.sh compiles PhotonCore from app/Sources).
//
// Outputs: calibration.json (machine-readable) and a human summary on stdout. The markdown report
// work/m4/probe/calibration.md is written by hand from this JSON.

import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

@main
struct CalibrateProbe {
    // MARK: - Paths

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // probe
            .deletingLastPathComponent() // m4
            .deletingLastPathComponent() // work
            .deletingLastPathComponent() // repository root
    }

    static var probeDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }

    static var deliveredHEIC: URL {
        repositoryRoot.appendingPathComponent("work/m0/deliverable/R0003777-M0.heic")
    }
    static var previewHEIC: URL {
        repositoryRoot.appendingPathComponent("work/m0/deliverable/R0003777-M0-2560.heic")
    }
    static var sdrTIFF: URL {
        repositoryRoot.appendingPathComponent("work/m0/real/sdr.tif")
    }
    static var hdrTIFF: URL {
        repositoryRoot.appendingPathComponent("work/m0/real/hdr.tif")
    }
    static var statsJSON: URL {
        repositoryRoot.appendingPathComponent("work/m0/real/stats.json")
    }
    static var recipeJSON: URL {
        repositoryRoot.appendingPathComponent("work/m0/deliverable/R0003777-M0.recipe.json")
    }
    static var sourceTIFF: URL {
        repositoryRoot.appendingPathComponent("samples/sources/R0003777-P3.tif")
    }
    static var outputDirectory: URL {
        probeDirectory.appendingPathComponent("out", isDirectory: true)
    }

    // MARK: - Entry point

    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("calibrate probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let probeStart = Date()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let context = DeliveryImageProbe.makeContext()
        var report: [String: Any] = [
            "probe": "work/m4/probe/calibrate.swift",
            "generatedAt": Recipe.currentTimestamp(),
            "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "note": "M0 full-resolution deliverable R0003777-M0.heic (6000x4000), M0 base sdr.tif, authored hdr.tif, M0 2560 px preview HEIC; links the real PhotonCore.",
        ]

        // MARK: Decode the delivered file (shared by every section)

        var timings: [String: Double] = [:]
        var stopwatch = Date()
        let decoded = try DeliveryImageProbe.decode(deliveredHEIC)
        timings["decodeDelivered"] = Date().timeIntervalSince(stopwatch)
        let ftyp = try DeliveryImageProbe.readFTYP(deliveredHEIC)
        let sdrSize = decoded.sdrSize
        let hdrSize = decoded.hdr.map { PixelSize(width: $0.width, height: $0.height) }
        report["delivered"] = [
            "file": relativePath(deliveredHEIC),
            "bytes": DeliveryImageProbe.fileBytes(deliveredHEIC) ?? 0,
            "sha256": (try? DeliveryImageProbe.sha256(ofFileAt: deliveredHEIC)) ?? "",
            "width": sdrSize.width,
            "height": sdrSize.height,
            "sdrBitsPerComponent": decoded.facts.sdrBitsPerComponent,
            "sdrAlphaInfo": decoded.sdrAlphaInfoName,
            "hdrDecoded": decoded.facts.hdrDecoded,
            "hdrWidth": decoded.facts.hdrWidth,
            "hdrHeight": decoded.facts.hdrHeight,
            "hdrBitsPerComponent": decoded.facts.hdrBitsPerComponent,
            "hdrAlphaInfo": decoded.hdrAlphaInfoName,
            "isoGainMapPresent": decoded.facts.isoGainMapPresent,
            "contentHeadroom": decoded.facts.contentHeadroom,
            "calculatedContentHeadroom": decoded.facts.calculatedContentHeadroom,
            "ftyp": ftypJSON(ftyp),
        ]
        stdout("delivered: \(sdrSize) SDR \(decoded.sdrAlphaInfoName), HDR \(hdrSize.map { "\($0)" } ?? "absent") \(decoded.hdrAlphaInfoName), "
            + "contentHeadroom \(fmt(decoded.facts.contentHeadroom)), calc \(fmt(decoded.facts.calculatedContentHeadroom)), "
            + "brands \(ftyp.majorBrand)/[\(ftyp.compatibleBrands.joined(separator: ","))]")

        // MARK: Section a — baseDeltaE (delivered SDR decode vs the Capture One base)

        stopwatch = Date()
        let sdrTIFFImage = try loadCGImage(sdrTIFF)
        timings["loadSdrTIFF"] = Date().timeIntervalSince(stopwatch)
        guard PixelSize(width: sdrTIFFImage.width, height: sdrTIFFImage.height) == sdrSize else {
            throw ProbeError("sdr.tif is \(sdrTIFFImage.width)x\(sdrTIFFImage.height), delivered SDR is \(sdrSize)")
        }

        stopwatch = Date()
        let baseVsTIFFDeltaE = DeliveryImageProbe.deltaEStats(
            CIImage(cgImage: decoded.sdr),
            CIImage(cgImage: sdrTIFFImage),
            size: sdrSize,
            context: context
        )
        let baseVsTIFFLSB = DeliveryImageProbe.lsbStats(
            CIImage(cgImage: decoded.sdr),
            CIImage(cgImage: sdrTIFFImage),
            size: sdrSize,
            context: context
        )
        timings["baseDeltaE_vs_sdrTIFF"] = Date().timeIntervalSince(stopwatch)

        // The verifier's exact comparison: the SourceDecoder linear-P3 buffer the pipeline holds.
        stopwatch = Date()
        let source = try SourceDecoder.decode(url: sourceTIFF)
        timings["sourceDecode"] = Date().timeIntervalSince(stopwatch)
        stopwatch = Date()
        let baseVsSdrBaseDeltaE = DeliveryImageProbe.deltaEStats(
            reference: source.linear,
            candidate: CIImage(cgImage: decoded.sdr),
            context: context
        )
        let baseVsSdrBaseLSB = DeliveryImageProbe.lsbStats(
            reference: source.linear,
            candidate: CIImage(cgImage: decoded.sdr),
            context: context
        )
        timings["baseDeltaE_vs_sourceBuffer"] = Date().timeIntervalSince(stopwatch)

        report["a_baseDeltaE"] = [
            "deliveredVsSdrTIFF": [
                "deltaE": deltaEJSON(baseVsTIFFDeltaE),
                "lsb8": lsbJSON(baseVsTIFFLSB),
            ],
            "deliveredVsSourceBuffer": [
                "deltaE": deltaEJSON(baseVsSdrBaseDeltaE),
                "lsb8": lsbJSON(baseVsSdrBaseLSB),
            ],
        ]
        stdout("a. baseDeltaE vs sdr.tif: mean \(fmt(baseVsTIFFDeltaE.mean, 4)) p95 \(fmt(baseVsTIFFDeltaE.p95, 4)) "
            + "p99 \(fmt(baseVsTIFFDeltaE.p99, 4)) max \(fmt(baseVsTIFFDeltaE.max, 3)) "
            + "frac>2 \(fmt(baseVsTIFFDeltaE.fractionAbove2 * 100, 3))% | 8-bit LSB mean \(fmt(baseVsTIFFLSB.meanAbsDiff)) "
            + "p99 \(baseVsTIFFLSB.p99) max \(baseVsTIFFLSB.max)")
        stdout("a. baseDeltaE vs SourceDecoder buffer: mean \(fmt(baseVsSdrBaseDeltaE.mean, 4)) "
            + "p95 \(fmt(baseVsSdrBaseDeltaE.p95, 4)) p99 \(fmt(baseVsSdrBaseDeltaE.p99, 4)) "
            + "max \(fmt(baseVsSdrBaseDeltaE.max, 3))")

        // Section a2 — diagnostic only: how much of the base ΔE is 8-bit quantisation (shared by
        // any 8-bit deliverable) versus the HEVC/4:2:0 encode itself. The 16-bit sdr.tif is rendered
        // to 8-bit Display P3 (nothing else changes); comparing the 16-bit and 8-bit renders shows
        // the quantisation floor, and comparing the 8-bit render with the delivered SDR decode
        // isolates the codec. Never a gate; it is the evidence behind the baseDeltaE threshold
        // decision (work/m4/probe/calibration.md, docs/07 §10).
        stopwatch = Date()
        let quantisedSource = try quantised8BitCGImage(from: sdrTIFFImage, context: context)
        let quantisationFloorDeltaE = DeliveryImageProbe.deltaEStats(
            reference: source.linear,
            candidate: CIImage(cgImage: quantisedSource),
            context: context
        )
        let codecLossDeltaE = DeliveryImageProbe.deltaEStats(
            CIImage(cgImage: quantisedSource),
            CIImage(cgImage: decoded.sdr),
            size: sdrSize,
            context: context
        )
        timings["baseDeltaE_quantisationFloorDiagnostic"] = Date().timeIntervalSince(stopwatch)
        report["a2_quantisationFloor"] = [
            "method": "sdr.tif rendered to 8-bit Display P3 (CIContext .RGBA8) vs the 16-bit linear source, then vs the delivered SDR decode",
            "quantisationOnlyDeltaE": deltaEJSON(quantisationFloorDeltaE),
            "codecOnlyDeltaE": deltaEJSON(codecLossDeltaE),
        ]
        stdout("a2. 16-bit -> 8-bit quantisation alone: ΔE mean \(fmt(quantisationFloorDeltaE.mean, 4)) "
            + "p95 \(fmt(quantisationFloorDeltaE.p95, 4)) | 8-bit source vs delivered decode (codec): "
            + "ΔE mean \(fmt(codecLossDeltaE.mean, 4)) p95 \(fmt(codecLossDeltaE.p95, 4)) "
            + "p99 \(fmt(codecLossDeltaE.p99, 4)) max \(fmt(codecLossDeltaE.max, 3))")

        // MARK: Section b — the ImageIO map-stripped fallback copy

        stopwatch = Date()
        let copyAURL = outputDirectory.appendingPathComponent("fallback-a.heic")
        let copyBURL = outputDirectory.appendingPathComponent("fallback-b.heic")
        try DeliveryImageProbe.makeMapStrippedCopy(of: deliveredHEIC, to: copyAURL)
        timings["fallbackWriteA"] = Date().timeIntervalSince(stopwatch)
        stopwatch = Date()
        try DeliveryImageProbe.makeMapStrippedCopy(of: deliveredHEIC, to: copyBURL)
        timings["fallbackWriteB"] = Date().timeIntervalSince(stopwatch)

        let copyAData = try Data(contentsOf: copyAURL)
        let copyBData = try Data(contentsOf: copyBURL)
        let byteIdentical = copyAData == copyBData
        var firstDifferenceJSON: Any = NSNull()
        if !byteIdentical {
            firstDifferenceJSON = firstDifference(copyAData, copyBData)
        }
        let copyFacts = try EncodedHEICValidator.inspect(copyAURL)
        let copyFTYP = try? DeliveryImageProbe.readFTYP(copyAURL)
        let copySize = PixelSize(width: copyFacts.width, height: copyFacts.height)
        let copyImage = try loadCGImage(copyAURL)

        stopwatch = Date()
        let copyVsDeliveredLSB = DeliveryImageProbe.lsbStats(
            CIImage(cgImage: decoded.sdr),
            CIImage(cgImage: copyImage),
            size: sdrSize,
            context: context
        )
        let copyVsDeliveredDeltaE = DeliveryImageProbe.deltaEStats(
            CIImage(cgImage: decoded.sdr),
            CIImage(cgImage: copyImage),
            size: sdrSize,
            context: context
        )
        timings["fallbackCompareVsDelivered"] = Date().timeIntervalSince(stopwatch)

        stopwatch = Date()
        let copyVsTIFFLSB = DeliveryImageProbe.lsbStats(
            CIImage(cgImage: sdrTIFFImage),
            CIImage(cgImage: copyImage),
            size: sdrSize,
            context: context
        )
        let copyVsTIFFDeltaE = DeliveryImageProbe.deltaEStats(
            CIImage(cgImage: sdrTIFFImage),
            CIImage(cgImage: copyImage),
            size: sdrSize,
            context: context
        )
        timings["fallbackCompareVsSdrTIFF"] = Date().timeIntervalSince(stopwatch)

        let copyAlphaName = DeliveryImageProbe.alphaInfoName(copyImage.alphaInfo)
        report["b_fallback"] = [
            "copyA": relativePath(copyAURL),
            "copyBytes": copyAData.count,
            "copySha256": sha256Hex(copyAData),
            "byteIdenticalAcrossTwoWrites": byteIdentical,
            "firstDifference": firstDifferenceJSON,
            "copySdrWidth": copyFacts.width,
            "copySdrHeight": copyFacts.height,
            "copyAlphaInfo": copyAlphaName,
            "copyIsoGainMapPresent": copyFacts.isoGainMapPresent,
            "copyHdrDecoded": copyFacts.hdrDecoded,
            "copyContentHeadroom": copyFacts.contentHeadroom,
            "copyFtyp": copyFTYP.map(ftypJSON) as Any? ?? NSNull(),
            "copyVsDeliveredSdrPrimary": [
                "deltaE": deltaEJSON(copyVsDeliveredDeltaE),
                "lsb8": lsbJSON(copyVsDeliveredLSB),
            ],
            "copyVsSdrTIFF": [
                "deltaE": deltaEJSON(copyVsTIFFDeltaE),
                "lsb8": lsbJSON(copyVsTIFFLSB),
            ],
        ]
        stdout("b. copy: \(copyAData.count) B, ISO aux \(copyFacts.isoGainMapPresent), alpha \(copyAlphaName), "
            + "brands \(copyFTYP?.majorBrand ?? "?")/[\(copyFTYP?.compatibleBrands.joined(separator: ",") ?? "")], "
            + "two writes byte-identical: \(byteIdentical)")
        stdout("b. copy vs delivered SDR: LSB mean \(fmt(copyVsDeliveredLSB.meanAbsDiff)) p99 \(copyVsDeliveredLSB.p99) "
            + "max \(copyVsDeliveredLSB.max), ΔE mean \(fmt(copyVsDeliveredDeltaE.mean, 4)) "
            + "p95 \(fmt(copyVsDeliveredDeltaE.p95, 4)) p99 \(fmt(copyVsDeliveredDeltaE.p99, 4))")
        stdout("b. copy vs sdr.tif: LSB mean \(fmt(copyVsTIFFLSB.meanAbsDiff)) p99 \(copyVsTIFFLSB.p99) "
            + "max \(copyVsTIFFLSB.max), ΔE mean \(fmt(copyVsTIFFDeltaE.mean, 4)) "
            + "p95 \(fmt(copyVsTIFFDeltaE.p95, 4)) p99 \(fmt(copyVsTIFFDeltaE.p99, 4))")

        // MARK: Section c — previewAgreement

        guard let deliveredHDR = decoded.hdr, let hdrSize else {
            throw ProbeError("the delivered M0 HEIC has no HDR decode; previewAgreement cannot be calibrated")
        }
        let previewSourceHDR = try loadHDRCGImage(previewHEIC)
        let previewSourceSDR = try loadCGImage(previewHEIC)
        let previewSize = PixelSize(width: previewSourceHDR.width, height: previewSourceHDR.height)
        guard previewSize == PixelSize(width: previewSourceSDR.width, height: previewSourceSDR.height) else {
            throw ProbeError("preview HEIC SDR/HDR sizes differ")
        }

        stopwatch = Date()
        let previewSDRLinear = try renderLinear(previewSourceSDR, size: previewSize, context: context)
        let previewHDRLinear = try renderLinear(previewSourceHDR, size: previewSize, context: context)
        let deliveredDownscaled = try downscaledLinear(CIImage(cgImage: deliveredHDR), to: previewSize, context: context)
        timings["previewRender"] = Date().timeIntervalSince(stopwatch)

        stopwatch = Date()
        let previewHEICVsDelivered = DeliveryImageProbe.deltaEStats(deliveredDownscaled, previewHDRLinear)
        timings["previewAgreement_encodedPreview"] = Date().timeIntervalSince(stopwatch)

        // The lossless authored comparison: downscale hdr.tif with the same Lanczos path, clamp to
        // the recipe cap (exactly what PreviewRenderer.downscale hands the verifier as preview.hdr),
        // then compare against the delivered HDR decode downscaled. This is the number the M4 gate
        // must tolerate.
        stopwatch = Date()
        let authoredHDRImage = try loadCGImage(hdrTIFF)
        let authoredDownscaled = try downscaledLinear(CIImage(cgImage: authoredHDRImage), to: previewSize, context: context)
        timings["authoredHDRDownscale"] = Date().timeIntervalSince(stopwatch)
        guard authoredDownscaled.size == previewSize else {
            throw ProbeError("authored downscale is \(authoredDownscaled.size), expected \(previewSize)")
        }
        stopwatch = Date()
        let authoredClamped = try HeadroomCap.clamp(authoredDownscaled, cap: 2.5)
        let authoredClampedVsDelivered = DeliveryImageProbe.deltaEStats(authoredClamped, deliveredDownscaled)
        let authoredClampedVsPreviewHEIC = DeliveryImageProbe.deltaEStats(authoredClamped, previewHDRLinear)
        timings["previewAgreement_authoredPreview"] = Date().timeIntervalSince(stopwatch)

        report["c_previewAgreement"] = [
            "previewWidth": previewSize.width,
            "previewHeight": previewSize.height,
            "previewLongEdge": max(previewSize.width, previewSize.height),
            "encodedPreviewHeicVsDeliveredDownscaled": deltaEJSON(previewHEICVsDelivered),
            "authoredDownscaledClampedVsDeliveredDownscaled": deltaEJSON(authoredClampedVsDelivered),
            "authoredDownscaledClampedVsEncodedPreviewHeic": deltaEJSON(authoredClampedVsPreviewHEIC),
        ]
        stdout("c. preview HEIC vs delivered downscaled: mean \(fmt(previewHEICVsDelivered.mean, 4)) "
            + "p95 \(fmt(previewHEICVsDelivered.p95, 4)) p99 \(fmt(previewHEICVsDelivered.p99, 4)) "
            + "max \(fmt(previewHEICVsDelivered.max, 3)) frac>2/3/5 "
            + "\(fmt(previewHEICVsDelivered.fractionAbove2 * 100, 3))/"
            + "\(fmt(previewHEICVsDelivered.fractionAbove3 * 100, 3))/"
            + "\(fmt(previewHEICVsDelivered.fractionAbove5 * 100, 3)) %")
        stdout("c. authored downscaled (clamped) vs delivered downscaled: mean \(fmt(authoredClampedVsDelivered.mean, 4)) "
            + "p95 \(fmt(authoredClampedVsDelivered.p95, 4)) p99 \(fmt(authoredClampedVsDelivered.p99, 4)) "
            + "max \(fmt(authoredClampedVsDelivered.max, 3)) frac>2/3/5 "
            + "\(fmt(authoredClampedVsDelivered.fractionAbove2 * 100, 3))/"
            + "\(fmt(authoredClampedVsDelivered.fractionAbove3 * 100, 3))/"
            + "\(fmt(authoredClampedVsDelivered.fractionAbove5 * 100, 3)) %")
        stdout("c. authored downscaled (clamped) vs preview HEIC: mean \(fmt(authoredClampedVsPreviewHEIC.mean, 4)) "
            + "p95 \(fmt(authoredClampedVsPreviewHEIC.p95, 4)) p99 \(fmt(authoredClampedVsPreviewHEIC.p99, 4))")

        // MARK: The real verifier on the M0 file (check-level smoke test + total timing)

        let recipeData = try Data(contentsOf: recipeJSON)
        let recipe = try JSONDecoder().decode(Recipe.self, from: recipeData)
        try recipe.validate()
        let stats = try loadJSON(statsJSON)
        let authored = authoredFacts(from: stats)
        let fallbackPath = outputDirectory.appendingPathComponent("fallback-sdr.heic")

        // The pipeline's own preview pair: downscale the bit-identical 16-bit base and the authored
        // HDR rendition (`hdr.tif` readback, bit-identical to the M0 buffer) with the same
        // PreviewRenderer.downscale path `photon deliver` uses, then clamp to the cap. This is the
        // float pair the real verifier compares against — not the encoded M0 preview HEIC.
        stopwatch = Date()
        let authoredHDRLinear = try renderLinear(authoredHDRImage, size: sdrSize, context: context)
        let pipelinePreviewLongEdge = PreviewRenderer.previewLongEdge(for: sdrSize, limit: 2560)
        let previewPair = try PreviewRenderer.downscale(
            base: source.linear,
            hdr: authoredHDRLinear,
            longEdge: pipelinePreviewLongEdge,
            headroomCap: Float(recipe.hdr.headroomCap)
        )
        timings["pipelinePreviewPair"] = Date().timeIntervalSince(stopwatch)
        guard previewPair.size == previewSize else {
            throw ProbeError("pipeline preview pair is \(previewPair.size), M0 preview HEIC is \(previewSize)")
        }
        let previewPairVsM0PreviewDeltaE = DeliveryImageProbe.deltaEStats(previewPair.hdr, previewHDRLinear)
        report["pipelinePreviewPairVsM0PreviewHeic"] = deltaEJSON(previewPairVsM0PreviewDeltaE)
        stdout("c. pipeline float preview pair vs the M0 preview HEIC: ΔE mean "
            + "\(fmt(previewPairVsM0PreviewDeltaE.mean, 4)) p95 \(fmt(previewPairVsM0PreviewDeltaE.p95, 4)) "
            + "(confirms the M0 preview HEIC is the same rendering, with its own codec loss)")

        let input = DeliveryVerificationInput(
            encodedHEIC: deliveredHEIC,
            fallbackHEIC: fallbackPath,
            sdrBase: source.linear,
            authoredPeak: authored.peak,
            fractionAboveOne: authored.fractionAboveOne,
            fractionAtCap: authored.fractionAtCap,
            preview: previewPair,
            previewLongEdge: pipelinePreviewLongEdge,
            recipe: recipe,
            source: DeliverySourceFacts(
                path: relativePath(sourceTIFF),
                sha256: source.sha256,
                size: source.size,
                profileName: source.profileName,
                bitsPerComponent: source.bitsPerComponent
            )
        )
        // The source path is provenance only; the recipe identity is what the check compares.
        stopwatch = Date()
        let checks = try DeliveryVerifier.verify(input)
        timings["verifyTotal"] = Date().timeIntervalSince(stopwatch)
        report["verifier"] = [
            "encodedHEIC": relativePath(deliveredHEIC),
            "fallbackHEIC": relativePath(fallbackPath),
            "checks": try checksJSON(checks),
            "allPass": checks.allSatisfy(\.passed),
        ]
        stdout("verifier on the M0 file: \(checks.filter(\.passed).count)/\(checks.count) PASS in \(fmt(timings["verifyTotal"] ?? 0, 3)) s")
        for check in checks {
            stdout("  \(check.passed ? "PASS" : "FAIL") \(check.name): \(check.detail)")
        }

        // MARK: Timing summary (per-check dominant costs, release build)

        timings["probeTotal"] = Date().timeIntervalSince(probeStart)
        report["timingsSeconds"] = timings
        stdout("timings (s): " + timings.keys.sorted().map { "\($0)=\(fmt(timings[$0] ?? 0, 3))" }.joined(separator: " "))

        // MARK: Write the JSON

        let jsonURL = probeDirectory.appendingPathComponent("calibration.json")
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: jsonURL)
        stdout("wrote \(relativePath(jsonURL))")
    }

    // MARK: - Authored rendition facts (from the M0 evidence, not re-rendered)

    /// M0 recorded the authored rendition facts on the float pixels before encoding (docs/05 §3.2);
    /// the verifier must be calibrated against those numbers, so read them from the M0 stats
    /// evidence rather than inventing them. `readback_*` are the read-back of `hdr.tif`, which M0
    /// proved bit-identical to the authored buffer (`hdr.readback_matches_buffer = true`).
    static func authoredFacts(from stats: [String: Any]) -> (peak: Float, fractionAboveOne: Double, fractionAtCap: Double) {
        let hdr = stats["hdr"] as? [String: Any] ?? [:]
        let peak = (hdr["readback_peak_linear"] as? NSNumber)?.floatValue ?? 2.5
        let fractionAboveOne = (hdr["readback_fraction_pixels_gt_1"] as? NSNumber)?.doubleValue ?? 0.10941866666666666
        let fractionAtCap = (hdr["readback_fraction_pixels_at_cap"] as? NSNumber)?.doubleValue ?? 0.004306083333333334
        return (peak, fractionAboveOne, fractionAtCap)
    }

    // MARK: - Image loading / rendering helpers

    static func loadCGImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ProbeError("ImageIO cannot open \(relativePath(url))")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProbeError("ImageIO cannot decode \(relativePath(url))")
        }
        return image
    }

    static func loadHDRCGImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ProbeError("ImageIO cannot open \(relativePath(url))")
        }
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary
        ) else {
            throw ProbeError("ImageIO cannot HDR-decode \(relativePath(url))")
        }
        return image
    }

    static func renderLinear(_ image: CGImage, size: PixelSize, context: CIContext) throws -> LinearImage {
        try PreviewRenderer.render(CIImage(cgImage: image), size: size, context: context)
    }

    /// Renders a decoded 16-bit image to a full-resolution 8-bit Display P3 `CGImage` (the
    /// "one 8-bit quantisation" reference for the a2 diagnostic). Strips bound the working memory;
    /// the destination rows are placed at the CGImage row index so the buffer stays top-down.
    static func quantised8BitCGImage(from image: CGImage, context: CIContext) throws -> CGImage {
        let width = image.width
        let height = image.height
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        let ciImage = CIImage(cgImage: image)
        bytes.withUnsafeMutableBytes { raw in
            var blockStart = 0
            while blockStart < height {
                let rows = min(256, height - blockStart)
                let ciY = height - blockStart - rows
                let destination = raw.baseAddress!.advanced(by: blockStart * rowBytes)
                context.render(
                    ciImage,
                    toBitmap: destination,
                    rowBytes: rowBytes,
                    bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                    format: .RGBA8,
                    colorSpace: DeliveryImageProbe.displayP3
                )
                blockStart += rows
            }
        }
        let data = bytes.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw ProbeError("cannot create a data provider for the 8-bit quantisation reference")
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: DeliveryImageProbe.displayP3,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ProbeError("cannot create the 8-bit quantisation reference CGImage")
        }
        return cgImage
    }

    static func downscaledLinear(_ image: CIImage, to size: PixelSize, context: CIContext) throws -> LinearImage {
        let lanczos = PreviewRenderer.lanczos(image, to: size)
        return try PreviewRenderer.render(lanczos, size: size, context: context)
    }

    static func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError("\(relativePath(url)) is not a JSON object")
        }
        return object
    }

    // MARK: - JSON shaping

    static func deltaEJSON(_ stats: DeliveryImageProbe.DeltaEStats) -> [String: Any] {
        [
            "mean": stats.mean,
            "p50": stats.p50,
            "p95": stats.p95,
            "p99": stats.p99,
            "max": stats.max,
            "fractionAbove2": stats.fractionAbove2,
            "fractionAbove3": stats.fractionAbove3,
            "fractionAbove5": stats.fractionAbove5,
            "pixelCount": stats.pixelCount,
            "nonFiniteCount": stats.nonFiniteCount,
        ]
    }

    static func lsbJSON(_ stats: DeliveryImageProbe.LSBStats) -> [String: Any] {
        [
            "meanAbsDiff": stats.meanAbsDiff,
            "p50": stats.p50,
            "p90": stats.p90,
            "p99": stats.p99,
            "max": stats.max,
            "fractionNonZero": stats.fractionNonZero,
            "sampleCount": stats.sampleCount,
        ]
    }

    static func ftypJSON(_ ftyp: DeliveryImageProbe.FTYP) -> [String: Any] {
        [
            "majorBrand": ftyp.majorBrand,
            "minorVersion": Int(ftyp.minorVersion),
            "compatibleBrands": ftyp.compatibleBrands,
            "boxSize": ftyp.boxSize,
            "isHEIF": ftyp.isHEIF,
            "tmapBrand": ftyp.hasTMap,
        ]
    }

    static func checksJSON(_ checks: [DeliveryReport.Check]) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(checks)
        return try JSONSerialization.jsonObject(with: data)
    }

    static func firstDifference(_ lhs: Data, _ rhs: Data) -> [String: Any] {
        let shared = min(lhs.count, rhs.count)
        var offset = 0
        while offset < shared, lhs[offset] == rhs[offset] { offset += 1 }
        return [
            "offset": offset,
            "lhsBytes": lhs.count,
            "rhsBytes": rhs.count,
            "lhsByte": offset < lhs.count ? Int(lhs[offset]) : -1,
            "rhsByte": offset < rhs.count ? Int(rhs[offset]) : -1,
        ]
    }

    // MARK: - Small utilities

    static func relativePath(_ url: URL) -> String {
        let root = repositoryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    static func sha256Hex(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fmt(_ value: Double, _ decimals: Int = 3) -> String {
        String(format: "%.\(decimals)f", value)
    }

    static func stdout(_ line: String) {
        print(line)
    }

    struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
