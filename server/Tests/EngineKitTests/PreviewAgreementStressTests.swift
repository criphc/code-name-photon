import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import EngineKit

/// Stress test for the `previewAgreement` comparison (docs/reference/deliver.md, delivery
/// contract): the 2026-11-05 failure measured ΔE2000 mean 40.1085 on a delivery whose HEIC is
/// byte-identical to a passing `main` run, so the suspect is the preview path, not the encoder.
///
/// This reproduces `DeliveryVerifier.previewAgreementCheck` without the other seven checks (the
/// full verifier takes ~86 s): decode the source, render `ToneMapper.sdrBase` +
/// `HDRRendition.render`, downscale the pair with `PreviewRenderer.downscale` at 2560 (exactly like
/// `DeliveryPipeline`), decode the existing rejected HEIC with `DeliveryImageProbe.decode`,
/// downscale that HDR decode with `PreviewRenderer.lanczos` + `PreviewRenderer.render`, and compare
/// with `DeliveryImageProbe.deltaEStats`.
///
/// The source decode and the HDR rendition are deterministic CPU work and are done once; the loop
/// repeats the part that touches Core Image and ImageIO. On 2026-11-09 this test reproduced the
/// failure on `main`: the preview pair and the HDR decode were correct every time, but
/// `PreviewRenderer.render` on a freshly created GPU `CIContext` intermittently left the
/// destination buffer at its zero initialization (ΔE mean 7.75–51.1 instead of 1.1689). The
/// `CIRender` fix (shared `CIContext` + `CIRenderDestination` + `waitUntilCompleted`) makes it
/// pass 20/20; this test is the regression that keeps the fix honest. It runs 5 iterations by
/// default and the full 20 with `PHOTON_PREVIEW_STRESS=1`.
final class PreviewAgreementStressTests: XCTestCase {
    // MARK: - Locating the evidence

    /// `server/Tests/EngineKitTests/PreviewAgreementStressTests.swift` → the repository root.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EngineKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // server
            .deletingLastPathComponent() // repo root
    }

    private static var sourceURL: URL {
        repositoryRoot.appendingPathComponent("fixtures/media/sources/R0003777-P3.tif")
    }

    /// The rejected 2026-11-05 delivery (`migration/p3`, previewAgreement FAIL).
    private static var rejectedDirectory: URL {
        repositoryRoot.appendingPathComponent(
            "work/p3-accept/bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116/rejected/5314fd618b56",
            isDirectory: true
        )
    }

    private static var recipeURL: URL {
        rejectedDirectory.appendingPathComponent("R0003777-P3.recipe.json")
    }

    private static var heicURL: URL {
        rejectedDirectory.appendingPathComponent("R0003777-P3-hdr.heic")
    }

    private static var scratchDirectory: URL {
        repositoryRoot.appendingPathComponent(".scratch/preview-agreement", isDirectory: true)
    }

    /// The documented `previewAgreement` gate and the preview long edge `DeliveryPipeline` uses.
    private static let meanLimit = 2.5
    private static let previewLongEdge = 2560
    /// 5 by default (a merge-gate smoke check, ~30 s); `PHOTON_PREVIEW_STRESS=1` runs the full
    /// 20-iteration stress that reproduced the 2026-11-05 failure (~125 s).
    private static var iterations: Int {
        ProcessInfo.processInfo.environment["PHOTON_PREVIEW_STRESS"] == "1" ? 20 : 5
    }
    /// A mean that moves by more than this between iterations is nondeterminism, not codec noise.
    private static let stabilityLimit = 1e-3

    // MARK: - The stress test

    func testPreviewAgreementIsStableAcrossTwentyRuns() throws {
        try Self.requireFile(Self.sourceURL, description: "the P3 source fixture")
        try Self.requireFile(Self.recipeURL, description: "the rejected recipe")
        try Self.requireFile(Self.heicURL, description: "the rejected HDR HEIC")

        let source = try SourceDecoder.decode(url: Self.sourceURL)
        let recipe = try JSONDecoder().decode(Recipe.self, from: try Data(contentsOf: Self.recipeURL))
        try recipe.validate()
        XCTAssertEqual(
            recipe.source.sha256.lowercased(),
            source.sha256,
            "the rejected recipe must belong to the fixture source"
        )

        let toneMap = try ToneMapKind.named(recipe.base.toneMap)
        let shape = try HighlightShape(recipe: recipe.hdr)
        let sdrBase = try ToneMapper.sdrBase(from: source.linear, toneMap: toneMap)
        let hdrRendition = try HDRRendition.render(base: sdrBase, shape: shape)
        let longEdge = PreviewRenderer.previewLongEdge(for: source.size, limit: Self.previewLongEdge)
        XCTAssertEqual(longEdge, Self.previewLongEdge, "the 6000 px source must be downscaled to 2560")

        var rows: [Row] = []
        var worst: (mean: Double, pair: PreviewRenderer.Pair, delivered: LinearImage)?

        for iteration in 1...Self.iterations {
            // Exactly the production preview pair: same maths, same cap, same long edge.
            let pair = try PreviewRenderer.downscale(
                base: sdrBase,
                hdr: hdrRendition.image,
                longEdge: longEdge,
                headroomCap: shape.headroomCap
            )
            let decoded = try DeliveryImageProbe.decode(Self.heicURL)
            guard let hdr = decoded.hdr else {
                XCTFail("the rejected HEIC has no HDR decode (no gain map); cannot compare")
                return
            }

            // Exactly `previewAgreementCheck`: Lanczos the delivered HDR decode to the preview grid,
            // render it to linear P3, compare with the lossless preview HDR buffer.
            let target = pair.size
            let hdrSize = PixelSize(width: hdr.width, height: hdr.height)
            let hdrCI = CIImage(cgImage: hdr)
            let scaled = hdrSize == target ? hdrCI : PreviewRenderer.lanczos(hdrCI, to: target)
            let context = DeliveryImageProbe.makeContext()
            let deliveredPreview = try PreviewRenderer.render(scaled, size: target, context: context)
            let deltaE = DeliveryImageProbe.deltaEStats(deliveredPreview, pair.hdr)
            let heicSHA = try DeliveryImageProbe.sha256(ofFileAt: Self.heicURL)

            rows.append(
                Row(
                    iteration: iteration,
                    mean: deltaE.mean,
                    p50: deltaE.p50,
                    p95: deltaE.p95,
                    p99: deltaE.p99,
                    fractionAbove5: deltaE.fractionAbove5,
                    heicSHA: heicSHA
                )
            )
            if worst.map({ deltaE.mean > $0.mean }) ?? true {
                worst = (deltaE.mean, pair, deliveredPreview)
            }
        }

        Self.printTable(rows)

        let means = rows.map(\.mean)
        let p95s = rows.map(\.p95)
        guard let minMean = means.min(), let maxMean = means.max(),
              let minP95 = p95s.min(), let maxP95 = p95s.max()
        else {
            return XCTFail("the stress loop produced no rows")
        }
        let shaSet = Set(rows.map(\.heicSHA))

        let meanRange = maxMean - minMean
        let p95Range = maxP95 - minP95
        let unstable = meanRange > Self.stabilityLimit
        let overLimit = maxMean > Self.meanLimit

        print(
            String(
                format: "summary: mean %.6f…%.6f (range %.6f), p95 %.4f…%.4f (range %.6f), %d distinct HEIC sha",
                minMean, maxMean, meanRange, minP95, maxP95, p95Range, shaSet.count
            )
        )

        if unstable || overLimit {
            if let worst {
                try Self.saveEvidence(pair: worst.pair, deliveredPreview: worst.delivered)
            }
            XCTFail(
                String(
                    format: "previewAgreement is not stable: mean %.6f…%.6f (range %.6f > %.0e) or max mean %.6f > %.1f; "
                        + "the worst preview pair was saved under %@",
                    minMean, maxMean, meanRange, Self.stabilityLimit, maxMean, Self.meanLimit,
                    Self.scratchDirectory.path
                )
            )
        }

        XCTAssertEqual(
            shaSet.count,
            1,
            "the rejected HEIC changed on disk during the run: \(shaSet.sorted())"
        )
        XCTAssertLessThanOrEqual(
            maxMean,
            Self.meanLimit,
            "the preview and the delivered HDR decode disagree beyond the documented gate"
        )
    }

    // MARK: - Evidence

    private struct Row {
        let iteration: Int
        let mean: Double
        let p50: Double
        let p95: Double
        let p99: Double
        let fractionAbove5: Double
        let heicSHA: String
    }

    private static func printTable(_ rows: [Row]) {
        print("iteration |     mean |      p50 |      p95 |      p99 |  >5 %  | HEIC sha256")
        print("----------+----------+----------+----------+----------+--------+------------")
        for row in rows {
            print(
                String(
                    format: "%9d | %8.4f | %8.3f | %8.3f | %8.3f | %6.2f | %@",
                    row.iteration, row.mean, row.p50, row.p95, row.p99,
                    row.fractionAbove5 * 100, String(row.heicSHA.prefix(16))
                )
            )
        }
    }

    /// Saves the preview pair (and the delivered decode downscaled the same way) as float TIFFs so
    /// the failing stage can be inspected outside the test (`.scratch/preview-agreement/`).
    private static func saveEvidence(pair: PreviewRenderer.Pair, deliveredPreview: LinearImage) throws {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        try TIFFWriter.writeHDR(pair.base, to: scratchDirectory.appendingPathComponent("preview-base.tif"))
        try TIFFWriter.writeHDR(pair.hdr, to: scratchDirectory.appendingPathComponent("preview-hdr.tif"))
        try TIFFWriter.writeHDR(
            deliveredPreview,
            to: scratchDirectory.appendingPathComponent("delivered-hdr-preview.tif")
        )
    }

    private static func requireFile(_ url: URL, description: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail(
                "missing \(description) at \(url.path); this test needs the 2026-11-05 rejected delivery "
                    + "under work/p3-accept/ and the gitignored fixtures/media/ source (server/AGENTS.md)"
            )
            throw PhotonError.sourceUnreadable(path: url.path, reason: "missing \(description)")
        }
    }
}
