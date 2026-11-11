import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest

import ContractKit
@testable import EngineKit

/// Opt-in benchmark for `DeliveryVerifier` on the rejected R0003777 delivery
/// (`work/p3-accept/bd486ca6…/rejected/5314fd618b56/`).
///
/// Not part of `make server-test`: it needs the gitignored `fixtures/media/` and `work/` artifacts
/// and it takes ~3 min (debug build, 24 Mpx, scalar ΔE2000). It is skipped unless
/// `PHOTON_VERIFY_BENCH=1`, so the default suite pays only the compile. The fast
/// `testFastDeltaEMatchesProductionMath` parity check does run in the default suite (< 1 s).
///
///     cd server && PHOTON_VERIFY_BENCH=1 TMPDIR=$PWD/../.tmp-verify \
///       CLANG_MODULE_CACHE_PATH=$PWD/../.mc-verify \
///       swift test --disable-sandbox --scratch-path ../.build-verify \
///       --filter VerifyPerformanceBenchmark
///
/// Add `PHOTON_VERIFY_BENCH_EXPERIMENTS=1` for the optimisation prototypes (parallel strips,
/// fast scalar ΔE, parallel LSB): that adds ~4 full-resolution passes (~2 more minutes).
///
/// The per-check numbers are measured with the same public `DeliveryImageProbe` /
/// `PreviewRenderer` calls the verifier makes (the check bodies themselves are private), in the
/// same order, on a warm shared `CIContext` (the pipeline's preview downscale runs first, exactly
/// as in `DeliveryPipeline.deliver`). The total is measured directly on `DeliveryVerifier.verify`.
final class VerifyPerformanceBenchmarkTests: XCTestCase {
    // MARK: - Inputs

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // EngineKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // server
        .deletingLastPathComponent() // repo root

    private static let rejectedDirectory = repoRoot.appendingPathComponent(
        "work/p3-accept/bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116/rejected/5314fd618b56",
        isDirectory: true
    )
    private static let heicURL = rejectedDirectory.appendingPathComponent("R0003777-P3-hdr.heic")
    private static let recipeURL = rejectedDirectory.appendingPathComponent("R0003777-P3.recipe.json")
    private static let sourceURL = repoRoot.appendingPathComponent("fixtures/media/sources/R0003777-P3.tif")

    /// The rejected report's `previewAgreement` mean (2026-11-05). The current build should no
    /// longer reproduce it: the 2026-11-09 `CIRender` fix removed the cold-context zero-buffer race
    /// (docs/plans/preview-agreement-investigation.md).
    private static let rejectedPreviewMean = 40.1085

    // MARK: - Entry point

    func testVerifyPerformanceBenchmark() throws {
        guard ProcessInfo.processInfo.environment["PHOTON_VERIFY_BENCH"] == "1" else {
            throw XCTSkip(
                "opt-in benchmark: set PHOTON_VERIFY_BENCH=1 (≈3 min; needs fixtures/media/ and work/)"
            )
        }
        for url in [Self.heicURL, Self.recipeURL, Self.sourceURL]
        where !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("missing benchmark input: \(url.path)")
        }
        let experiments = ProcessInfo.processInfo.environment["PHOTON_VERIFY_BENCH_EXPERIMENTS"] == "1"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-verify-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = ContinuousClock()

        // MARK: Setup — rebuild the pipeline state the verifier is handed (not part of verify)

        var setupStart = clock.now
        let source = try SourceDecoder.decode(url: Self.sourceURL)
        let sourceDecodeSeconds = Self.seconds(clock.now - setupStart)

        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: Self.recipeURL))
        try recipe.validate()
        let toneMap = try ToneMapKind.named(recipe.base.toneMap)
        let shape = try HighlightShape(recipe: recipe.hdr)

        setupStart = clock.now
        let sdrBase = try ToneMapper.sdrBase(from: source.linear, toneMap: toneMap)
        let toneMapSeconds = Self.seconds(clock.now - setupStart)

        setupStart = clock.now
        let hdrRendition = try HDRRendition.render(base: sdrBase, shape: shape)
        let hdrSeconds = Self.seconds(clock.now - setupStart)

        setupStart = clock.now
        let previewLongEdge = PreviewRenderer.previewLongEdge(for: source.size, limit: 2560)
        let preview = try PreviewRenderer.downscale(
            base: sdrBase,
            hdr: hdrRendition.image,
            longEdge: previewLongEdge,
            headroomCap: shape.headroomCap
        )
        let previewSeconds = Self.seconds(clock.now - setupStart)

        let input = DeliveryVerificationInput(
            encodedHEIC: Self.heicURL,
            fallbackHEIC: directory.appendingPathComponent("R0003777-P3-sdr.heic"),
            sdrBase: sdrBase,
            authoredPeak: hdrRendition.authoredPeak,
            fractionAboveOne: hdrRendition.fractionAboveOne,
            fractionAtCap: hdrRendition.fractionAtCap,
            preview: preview,
            previewLongEdge: previewLongEdge,
            recipe: recipe,
            source: DeliverySourceFacts(
                path: source.url.standardizedFileURL.path,
                sha256: source.sha256,
                size: source.size,
                profileName: source.profileName,
                bitsPerComponent: source.bitsPerComponent
            ),
            profile: try HEICEncodeOptions(
                bitDepth: .eight, quality: 0.85, mapResolution: .full, mapKind: .isoRGB
            )
        )

        // MARK: Total verify

        let verifyStart = clock.now
        let checks = try DeliveryVerifier.verify(input)
        let totalVerify = Self.seconds(clock.now - verifyStart)

        // MARK: Per-check components (same calls the private check bodies make)

        var decodeSeconds = 0.0
        var containerSeconds = 0.0
        var clippingSeconds = 0.0
        var baseDeltaESeconds = 0.0
        var baseDeltaERenderSeconds = 0.0
        var baseDeltaELoopSeconds = 0.0
        var baseLSBSeconds = 0.0
        var fallbackCopySeconds = 0.0
        var fallbackInspectSeconds = 0.0
        var fallbackDecodeSeconds = 0.0
        var fallbackFTYPSeconds = 0.0
        var fallbackLSBSeconds = 0.0
        var fallbackDeltaESeconds = 0.0
        var fallbackSHASeconds = 0.0
        var previewRenderSeconds = 0.0
        var previewDeltaESeconds = 0.0
        var previewMean = 0.0

        let decoded: DeliveryImageProbe.DecodedDelivery
        do {
            let start = clock.now
            decoded = try DeliveryImageProbe.decode(Self.heicURL)
            decodeSeconds = Self.seconds(clock.now - start)
        }
        let context = DeliveryImageProbe.makeContext()
        let sdrCI = CIImage(cgImage: decoded.sdr)
        guard let hdr = decoded.hdr else {
            XCTFail("the rejected delivery must carry an HDR decode")
            return
        }
        let hdrCI = CIImage(cgImage: hdr)
        let sdrSize = decoded.sdrSize
        let hdrSize = PixelSize(width: hdr.width, height: hdr.height)

        do {
            let start = clock.now
            _ = try DeliveryImageProbe.readFTYP(Self.heicURL)
            containerSeconds = Self.seconds(clock.now - start)
        }

        do {
            let start = clock.now
            _ = try DeliveryImageProbe.linearStats(
                candidate: hdrCI,
                size: hdrSize,
                cap: recipe.hdr.headroomCap,
                contentHeadroom: decoded.facts.contentHeadroom > 1.0 ? decoded.facts.contentHeadroom : nil,
                context: context
            )
            clippingSeconds = Self.seconds(clock.now - start)
        }

        var baseDeltaEStats: DeliveryImageProbe.DeltaEStats?
        do {
            let start = clock.now
            baseDeltaEStats = try DeliveryImageProbe.deltaEStats(reference: sdrBase, candidate: sdrCI, context: context)
            baseDeltaESeconds = Self.seconds(clock.now - start)
        }
        baseDeltaERenderSeconds = try Self.renderOnly(
            candidate: sdrCI,
            size: sdrSize,
            context: context,
            clock: clock
        )
        baseDeltaELoopSeconds = max(0, baseDeltaESeconds - baseDeltaERenderSeconds)

        var baseLSBStats: DeliveryImageProbe.LSBStats?
        do {
            let start = clock.now
            baseLSBStats = try DeliveryImageProbe.lsbStats(reference: sdrBase, candidate: sdrCI, context: context)
            baseLSBSeconds = Self.seconds(clock.now - start)
        }

        // fallback: copy write, inspect, copy decode, then the two comparisons (exactly the check).
        do {
            let start = clock.now
            try DeliveryImageProbe.makeMapStrippedCopy(of: Self.heicURL, to: input.fallbackHEIC)
            fallbackCopySeconds = Self.seconds(clock.now - start)
        }
        do {
            let start = clock.now
            _ = try EncodedHEICValidator.inspect(input.fallbackHEIC)
            fallbackInspectSeconds = Self.seconds(clock.now - start)
        }
        var copyImage: CGImage?
        do {
            let start = clock.now
            if let copySource = CGImageSourceCreateWithURL(input.fallbackHEIC as CFURL, nil) {
                copyImage = CGImageSourceCreateImageAtIndex(copySource, 0, nil)
            }
            fallbackDecodeSeconds = Self.seconds(clock.now - start)
        }
        do {
            let start = clock.now
            _ = try DeliveryImageProbe.readFTYP(input.fallbackHEIC)
            fallbackFTYPSeconds = Self.seconds(clock.now - start)
        }
        if let copyImage {
            let copyCI = CIImage(cgImage: copyImage)
            do {
                let start = clock.now
                _ = try DeliveryImageProbe.lsbStats(sdrCI, copyCI, size: sdrSize, context: context)
                fallbackLSBSeconds = Self.seconds(clock.now - start)
            }
            do {
                let start = clock.now
                _ = try DeliveryImageProbe.deltaEStats(sdrCI, copyCI, size: sdrSize, context: context)
                fallbackDeltaESeconds = Self.seconds(clock.now - start)
            }
        }
        do {
            let start = clock.now
            _ = try DeliveryImageProbe.sha256(ofFileAt: input.fallbackHEIC)
            fallbackSHASeconds = Self.seconds(clock.now - start)
        }

        // previewAgreement: Lanczos + one preview-scale render + the ΔE loop over the preview.
        var deliveredPreview: LinearImage?
        do {
            let scaled = hdrSize == preview.size ? hdrCI : PreviewRenderer.lanczos(hdrCI, to: preview.size)
            let start = clock.now
            deliveredPreview = try PreviewRenderer.render(scaled, size: preview.size, context: context)
            previewRenderSeconds = Self.seconds(clock.now - start)
        }
        if let deliveredPreview {
            let start = clock.now
            let deltaE = DeliveryImageProbe.deltaEStats(deliveredPreview, preview.hdr)
            previewDeltaESeconds = Self.seconds(clock.now - start)
            previewMean = deltaE.mean
        }

        // MARK: Report

        let fallbackSeconds = fallbackCopySeconds + fallbackInspectSeconds + fallbackDecodeSeconds
            + fallbackFTYPSeconds + fallbackLSBSeconds + fallbackDeltaESeconds + fallbackSHASeconds
        let previewAgreementSeconds = previewRenderSeconds + previewDeltaESeconds
        let baseDeltaETotal = baseDeltaESeconds + baseLSBSeconds
        let measuredSum = decodeSeconds + containerSeconds + clippingSeconds
            + baseDeltaETotal + fallbackSeconds + previewAgreementSeconds

        print("")
        print("=== DeliveryVerifier benchmark — R0003777-P3 (rejected 5314fd618b56) ===")
        print(String(format: "image %@, %.1f Mpx; debug build (swift test); macOS 27 / M1 Max",
                     "\(sdrSize)", Double(sdrSize.pixelCount) / 1_000_000))
        print("")
        print("setup (pipeline, not verifier):")
        Self.printRow("source decode", sourceDecodeSeconds, totalVerify, indent: 1)
        Self.printRow("tone map (\(toneMap.name))", toneMapSeconds, totalVerify, indent: 1)
        Self.printRow("HDR rendition", hdrSeconds, totalVerify, indent: 1)
        Self.printRow("preview downscale", previewSeconds, totalVerify, indent: 1)
        print("")
        print("verify total: \(String(format: "%.3f", totalVerify)) s")
        print("")
        print("check                    seconds   % verify")
        Self.printRow("decode (shared)", decodeSeconds, totalVerify)
        Self.printRow("container", containerSeconds, totalVerify)
        Self.printRow("identity", 0, totalVerify)
        Self.printRow("alpha", 0, totalVerify)
        Self.printRow("headroom", 0, totalVerify)
        Self.printRow("clipping", clippingSeconds, totalVerify)
        Self.printRow("baseDeltaE", baseDeltaETotal, totalVerify)
        Self.printRow("ΔE pass", baseDeltaESeconds, totalVerify, indent: 1)
        Self.printRow("render only (float)", baseDeltaERenderSeconds, totalVerify, indent: 2)
        Self.printRow("ΔE loop", baseDeltaELoopSeconds, totalVerify, indent: 2)
        Self.printRow("LSB pass", baseLSBSeconds, totalVerify, indent: 1)
        Self.printRow("fallback", fallbackSeconds, totalVerify)
        Self.printRow("map-stripped copy write", fallbackCopySeconds, totalVerify, indent: 1)
        Self.printRow("inspect (decode #1)", fallbackInspectSeconds, totalVerify, indent: 1)
        Self.printRow("copy decode (#2)", fallbackDecodeSeconds, totalVerify, indent: 1)
        Self.printRow("copy ftyp", fallbackFTYPSeconds, totalVerify, indent: 1)
        Self.printRow("LSB pair", fallbackLSBSeconds, totalVerify, indent: 1)
        Self.printRow("ΔE pair", fallbackDeltaESeconds, totalVerify, indent: 1)
        Self.printRow("sha256", fallbackSHASeconds, totalVerify, indent: 1)
        Self.printRow("previewAgreement", previewAgreementSeconds, totalVerify)
        Self.printRow("preview render", previewRenderSeconds, totalVerify, indent: 1)
        Self.printRow("ΔE at preview scale", previewDeltaESeconds, totalVerify, indent: 1)
        print("")
        Self.printRow("sum of measured components", measuredSum, totalVerify)
        Self.printRow("unattributed (verify - sum)", totalVerify - measuredSum, totalVerify)
        print("")
        print("checks:")
        for check in checks {
            print("  \(check.name): \(check.passed ? "PASS" : "FAIL") — \(check.detail.prefix(110))")
        }
        print("")
        print(String(format: "previewAgreement ΔE mean now %.4f (rejected report 2026-11-05: %.4f)",
                     previewMean, Self.rejectedPreviewMean))

        // MARK: Experiments (opt-in)

        guard experiments else {
            print("")
            print("experiments skipped: set PHOTON_VERIFY_BENCH_EXPERIMENTS=1 for the prototypes")
            return
        }

        print("")
        print("=== experiments (same reference/candidate, full resolution) ===")
        let cores = ProcessInfo.processInfo.activeProcessorCount
        print("activeProcessorCount = \(cores)")

        // Production math, parallel, twice: a warm-up artefact would show up as a fast second run.
        let parallelProduction1 = try Self.parallelDeltaEStats(
            reference: sdrBase,
            candidate: sdrCI,
            context: context,
            concurrency: 0,
            labFast: false,
            deltaEFast: false
        )
        let parallelProduction2 = try Self.parallelDeltaEStats(
            reference: sdrBase,
            candidate: sdrCI,
            context: context,
            concurrency: 0,
            labFast: false,
            deltaEFast: false
        )
        let serialFast = try Self.timedDeltaE(reference: sdrBase, candidate: sdrCI, context: context, fastMath: true)
        // Isolates the cause: fast `lab` (scalar constants, no [[Double]] subscripting) with the
        // production `deltaE2000` (libm pow/sin/cos).
        let parallelFastLabOnly = try Self.parallelDeltaEStats(
            reference: sdrBase,
            candidate: sdrCI,
            context: context,
            concurrency: 0,
            labFast: true,
            deltaEFast: false
        )
        let parallelFast = try Self.parallelDeltaEStats(
            reference: sdrBase,
            candidate: sdrCI,
            context: context,
            concurrency: 0,
            labFast: true,
            deltaEFast: true
        )
        let parallelLSB = try Self.parallelLSBStats(reference: sdrBase, candidate: sdrCI, context: context)

        print("")
        print("ΔE pass (24 Mpx)                        seconds   vs serial")
        Self.printSpeedup("serial, production math", baseDeltaESeconds, baseDeltaESeconds)
        Self.printSpeedup("serial, fast math", serialFast.seconds, baseDeltaESeconds)
        Self.printSpeedup("parallel strips, production math", parallelProduction1.seconds, baseDeltaESeconds)
        Self.printSpeedup("parallel strips, production math (2nd)", parallelProduction2.seconds, baseDeltaESeconds)
        Self.printSpeedup("parallel strips, fast lab only", parallelFastLabOnly.seconds, baseDeltaESeconds)
        Self.printSpeedup("parallel strips + fast math", parallelFast.seconds, baseDeltaESeconds)
        print("")
        print("LSB pass (24 Mpx)                       seconds   vs serial")
        Self.printSpeedup("serial, production", baseLSBSeconds, baseLSBSeconds)
        Self.printSpeedup("parallel strips", parallelLSB.seconds, baseLSBSeconds)
        print("")
        let serialMean = baseDeltaEStats?.mean ?? 0
        let serialP95 = baseDeltaEStats?.p95 ?? 0
        print(String(
            format: "semantics: serial mean %.6f / p95 %.4f (n=%d); parallel mean %.6f / p95 %.4f (n=%d); "
                + "parallel+fast mean %.6f / p95 %.4f (n=%d)",
            serialMean,
            serialP95,
            baseDeltaEStats?.pixelCount ?? 0,
            parallelProduction2.mean,
            parallelProduction2.p95,
            parallelProduction2.count,
            parallelFast.mean,
            parallelFast.p95,
            parallelFast.count
        ))
        print(String(format: "fast lab + production ΔE: mean %.6f / p95 %.4f (n=%d)",
                     parallelFastLabOnly.mean, parallelFastLabOnly.p95, parallelFastLabOnly.count))
        print(String(format: "fast-math serial mean %.6f / p95 %.4f", serialFast.mean, serialFast.p95))
        print(String(format: "parallel LSB mean %.6f / p99 %d (serial mean %.6f / p99 %d, n=%d)",
                     parallelLSB.mean, parallelLSB.p99,
                     baseLSBStats?.meanAbsDiff ?? 0,
                     baseLSBStats?.p99 ?? 0,
                     parallelLSB.count))

        // Projected verify: every ΔE pass and every LSB pass becomes parallel+fast. The fallback
        // pair loops over the same 24 Mpx (two renders per strip, negligible: render-only is
        // ~0.04 s/pass), so the 24 Mpx parallel time applies to it; the preview ΔE scales by area.
        let previewScale = Double(preview.size.pixelCount) / Double(sdrSize.pixelCount)
        let projectedDeltaE = parallelFast.seconds * 2 + parallelFast.seconds * previewScale
        let projectedLSB = parallelLSB.seconds * 2
        let projected = totalVerify
            - (baseDeltaESeconds + fallbackDeltaESeconds + previewDeltaESeconds)
            - (baseLSBSeconds + fallbackLSBSeconds)
            + projectedDeltaE + projectedLSB
        print("")
        print("projected verify (parallel+fast ΔE, parallel LSB):")
        print(String(
            format: "  %.3f s -> %.3f s  (ΔE %.3f -> %.3f s; LSB %.3f -> %.3f s)",
            totalVerify, projected,
            baseDeltaESeconds + fallbackDeltaESeconds + previewDeltaESeconds, projectedDeltaE,
            baseLSBSeconds + fallbackLSBSeconds, projectedLSB
        ))
    }

    // MARK: - Prototype parity (fast, runs in the default suite)

    /// Proves the `FastColorimetry` prototype used by the experiments is the same CIEDE2000
    /// formulation as `Colorimetry` (max difference ~1e-12 over 200k random linear-P3 pairs), so
    /// the measured speedup is a speedup of the same check, not a different one.
    func testFastDeltaEMatchesProductionMath() throws {
        var rng = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
        var maxDifference = 0.0
        var nonFiniteMismatch = 0
        for _ in 0..<200_000 {
            let lhs = RGBA(
                r: Float(rng.nextUnit()),
                g: Float(rng.nextUnit()),
                b: Float(rng.nextUnit())
            )
            let rhs = RGBA(
                r: Float(rng.nextUnit()),
                g: Float(rng.nextUnit()),
                b: Float(rng.nextUnit())
            )
            let production = Colorimetry.deltaE2000(Colorimetry.lab(lhs), Colorimetry.lab(rhs))
            let fast = FastColorimetry.deltaE2000(lhs, rhs)
            if production.isFinite != fast.isFinite {
                nonFiniteMismatch += 1
                continue
            }
            if production.isFinite {
                maxDifference = max(maxDifference, abs(production - fast))
            }
        }
        print(String(format: "fast ΔE2000 parity: max |production - fast| = %.3e, non-finite mismatches = %d",
                     maxDifference, nonFiniteMismatch))
        XCTAssertEqual(nonFiniteMismatch, 0, "the fast prototype must agree on which pairs are finite")
        XCTAssertLessThan(maxDifference, 1e-9, "the fast prototype must be the same CIEDE2000 formulation")
    }

    // MARK: - Helpers

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func printRow(_ name: String, _ seconds: Double, _ total: Double, indent: Int = 0) {
        let label = String(repeating: "  ", count: indent) + name
        let padded = label.count > 36 ? String(label.prefix(36)) : label.padding(toLength: 36, withPad: " ", startingAt: 0)
        let percent = total > 0 ? seconds / total * 100 : 0
        print("  \(padded) \(String(format: "%8.3f", seconds)) \(String(format: "%8.2f", percent)) %")
    }

    private static func printSpeedup(_ name: String, _ seconds: Double, _ baseline: Double) {
        let padded = name.count > 34 ? String(name.prefix(34)) : name.padding(toLength: 34, withPad: " ", startingAt: 0)
        let speedup = seconds > 0 ? baseline / seconds : 0
        print("  \(padded) \(String(format: "%8.3f", seconds)) \(String(format: "%8.2f", speedup))×")
    }

    /// Renders every strip of `candidate` to linear float and touches one sample, without the ΔE
    /// loop: the render half of a full-resolution pass.
    private static func renderOnly(
        candidate: CIImage,
        size: PixelSize,
        context: CIContext,
        clock: ContinuousClock
    ) throws -> Double {
        let width = size.width
        let height = size.height
        let stripRows = DeliveryImageProbe.stripRows
        var sink: Float = 0
        var buffer = [Float](repeating: 0, count: width * stripRows * 4)
        let start = clock.now
        var blockStart = 0
        while blockStart < height {
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            try buffer.withUnsafeMutableBytes { raw in
                try CIRender.render(
                    candidate,
                    toBitmap: raw.baseAddress!,
                    rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                    format: .RGBAf,
                    colorSpace: DeliveryImageProbe.linearP3,
                    context: context
                )
            }
            sink += buffer[0]
            blockStart += rows
        }
        _ = sink
        return seconds(clock.now - start)
    }

    private static func timedDeltaE(
        reference: LinearImage,
        candidate: CIImage,
        context: CIContext,
        fastMath: Bool
    ) throws -> (seconds: Double, mean: Double, p95: Double) {
        let clock = ContinuousClock()
        var histogram = DeltaEHistogram()
        let width = reference.size.width
        let height = reference.size.height
        let stripRows = DeliveryImageProbe.stripRows
        var buffer = [Float](repeating: 0, count: width * stripRows * 4)
        let start = clock.now
        var blockStart = 0
        while blockStart < height {
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            try buffer.withUnsafeMutableBytes { raw in
                try CIRender.render(
                    candidate,
                    toBitmap: raw.baseAddress!,
                    rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                    format: .RGBAf,
                    colorSpace: DeliveryImageProbe.linearP3,
                    context: context
                )
            }
            buffer.withUnsafeBufferPointer { candidatePixels in
                reference.pixels.withUnsafeBufferPointer { referencePixels in
                    for row in 0..<rows {
                        let referenceBase = (blockStart + row) * width * 4
                        let candidateBase = row * width * 4
                        for x in 0..<width {
                            let referenceIndex = referenceBase + x * 4
                            let candidateIndex = candidateBase + x * 4
                            let lhs = RGBA(
                                r: referencePixels[referenceIndex],
                                g: referencePixels[referenceIndex + 1],
                                b: referencePixels[referenceIndex + 2]
                            )
                            let rhs = RGBA(
                                r: candidatePixels[candidateIndex],
                                g: candidatePixels[candidateIndex + 1],
                                b: candidatePixels[candidateIndex + 2]
                            )
                            if fastMath {
                                histogram.add(FastColorimetry.deltaE2000(lhs, rhs))
                            } else {
                                histogram.add(Colorimetry.deltaE2000(Colorimetry.lab(lhs), Colorimetry.lab(rhs)))
                            }
                        }
                    }
                }
            }
            blockStart += rows
        }
        return (seconds(clock.now - start), histogram.mean, histogram.percentile(95))
    }

    /// Strip-level parallelism prototype: one `CIRender` + one scalar ΔE loop per 256-row strip,
    /// a private histogram per strip, merged at the end. `concurrency = 0` uses all cores.
    ///
    /// `labFast` / `deltaEFast` split the two costs so the experiment can tell the shared
    /// `[[Double]]` matrix in `Colorimetry.lab` (ARC retain/release on a global array) apart from
    /// the libm `pow` calls in `deltaE2000`.
    private static func parallelDeltaEStats(
        reference: LinearImage,
        candidate: CIImage,
        context: CIContext,
        concurrency: Int,
        labFast: Bool,
        deltaEFast: Bool
    ) throws -> (seconds: Double, mean: Double, p95: Double, count: Int) {
        let clock = ContinuousClock()
        let width = reference.size.width
        let height = reference.size.height
        let stripRows = DeliveryImageProbe.stripRows
        let blockCount = (height + stripRows - 1) / stripRows
        var histograms = [DeltaEHistogram](repeating: DeltaEHistogram(), count: blockCount)
        var errors = [Error?](repeating: nil, count: blockCount)
        let semaphore = concurrency > 0 ? DispatchSemaphore(value: concurrency) : nil
        let pixels = reference.pixels

        let start = clock.now
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            semaphore?.wait()
            defer { semaphore?.signal() }
            let blockStart = block * stripRows
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            var buffer = [Float](repeating: 0, count: width * rows * 4)
            do {
                try buffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        candidate,
                        toBitmap: raw.baseAddress!,
                        rowBytes: width * 16,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBAf,
                        colorSpace: DeliveryImageProbe.linearP3,
                        context: context
                    )
                }
                var histogram = DeltaEHistogram()
                pixels.withUnsafeBufferPointer { referencePixels in
                    buffer.withUnsafeBufferPointer { candidatePixels in
                        for row in 0..<rows {
                            let referenceBase = (blockStart + row) * width * 4
                            let candidateBase = row * width * 4
                            for x in 0..<width {
                                let referenceIndex = referenceBase + x * 4
                                let candidateIndex = candidateBase + x * 4
                                let lhs = RGBA(
                                    r: referencePixels[referenceIndex],
                                    g: referencePixels[referenceIndex + 1],
                                    b: referencePixels[referenceIndex + 2]
                                )
                                let rhs = RGBA(
                                    r: candidatePixels[candidateIndex],
                                    g: candidatePixels[candidateIndex + 1],
                                    b: candidatePixels[candidateIndex + 2]
                                )
                                let lhsLab = labFast ? FastColorimetry.lab(lhs) : Colorimetry.lab(lhs)
                                let rhsLab = labFast ? FastColorimetry.lab(rhs) : Colorimetry.lab(rhs)
                                if deltaEFast {
                                    histogram.add(FastColorimetry.deltaE2000(lhsLab, rhsLab))
                                } else {
                                    histogram.add(Colorimetry.deltaE2000(lhsLab, rhsLab))
                                }
                            }
                        }
                    }
                }
                histograms[block] = histogram
            } catch {
                errors[block] = error
            }
        }
        let elapsed = seconds(clock.now - start)
        if let error = errors.compactMap({ $0 }).first { throw error }
        var merged = DeltaEHistogram()
        for histogram in histograms { merged.merge(histogram) }
        return (elapsed, merged.mean, merged.percentile(95), merged.count)
    }

    /// Strip-level parallel LSB prototype: the same 8-bit Display P3 render + `quantised8`
    /// comparison as `DeliveryImageProbe.lsbStats(reference:candidate:context:)`, one histogram per
    /// strip, merged at the end.
    private static func parallelLSBStats(
        reference: LinearImage,
        candidate: CIImage,
        context: CIContext
    ) throws -> (seconds: Double, mean: Double, p99: Int, count: Int) {
        let clock = ContinuousClock()
        let width = reference.size.width
        let height = reference.size.height
        let stripRows = DeliveryImageProbe.stripRows
        let blockCount = (height + stripRows - 1) / stripRows
        var histograms = [LSBHistogram](repeating: LSBHistogram(), count: blockCount)
        var errors = [Error?](repeating: nil, count: blockCount)
        let pixels = reference.pixels
        let rowBytes = width * 4

        let start = clock.now
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            let blockStart = block * stripRows
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            var buffer = [UInt8](repeating: 0, count: rowBytes * rows)
            do {
                try buffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        candidate,
                        toBitmap: raw.baseAddress!,
                        rowBytes: rowBytes,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBA8,
                        colorSpace: DeliveryImageProbe.displayP3,
                        context: context
                    )
                }
                var histogram = LSBHistogram()
                pixels.withUnsafeBufferPointer { referencePixels in
                    buffer.withUnsafeBufferPointer { candidatePixels in
                        for row in 0..<rows {
                            let referenceBase = (blockStart + row) * width * 4
                            let candidateBase = row * rowBytes
                            for x in 0..<width {
                                let referenceIndex = referenceBase + x * 4
                                let candidateIndex = candidateBase + x * 4
                                for channel in 0..<3 {
                                    let expected = Int(
                                        (Double(SDRQuantiser.encoded16(referencePixels[referenceIndex + channel])) / 257.0)
                                            .rounded()
                                    )
                                    histogram.add(abs(Int(candidatePixels[candidateIndex + channel]) - expected))
                                }
                            }
                        }
                    }
                }
                histograms[block] = histogram
            } catch {
                errors[block] = error
            }
        }
        let elapsed = seconds(clock.now - start)
        if let error = errors.compactMap({ $0 }).first { throw error }
        var merged = LSBHistogram()
        for histogram in histograms { merged.merge(histogram) }
        return (elapsed, merged.mean, merged.percentile(99), merged.count)
    }
}

// MARK: - Local accumulator (same histogram shape as `DeliveryImageProbe`)

private struct DeltaEHistogram {
    static let binWidth = 0.01
    static let binCount = 4000

    private var bins = [Int](repeating: 0, count: DeltaEHistogram.binCount)
    private(set) var count = 0
    private(set) var sum = 0.0
    private(set) var maxValue = 0.0

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        sum += value
        if value > maxValue { maxValue = value }
        let bin = min(max(Int(value / Self.binWidth), 0), Self.binCount - 1)
        bins[bin] += 1
    }

    mutating func merge(_ other: DeltaEHistogram) {
        count += other.count
        sum += other.sum
        if other.maxValue > maxValue { maxValue = other.maxValue }
        for index in 0..<Self.binCount { bins[index] += other.bins[index] }
    }

    var mean: Double { count > 0 ? sum / Double(count) : 0 }

    func percentile(_ percent: Double) -> Double {
        guard count > 0 else { return 0 }
        let rank = max(1, Int((percent / 100.0 * Double(count)).rounded(.up)))
        var cumulative = 0
        for (index, binCount) in bins.enumerated() {
            cumulative += binCount
            if cumulative >= rank { return Double(index) * Self.binWidth }
        }
        return maxValue
    }
}

// MARK: - Local LSB accumulator (same histogram shape as `DeliveryImageProbe`)

private struct LSBHistogram {
    private var counts = [Int](repeating: 0, count: 256)
    private(set) var count = 0
    private(set) var sum = 0.0
    private(set) var maxValue = 0

    mutating func add(_ difference: Int) {
        let value = min(max(difference, 0), 255)
        count += 1
        sum += Double(value)
        if value > maxValue { maxValue = value }
        counts[value] += 1
    }

    mutating func merge(_ other: LSBHistogram) {
        count += other.count
        sum += other.sum
        if other.maxValue > maxValue { maxValue = other.maxValue }
        for index in 0..<256 { counts[index] += other.counts[index] }
    }

    var mean: Double { count > 0 ? sum / Double(count) : 0 }

    func percentile(_ percent: Double) -> Int {
        guard count > 0 else { return 0 }
        let rank = max(1, Int((percent / 100.0 * Double(count)).rounded(.up)))
        var cumulative = 0
        for (value, binCount) in counts.enumerated() {
            cumulative += binCount
            if cumulative >= rank { return value }
        }
        return maxValue
    }
}

// MARK: - Fast scalar ΔE2000 prototype

/// The same CIEDE2000 formulation as `Colorimetry`, with the two costs that a debug build pays per
/// pixel removed: the `[[Double]]` matrix subscripting in `lab` and the libm `pow` calls in
/// `deltaE2000` (`pow(25, 7)` is a constant; `x^7` is a few multiplies). Values agree with
/// `Colorimetry` to ~1e-12, far below every report threshold.
private enum FastColorimetry {
    // Display P3 → XYZ, D65 (identical constants to `Colorimetry`).
    private static let m00 = 0.4865709486482162
    private static let m01 = 0.26566769316909306
    private static let m02 = 0.1982172852343625
    private static let m10 = 0.2289745640697488
    private static let m11 = 0.6917385218365064
    private static let m12 = 0.079286914093745
    private static let m20 = 0.0
    private static let m21 = 0.04511338185890264
    private static let m22 = 1.043944368900976

    private static let whiteX = m00 + m01 + m02
    private static let whiteY = m10 + m11 + m12
    private static let whiteZ = m20 + m21 + m22

    private static let pow25_7 = 6103515625.0 // 25^7

    static func lab(_ pixel: RGBA) -> LABColor {
        let r = Double(pixel.r)
        let g = Double(pixel.g)
        let b = Double(pixel.b)
        let x = m00 * r + m01 * g + m02 * b
        let y = m10 * r + m11 * g + m12 * b
        let z = m20 * r + m21 * g + m22 * b
        let fx = labF(x / whiteX)
        let fy = labF(y / whiteY)
        let fz = labF(z / whiteZ)
        return LABColor(L: 116.0 * fy - 16.0, a: 500.0 * (fx - fy), b: 200.0 * (fy - fz))
    }

    private static func labF(_ t: Double) -> Double {
        let delta = 6.0 / 29.0
        let delta3 = delta * delta * delta
        if t > delta3 { return cbrt(t) }
        return t / (3.0 * delta * delta) + 4.0 / 29.0
    }

    static func deltaE2000(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        deltaE2000(lab(lhs), lab(rhs))
    }

    static func deltaE2000(_ lhs: LABColor, _ rhs: LABColor) -> Double {
        let l1 = lhs.L, a1 = lhs.a, b1 = lhs.b
        let l2 = rhs.L, a2 = rhs.a, b2 = rhs.b

        let c1 = (a1 * a1 + b1 * b1).squareRoot()
        let c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2.0
        let cBar7 = seventh(cBar)
        let g = 0.5 * (1.0 - (cBar7 / (cBar7 + pow25_7)).squareRoot())
        let a1p = (1.0 + g) * a1
        let a2p = (1.0 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot()
        let c2p = (a2p * a2p + b2 * b2).squareRoot()
        let h1p = hueAngle(b: b1, a: a1p, chroma: c1p)
        let h2p = hueAngle(b: b2, a: a2p, chroma: c2p)

        let dLp = l2 - l1
        let dCp = c2p - c1p
        let dhp: Double
        if c1p * c2p == 0.0 {
            dhp = 0.0
        } else if h2p - h1p > 180.0 {
            dhp = h2p - h1p - 360.0
        } else if h2p - h1p < -180.0 {
            dhp = h2p - h1p + 360.0
        } else {
            dhp = h2p - h1p
        }
        let dHp = 2.0 * (c1p * c2p).squareRoot() * sin(radians(dhp) / 2.0)

        let lBarP = (l1 + l2) / 2.0
        let cBarP = (c1p + c2p) / 2.0
        let hBarP: Double
        if c1p * c2p == 0.0 {
            hBarP = h1p + h2p
        } else if abs(h1p - h2p) <= 180.0 {
            hBarP = (h1p + h2p) / 2.0
        } else if h1p + h2p < 360.0 {
            hBarP = (h1p + h2p + 360.0) / 2.0
        } else {
            hBarP = (h1p + h2p - 360.0) / 2.0
        }

        let t = 1.0
            - 0.17 * cos(radians(hBarP - 30.0))
            + 0.24 * cos(radians(2.0 * hBarP))
            + 0.32 * cos(radians(3.0 * hBarP + 6.0))
            - 0.20 * cos(radians(4.0 * hBarP - 63.0))

        let hueTerm = (hBarP - 275.0) / 25.0
        let dTheta = 30.0 * exp(-(hueTerm * hueTerm))
        let cBarP7 = seventh(cBarP)
        let rC = 2.0 * (cBarP7 / (cBarP7 + pow25_7)).squareRoot()
        let rT = -sin(radians(2.0 * dTheta)) * rC

        let dL = lBarP - 50.0
        let sL = 1.0 + (0.015 * dL * dL) / (20.0 + dL * dL).squareRoot()
        let sC = 1.0 + 0.045 * cBarP
        let sH = 1.0 + 0.015 * cBarP * t

        let termL = dLp / sL
        let termC = dCp / sC
        let termH = dHp / sH
        return (termL * termL + termC * termC + termH * termH + rT * termC * termH).squareRoot()
    }

    /// x^7 as three multiplies (x, x², x³, x⁶, x⁷) instead of a libm `pow`.
    @inline(__always)
    private static func seventh(_ x: Double) -> Double {
        let x2 = x * x
        let x3 = x2 * x
        return x3 * x3 * x
    }

    private static func hueAngle(b: Double, a: Double, chroma: Double) -> Double {
        guard chroma != 0.0 else { return 0.0 }
        var degrees = atan2(b, a) * 180.0 / Double.pi
        if degrees < 0.0 { degrees += 360.0 }
        return degrees
    }

    private static func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180.0 }
}

// MARK: - Deterministic RNG for the parity check

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
