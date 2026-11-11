import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// v2 delivery contract tests (docs/reference/deliver.md): the profile files, the report gate,
/// determinism, and the identity/recipe refusals. The encoder is the in-process Core Image writer,
/// so these tests do not need `tools/toGainMapHDR`.
final class DeliveryPipelineTests: XCTestCase {
    // MARK: - Harness

    /// A temporary source + a work folder holding the stored recipe, in the M3 client's layout.
    private struct Harness {
        let root: URL
        let sourceURL: URL
        let sourceSHA256: String
        let sourceSize: PixelSize
        let recipe: Recipe

        var workDirectory: URL { root.appendingPathComponent("work", isDirectory: true) }
        var outputDirectory: URL { root.appendingPathComponent("out", isDirectory: true) }
        var storedRecipeURL: URL {
            workDirectory.appendingPathComponent(sourceSHA256, isDirectory: true)
                .appendingPathComponent("recipe.json")
        }

        func storeRecipe(_ recipe: Recipe) throws {
            try AtomicFile.write(try recipe.canonicalJSON(), to: storedRecipeURL)
        }

        func configuration(recipePath: URL? = nil) -> DeliveryConfiguration {
            DeliveryConfiguration(
                sourcePath: sourceURL,
                recipePath: recipePath,
                workDirectory: workDirectory,
                outputDirectory: outputDirectory,
                encoderVersion: "coreimage-1"
            )
        }
    }

    private func makeHarness(
        size: PixelSize = PixelSize(width: 96, height: 64),
        hdr: Recipe.HDR = Recipe.HDR(start: 0.4, liftStops: 1.4, transition: 0.3, headroomCap: 2.5),
        storeRecipe: Bool = true
    ) throws -> Harness {
        let root = try TestFixtures.makeTemporaryDirectory()
        let sourceURL = root.appendingPathComponent("source.tif")
        try TestFixtures.writeGradientP3TIFF(size: size, to: sourceURL)
        let sha256 = try SourceDecoder.sha256(ofFileAt: sourceURL)
        let recipe = Recipe(
            source: Recipe.Source(
                path: "source.tif",
                sha256: sha256,
                width: size.width,
                height: size.height
            ),
            hdr: hdr,
            encoder: Recipe.EncoderParams(
                tool: Recipe.EncoderParams.coreImageToolName,
                quality: 0.85,
                depth: 10,
                subsample: true,
                map: Recipe.EncoderParams.isoRGBMap
            ),
            versions: Recipe.Versions(encoder: "coreimage-1"),
            created: "2026-11-03T13:00:00+08:00"
        )
        try recipe.validate()
        let harness = Harness(
            root: root,
            sourceURL: sourceURL,
            sourceSHA256: sha256,
            sourceSize: size,
            recipe: recipe
        )
        if storeRecipe {
            try harness.storeRecipe(recipe)
        }
        return harness
    }

    // MARK: - The happy path

    func testDeliverInstallsTheProfileFilesAndPassesEveryCheck() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let outcome = try DeliveryPipeline().deliver(harness.configuration())
        let profile = try XCTUnwrap(outcome.report.profiles.first)
        XCTAssertTrue(outcome.report.pass, "failures: \(outcome.report.failures)")
        XCTAssertEqual(profile.checks.map(\.name), DeliveryReport.checkOrder)
        XCTAssertEqual(profile.profile.name, "10-half-rgb", "the recipe's encoder block is the default profile")
        XCTAssertEqual(outcome.renderKey, try harness.recipe.renderKey())
        XCTAssertEqual(outcome.sourceSHA256, harness.sourceSHA256)

        // The --out folder holds the profile HDR, the shared fallback, the recipe echo and the report.
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: harness.outputDirectory.path))
        XCTAssertEqual(
            names,
            Set(["source-hdr-10-half-rgb.heic", "source-sdr.heic", "source.recipe.json", "source.report.json"])
        )

        // The report describes the files that are actually installed.
        let reportOnDisk = try JSONDecoder().decode(
            DeliveryReport.self,
            from: Data(contentsOf: harness.outputDirectory.appendingPathComponent("source.report.json"))
        )
        XCTAssertEqual(reportOnDisk, outcome.report)
        let hdrURL = try XCTUnwrap(outcome.artifacts.hdrHEICs["10-half-rgb"])
        XCTAssertEqual(
            try SourceDecoder.sha256(ofFileAt: hdrURL),
            reportOnDisk.profiles[0].artifacts.hdrHEIC.sha256,
            "the report names the delivered HEIC's sha256 so the pairing is auditable"
        )

        // The recipe echo is the exact recipe that was used (same canonical bytes, created kept).
        XCTAssertEqual(
            try Data(contentsOf: outcome.artifacts.recipeJSON),
            try harness.recipe.canonicalJSON()
        )

        // Container facts: a gain-map HEIC and a genuinely map-stripped 8-bit fallback.
        let hdrFacts = try EncodedHEICValidator.inspect(hdrURL)
        XCTAssertTrue(hdrFacts.isoGainMapPresent)
        XCTAssertFalse(hdrFacts.sdrHasAlpha)
        XCTAssertEqual(hdrFacts.width, harness.sourceSize.width)
        XCTAssertEqual(hdrFacts.height, harness.sourceSize.height)
        XCTAssertEqual(hdrFacts.gainMapWidth, harness.sourceSize.width / 2, "the recipe's profile is half-res")

        let sdrFacts = try EncodedHEICValidator.inspect(outcome.artifacts.sdrHEIC)
        XCTAssertFalse(sdrFacts.isoGainMapPresent, "the fallback must still be decodable by SDR-only viewers")
        XCTAssertFalse(sdrFacts.sdrHasAlpha)
        XCTAssertEqual(sdrFacts.sdrBitsPerComponent, 8)

        // No staging leftovers after a successful install.
        let deliveryRoot = harness.workDirectory
            .appendingPathComponent(harness.sourceSHA256, isDirectory: true)
            .appendingPathComponent("delivery", isDirectory: true)
        if FileManager.default.fileExists(atPath: deliveryRoot.path) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: deliveryRoot.path), [])
        }

        // The authored rendition reached the recipe cap and the report records it.
        XCTAssertEqual(profile.render.authoredPeak, 2.5, accuracy: 1e-5)
        XCTAssertTrue(profile.render.capEngaged)
        XCTAssertGreaterThan(profile.render.fractionAboveOne, 0)
        XCTAssertGreaterThan(profile.timings.totalSeconds, 0)
    }

    func testTwoDeliveriesOfTheSameRecipeAreByteIdentical() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let pipeline = DeliveryPipeline()
        let first = try pipeline.deliver(harness.configuration())
        let firstHDR = try Data(contentsOf: try XCTUnwrap(first.artifacts.hdrHEICs["10-half-rgb"]))
        let firstFallback = try Data(contentsOf: first.artifacts.sdrHEIC)
        let firstRecipe = try Data(contentsOf: first.artifacts.recipeJSON)

        let second = try pipeline.deliver(harness.configuration())
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(second.artifacts.hdrHEICs["10-half-rgb"])),
            firstHDR,
            "same recipe ⇒ byte-identical profile HEIC"
        )
        XCTAssertEqual(try Data(contentsOf: second.artifacts.sdrHEIC), firstFallback, "the fallback is deterministic too")
        XCTAssertEqual(try Data(contentsOf: second.artifacts.recipeJSON), firstRecipe)
        XCTAssertEqual(second.report.profiles[0].artifacts, first.report.profiles[0].artifacts)
        XCTAssertGreaterThan(
            second.report.profiles[0].timings.totalSeconds, 0,
            "timings are recorded; the report is not byte-identity material"
        )
    }

    // MARK: - Fail-closed install rule

    func testAFailingCheckInstallsNothingAndKeepsTheReportAsEvidence() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        var verifierCalls = 0
        let pipeline = DeliveryPipeline { input in
            verifierCalls += 1
            // The pipeline hashes the shared fallback before the pass/fail gate, so a verifier must
            // still have produced the copy. Mark one documented check as failed.
            try Data("not-a-real-fallback".utf8).write(to: input.fallbackHEIC)
            return DeliveryReport.checkOrder.map { name in
                DeliveryReport.Check(
                    name: name,
                    pass: name != "baseDeltaE",
                    detail: name == "baseDeltaE" ? "measured drift above the documented threshold" : "injected PASS",
                    measured: ["injected": .boolean(true)]
                )
            }
        }

        XCTAssertThrowsError(try pipeline.deliver(harness.configuration())) { error in
            guard case let PhotonError.deliveryVerificationFailed(reportPath, failures)? = error as? PhotonError else {
                return XCTFail("expected deliveryVerificationFailed, got \(error)")
            }
            XCTAssertEqual(failures, ["10-half-rgb: baseDeltaE"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: reportPath), "the report must be kept as evidence")
            let evidenceReport = try? DeliveryReport(contentsOf: URL(fileURLWithPath: reportPath))
            XCTAssertEqual(evidenceReport?.pass, false)
        }
        XCTAssertEqual(verifierCalls, 1)

        // Fail closed: nothing in `--out` at all.
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.outputDirectory.path))

        // The evidence folder is `work/<sha>/rejected/<renderKey12>/`.
        let renderKey = try harness.recipe.renderKey()
        let rejected = harness.workDirectory
            .appendingPathComponent(harness.sourceSHA256, isDirectory: true)
            .appendingPathComponent("rejected", isDirectory: true)
            .appendingPathComponent(String(renderKey.prefix(12)), isDirectory: true)
        let evidenceNames = try Set(FileManager.default.contentsOfDirectory(atPath: rejected.path))
        XCTAssertTrue(evidenceNames.contains("source.report.json"))
        XCTAssertTrue(evidenceNames.contains("source-hdr-10-half-rgb.heic"))
        XCTAssertTrue(evidenceNames.contains("source-sdr.heic"))
    }

    // MARK: - Refusals

    func testMissingStoredRecipeIsRefused() throws {
        let harness = try makeHarness(storeRecipe: false)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        XCTAssertThrowsError(try DeliveryPipeline().deliver(harness.configuration())) { error in
            guard case let PhotonError.invalidRecipe(field, reason)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)")
            }
            XCTAssertEqual(field, "recipe")
            XCTAssertTrue(reason.contains("no stored recipe"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.outputDirectory.path))
    }

    func testRecipeForDifferentBytesIsRefused() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let stale = Recipe(
            source: Recipe.Source(
                path: "source.tif",
                sha256: String(repeating: "f", count: 64),
                width: harness.sourceSize.width,
                height: harness.sourceSize.height
            ),
            versions: Recipe.Versions(encoder: "coreimage-1"),
            created: "2026-11-03T13:00:00+08:00"
        )
        try harness.storeRecipe(stale)

        XCTAssertThrowsError(try DeliveryPipeline().deliver(harness.configuration())) { error in
            guard case PhotonError.sourceHashMismatch? = error as? PhotonError else {
                return XCTFail("expected sourceHashMismatch, got \(error)")
            }
        }
    }

    func testRecipeWithWrongDimensionsIsRefused() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let wrongSize = Recipe(
            source: Recipe.Source(
                path: "source.tif",
                sha256: harness.sourceSHA256,
                width: harness.sourceSize.width + 1,
                height: harness.sourceSize.height
            ),
            versions: Recipe.Versions(encoder: "coreimage-1"),
            created: "2026-11-03T13:00:00+08:00"
        )
        try harness.storeRecipe(wrongSize)

        XCTAssertThrowsError(try DeliveryPipeline().deliver(harness.configuration())) { error in
            guard case PhotonError.dimensionMismatch? = error as? PhotonError else {
                return XCTFail("expected dimensionMismatch, got \(error)")
            }
        }
    }

    func testARenditionBelowTheEncoderFloorIsRefusedBeforeEncoding() throws {
        // lift 0 ⇒ the gradient's own 0.98 peak never reaches the 1.05 floor.
        let harness = try makeHarness(
            hdr: Recipe.HDR(start: 0.4, liftStops: 0, transition: 0.3, headroomCap: 2.5)
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }

        XCTAssertThrowsError(try DeliveryPipeline().deliver(harness.configuration())) { error in
            guard case let PhotonError.hdrTooDim(peak, minimum)? = error as? PhotonError else {
                return XCTFail("expected hdrTooDim, got \(error)")
            }
            XCTAssertLessThan(peak, minimum)
            XCTAssertEqual(minimum, EncodedHEICValidator.minimumAuthoredPeak)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.outputDirectory.path))
    }

    func testExplicitRecipeOverridesTheStoredOne() throws {
        let harness = try makeHarness(storeRecipe: false)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let explicit = harness.root.appendingPathComponent("explicit-recipe.json")
        try Data(try harness.recipe.canonicalJSON()).write(to: explicit)

        let outcome = try DeliveryPipeline().deliver(harness.configuration(recipePath: explicit))
        XCTAssertEqual(outcome.renderKey, try harness.recipe.renderKey())
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.outputDirectory.appendingPathComponent("source.report.json").path))
    }
}

// MARK: - Test helpers

private extension DeliveryReport {
    /// Convenience for asserting on the report kept in the rejected evidence folder.
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(DeliveryReport.self, from: Data(contentsOf: url))
    }
}
