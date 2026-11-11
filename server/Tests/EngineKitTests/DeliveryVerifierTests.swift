import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// v2 delivery verifier tests (docs/reference/deliver.md, report schema 1).
///
/// The verifier is the delivery gate: it must return the eight named checks in the canonical order,
/// PASS on a valid tiny delivery set, and FAIL a defective one **by name** without throwing. The
/// fixture is encoded by the in-process `CoreImageHEICEncoder`; no external tool is needed.
final class DeliveryVerifierTests: XCTestCase {
    // MARK: - A valid tiny delivery set

    /// The generated pieces of one delivery, shared by the valid/defect/wrong-base tests.
    private struct Fixture {
        let directory: URL
        let size: PixelSize
        let sdrBase: LinearImage
        let hdrImage: LinearImage
        let authoredPeak: Float
        let fractionAboveOne: Double
        let fractionAtCap: Double
        let baseURL: URL
        let hdrURL: URL
        let encodedHEIC: URL
        let sourceSHA256: String
        let recipe: Recipe
        let preview: PreviewRenderer.Pair
        let fallbackHEIC: URL
        let profile: HEICEncodeOptions

        func input(
            encodedHEIC override: URL? = nil,
            sdrBase overrideBase: LinearImage? = nil,
            authoredPeak overridePeak: Float? = nil,
            recipe overrideRecipe: Recipe? = nil
        ) -> DeliveryVerificationInput {
            DeliveryVerificationInput(
                encodedHEIC: override ?? encodedHEIC,
                fallbackHEIC: fallbackHEIC,
                sdrBase: overrideBase ?? sdrBase,
                authoredPeak: overridePeak ?? authoredPeak,
                fractionAboveOne: fractionAboveOne,
                fractionAtCap: fractionAtCap,
                preview: preview,
                previewLongEdge: PreviewRenderer.previewLongEdge(for: size, limit: 2560),
                recipe: overrideRecipe ?? recipe,
                source: DeliverySourceFacts(
                    path: baseURL.path,
                    sha256: sourceSHA256,
                    size: size,
                    profileName: "Display P3",
                    bitsPerComponent: 16
                ),
                profile: profile
            )
        }
    }

    /// 0.40 → 0.95 linear ramp: the recipe mask (start 0.55, transition 0.3) raises the right side
    /// above SDR white and reaches the 2.5 cap on the last column, with no hard edge anywhere.
    private func makeBaseImage(_ size: PixelSize) -> LinearImage {
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = Float(x) / Float(max(size.width - 1, 1))
                let value = 0.40 + 0.55 * t
                let index = (y * size.width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        return try! LinearImage(size: size, pixels: pixels)
    }

    private func makeFixture(
        size: PixelSize = PixelSize(width: 96, height: 64),
        bitDepth: HEICEncodeOptions.BitDepth = .ten
    ) throws -> Fixture {
        let directory = try TestFixtures.makeTemporaryDirectory(function: #function)

        let base = makeBaseImage(size)
        let shape = try HighlightShape(start: 0.55, liftStops: 1.4, transition: 0.3, headroomCap: 2.5)
        let hdr = try HDRRendition.render(base: base, shape: shape)
        XCTAssertGreaterThan(hdr.authoredPeak, 2.4, "the fixture must author real HDR at the cap")
        XCTAssertGreaterThan(hdr.fractionAboveOne, 0, "the fixture must author pixels above SDR white")

        let baseURL = directory.appendingPathComponent("base.tif")
        let hdrURL = directory.appendingPathComponent("hdr.tif")
        try TIFFWriter.writeSDRBase(base, to: baseURL)
        try TIFFWriter.writeHDR(hdr.image, to: hdrURL)

        let sourceSHA256 = try TestFixtures.sha256(ofFileAt: baseURL)
        let recipe = Recipe(
            source: Recipe.Source(
                path: "fixture/base.tif",
                sha256: sourceSHA256,
                width: size.width,
                height: size.height
            ),
            hdr: Recipe.HDR(start: 0.55, liftStops: 1.4, transition: 0.3, headroomCap: 2.5),
            versions: Recipe.Versions(encoder: "test-encoder"),
            created: "2026-11-03T00:00:00+08:00"
        )
        try recipe.validate()

        let profile = try HEICEncodeOptions(
            bitDepth: bitDepth, quality: 0.85, mapResolution: .half, mapKind: .isoRGB
        )
        let encodedHEIC = directory.appendingPathComponent("hdr.heic")
        let fallbackHEIC = directory.appendingPathComponent("fallback-sdr.heic")
        _ = try CoreImageHEICEncoder().encode(
            HEICEncodeRequest(
                sdrBase: base,
                hdrRendition: hdr.image,
                authoredPeak: hdr.authoredPeak,
                options: profile,
                sourceURL: baseURL,
                hdrOutputURL: encodedHEIC,
                sdrOutputURL: fallbackHEIC
            )
        )
        // The read-back gate the pipeline runs before the verifier.
        _ = try EncodedHEICValidator.validate(encodedHEIC, expectedSize: size)

        let previewLongEdge = PreviewRenderer.previewLongEdge(for: size, limit: 2560)
        let preview = try PreviewRenderer.downscale(
            base: base,
            hdr: hdr.image,
            longEdge: previewLongEdge,
            headroomCap: Float(recipe.hdr.headroomCap)
        )
        return Fixture(
            directory: directory,
            size: size,
            sdrBase: base,
            hdrImage: hdr.image,
            authoredPeak: hdr.authoredPeak,
            fractionAboveOne: hdr.fractionAboveOne,
            fractionAtCap: hdr.fractionAtCap,
            baseURL: baseURL,
            hdrURL: hdrURL,
            encodedHEIC: encodedHEIC,
            sourceSHA256: sourceSHA256,
            recipe: recipe,
            preview: preview,
            fallbackHEIC: fallbackHEIC,
            profile: profile
        )
    }

    // MARK: - Valid delivery set

    func testValidDeliveryPassesEveryCheckInCanonicalOrder() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let checks = try DeliveryVerifier.verify(fixture.input())

        XCTAssertEqual(checks.count, 8)
        XCTAssertEqual(checks.map(\.name), DeliveryReport.checkOrder, "checks must be in the documented order")
        for check in checks {
            XCTAssertTrue(check.passed, "\(check.name) failed: \(check.detail)")
            XCTAssertFalse(check.detail.isEmpty, "\(check.name) must carry a one-sentence detail")
        }
        // Measured values the CLI prints must be present on the passing checks.
        XCTAssertNotNil(checks.first { $0.name == "headroom" }?.measured["contentHeadroom"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "headroom" }?.measured["expectedHeadroom"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "headroom" }?.measured["capEngaged"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "baseDeltaE" }?.measured["mean"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "baseDeltaE" }?.measured["p95"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "fallback" }?.measured["copySha256"]?.textValue)
        XCTAssertNotNil(checks.first { $0.name == "fallback" }?.measured["copyBytes"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "previewAgreement" }?.measured["fractionAbove3"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "clipping" }?.measured["decodedPeak"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "container" }?.measured["compatibleBrands"]?.textValue)
        XCTAssertNotNil(checks.first { $0.name == "identity" }?.measured["decodedWidth"]?.numberValue)
        XCTAssertNotNil(checks.first { $0.name == "alpha" }?.measured["sdrAlphaInfo"]?.textValue)

        // The report assembly still derives PASS/failures and the canonical order from the checks.
        let report = try makeReport(fixture: fixture, checks: checks)
        XCTAssertTrue(report.pass)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.profiles[0].checks.map(\.name), DeliveryReport.checkOrder)
        XCTAssertEqual(report.schema, DeliveryReport.currentSchema)
    }

    // MARK: - Headroom mismatch is a gate (ADR-0011 recovered)

    /// v2's writer advertises the authored peak exactly, so the 5 % match is a hard gate again. The
    /// same encoded file with an authored peak it does not advertise must fail, not warn.
    func testAdvertisedHeadroomMismatchFailsTheGate() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Claim a 3.0 cap/peak: the encoded file advertises ~2.46, far outside the 5 % match.
        let higherCap = Recipe(
            source: fixture.recipe.source,
            base: fixture.recipe.base,
            hdr: Recipe.HDR(
                start: fixture.recipe.hdr.start,
                liftStops: fixture.recipe.hdr.liftStops,
                transition: fixture.recipe.hdr.transition,
                headroomCap: 3.0
            ),
            encoder: fixture.recipe.encoder,
            versions: fixture.recipe.versions,
            created: fixture.recipe.created
        )
        let checks = try DeliveryVerifier.verify(
            fixture.input(authoredPeak: 3.0, recipe: higherCap)
        )
        let headroom = try XCTUnwrap(checks.first { $0.name == "headroom" })
        XCTAssertEqual(headroom.status, .fail, "the 5% match is a gate in v2: \(headroom.detail)")
        XCTAssertEqual(headroom.measured["withinTolerance"]?.numberValue, 0)
        XCTAssertTrue(headroom.detail.contains("failed"), headroom.detail)

        let report = try makeReport(fixture: fixture, checks: checks)
        XCTAssertFalse(report.pass, "a headroom mismatch must reject the delivery")
        XCTAssertTrue(report.failures.contains("10-half-rgb: headroom"), "\(report.failures)")
    }

    // MARK: - Defective files fail by name, never throw

    /// A plain SDR HEIC (no ISO gain map) — exactly what the encoder degrades to for a too-dim
    /// pair — must fail `container` and `headroom` by name, and `verify` must return a report, not
    /// throw.
    func testPlainSDRHEICFailsContainerAndHeadroomByNamename() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let plainHEIC = fixture.directory.appendingPathComponent("plain-sdr.heic")
        try writePlainSDRHEIC(size: fixture.size, to: plainHEIC)

        let checks = try DeliveryVerifier.verify(fixture.input(encodedHEIC: plainHEIC))
        XCTAssertEqual(checks.map(\.name), DeliveryReport.checkOrder)

        let container = try XCTUnwrap(checks.first { $0.name == "container" })
        XCTAssertEqual(container.status, .fail)
        XCTAssertTrue(
            container.detail.contains("tmap") || container.detail.contains("ISO"),
            "the container failure must name the missing sub-assertion: \(container.detail)"
        )
        XCTAssertEqual(container.measured["tmapBrand"]?.numberValue, 0, "a plain SDR HEIC has no tmap brand")
        XCTAssertEqual(container.measured["isoGainMapPresent"]?.numberValue, 0)

        let headroom = try XCTUnwrap(checks.first { $0.name == "headroom" })
        XCTAssertEqual(headroom.status, .fail, "no gain map must fail the headroom check: \(headroom.detail)")
        XCTAssertEqual(headroom.measured["capEngaged"]?.numberValue, 1, "the authored cap was still engaged")
        XCTAssertNil(headroom.measured["relativeError"], "there is no advertised headroom to compare")

        let report = try makeReport(fixture: fixture, checks: checks)
        XCTAssertFalse(report.pass)
        XCTAssertTrue(report.failures.contains("10-half-rgb: container"))
        XCTAssertTrue(report.failures.contains("10-half-rgb: headroom"))
    }

    /// A delivered base that no longer matches the Capture One base must fail `baseDeltaE` only
    /// (the file itself is still a valid gain-map HEIC); this is the "SDR base drifted" failure
    /// docs/archive/stage-1/07-m4-m5-output-and-acceptance.md §9 warns about.
    func testWrongSDRBaseFailsBaseDeltaE() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // 30 % brighter base: a plausible re-grade, far outside the ΔE2000 mean < 1 gate.
        let wrongBase = fixture.sdrBase.map {
            RGBA(r: min($0.r * 1.3, 1), g: min($0.g * 1.3, 1), b: min($0.b * 1.3, 1))
        }
        let checks = try DeliveryVerifier.verify(fixture.input(sdrBase: wrongBase))
        XCTAssertEqual(checks.map(\.name), DeliveryReport.checkOrder)

        let baseDeltaE = try XCTUnwrap(checks.first { $0.name == "baseDeltaE" })
        XCTAssertEqual(baseDeltaE.status, .fail, "a re-graded base must fail baseDeltaE: \(baseDeltaE.detail)")
        let mean = try XCTUnwrap(baseDeltaE.measured["mean"]?.numberValue)
        XCTAssertGreaterThanOrEqual(mean, 1.0, "the measured mean ΔE2000 must show the drift")
        // The check must not accuse the unrelated checks of being the failure it is.
        XCTAssertEqual(checks.first { $0.name == "headroom" }?.status, .pass)
        XCTAssertEqual(checks.first { $0.name == "clipping" }?.status, .pass)
    }

    // MARK: - baseDeltaE limits are per profile bit depth

    /// 8-bit keeps the M0 calibration; 10-bit has its own (2026-11-09, three real P3 exports).
    func testBaseDeltaELimitsFollowTheProfileBitDepth() {
        let eight = DeliveryVerifier.baseDeltaELimits(forBitDepth: 8)
        XCTAssertEqual(eight.mean, 2.5)
        XCTAssertEqual(eight.p95, 6.0)

        let ten = DeliveryVerifier.baseDeltaELimits(forBitDepth: 10)
        XCTAssertEqual(ten.mean, 2.0)
        XCTAssertEqual(ten.p95, 5.0)
    }

    /// The same measured stats must pass an 8-bit profile and fail a 10-bit one: the gate keys on
    /// the profile, it is not the 8-bit limit applied everywhere.
    func testSameStatsPassAtEightBitAndFailAtTenBit() {
        let mean = 2.2
        let p95 = 5.5
        XCTAssertTrue(
            DeliveryVerifier.baseDeltaEPasses(mean: mean, p95: p95, bitDepth: 8),
            "mean 2.2 / p95 5.5 is inside the 8-bit limits (2.5 / 6.0)"
        )
        XCTAssertFalse(
            DeliveryVerifier.baseDeltaEPasses(mean: mean, p95: p95, bitDepth: 10),
            "mean 2.2 / p95 5.5 is outside the 10-bit limits (2.0 / 5.0)"
        )
    }

    /// The report must echo the limit that was actually applied, and the detail must name the
    /// profile's bit depth — not a hard-coded 8-bit container.
    func testMeasuredLimitsAndDetailFollowTheProfile() throws {
        for bitDepth in HEICEncodeOptions.BitDepth.allCases {
            let fixture = try makeFixture(bitDepth: bitDepth)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let checks = try DeliveryVerifier.verify(fixture.input())
            let baseDeltaE = try XCTUnwrap(checks.first { $0.name == "baseDeltaE" })
            let limits = DeliveryVerifier.baseDeltaELimits(forBitDepth: bitDepth.rawValue)

            XCTAssertEqual(baseDeltaE.status, .pass, "\(bitDepth.rawValue)-bit fixture failed: \(baseDeltaE.detail)")
            XCTAssertEqual(baseDeltaE.measured["meanLimit"]?.numberValue, limits.mean)
            XCTAssertEqual(baseDeltaE.measured["p95Limit"]?.numberValue, limits.p95)
            XCTAssertEqual(baseDeltaE.measured["profileBitDepth"]?.numberValue, Double(bitDepth.rawValue))
            XCTAssertTrue(
                baseDeltaE.detail.contains("decoded \(bitDepth.rawValue)-bit 4:2:0 HEVC container"),
                "the detail must name the profile's bit depth: \(baseDeltaE.detail)"
            )
        }
    }

    // MARK: - Fallback copy (determinism + container)

    func testMapStrippedCopyIsDeterministicAndCarriesNoISOAux() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let copyA = fixture.directory.appendingPathComponent("copy-a.heic")
        let copyB = fixture.directory.appendingPathComponent("copy-b.heic")
        try DeliveryImageProbe.makeMapStrippedCopy(of: fixture.encodedHEIC, to: copyA)
        try DeliveryImageProbe.makeMapStrippedCopy(of: fixture.encodedHEIC, to: copyB)

        let dataA = try Data(contentsOf: copyA)
        let dataB = try Data(contentsOf: copyB)
        XCTAssertEqual(dataA, dataB, "the ImageIO fallback copy must be byte-identical across two writes (docs/reference/deliver.md, delivery contract)")

        let facts = try EncodedHEICValidator.inspect(copyA)
        XCTAssertFalse(facts.isoGainMapPresent, "the map-stripped copy must not carry an ISO gain map")
        XCTAssertEqual(facts.width, fixture.size.width)
        XCTAssertEqual(facts.height, fixture.size.height)
        XCTAssertFalse(facts.sdrHasAlpha, "the fallback copy must stay alpha-free")

        let ftyp = try DeliveryImageProbe.readFTYP(copyA)
        XCTAssertTrue(ftyp.isHEIF, "the fallback copy must be a HEIF file")
        XCTAssertFalse(ftyp.hasTMap, "the fallback copy must not declare the tmap brand")
        XCTAssertFalse(ftyp.compatibleBrands.contains("tmap"))
    }

    // MARK: - ftyp reader

    func testFTYPReaderReadsEncoderOutput() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let ftyp = try DeliveryImageProbe.readFTYP(fixture.encodedHEIC)
        XCTAssertTrue(
            DeliveryImageProbe.heifBrands.contains(ftyp.majorBrand),
            "the encoder output declares a HEIF major brand, got '\(ftyp.majorBrand)'"
        )
        XCTAssertTrue(ftyp.isHEIF)
        XCTAssertTrue(ftyp.hasTMap, "the writer emits the ISO 21496-1 dialect: tmap in the compatible brands")
        XCTAssertTrue(ftyp.compatibleBrands.contains("tmap"))
    }

    func testFTYPReaderRejectsTruncatedAndNonBMFFBlobs() {
        // A handcrafted, valid 64-byte ftyp box: size 64, type "ftyp", major brand "heic",
        // minor version 0, and twelve compatible brands. No encoder needed for the failure cases.
        func validHeader() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 64)
            bytes.replaceSubrange(0...3, with: [0, 0, 0, 64])
            bytes.replaceSubrange(4...7, with: "ftyp".utf8)
            bytes.replaceSubrange(8...11, with: "heic".utf8)
            for index in 0..<12 {
                let offset = 16 + index * 4
                bytes.replaceSubrange(offset..<(offset + 4), with: "mif1".utf8)
            }
            return bytes
        }
        XCTAssertNoThrow(try DeliveryImageProbe.readFTYP(Data(validHeader())))

        // Too short for a header.
        XCTAssertThrowsError(try DeliveryImageProbe.readFTYP(Data()))
        XCTAssertThrowsError(try DeliveryImageProbe.readFTYP(Data(validHeader().prefix(8))))

        // Not ISO-BMFF at all.
        XCTAssertThrowsError(try DeliveryImageProbe.readFTYP(Data("this is not a heic file".utf8)))

        // A header whose declared box size runs past the data: truncated, must throw (no crash).
        // 4096-byte ftyp box, only 64 bytes present.
        var truncated = validHeader()
        truncated.replaceSubrange(0...3, with: [0x00, 0x00, 0x10, 0x00])
        XCTAssertThrowsError(try DeliveryImageProbe.readFTYP(Data(truncated)))

        // A box that is present but not ftyp.
        var wrongBox = validHeader()
        wrongBox.replaceSubrange(4...7, with: "mdat".utf8)
        XCTAssertThrowsError(try DeliveryImageProbe.readFTYP(Data(wrongBox)))
    }

    // MARK: - Strip-render row mapping (the base comparison depends on it)

    /// `CIContext.render(…, bounds:)` puts the first destination row at the TOP of the requested
    /// Core Image bounds; the probe helper translates that to top-down `LinearImage` rows. If the
    /// mapping flips, this test's 4-row ramp compares 0.1 against 0.7 (ΔE ≈ 25) instead of itself.
    func testStripRenderRowMappingIsTopDown() throws {
        let size = PixelSize(width: 8, height: 4)
        let rowValues: [Float] = [0.1, 0.3, 0.5, 0.7]
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let index = (y * size.width + x) * 4
                pixels[index] = rowValues[y]
                pixels[index + 1] = rowValues[y]
                pixels[index + 2] = rowValues[y]
            }
        }
        let reference = try LinearImage(size: size, pixels: pixels)
        let cgImage = try ImageBuffers.floatRGBA(reference)
        let candidate = CIImage(cgImage: cgImage)
        let context = DeliveryImageProbe.makeContext()

        let deltaE = try DeliveryImageProbe.deltaEStats(reference: reference, candidate: candidate, context: context)
        XCTAssertEqual(deltaE.pixelCount, size.pixelCount)
        XCTAssertLessThan(deltaE.mean, 0.05, "the same pixels must compare as identical (row order flipped?)")
        XCTAssertLessThan(deltaE.max, 0.2)

        let lsb = try DeliveryImageProbe.lsbStats(reference: reference, candidate: candidate, context: context)
        XCTAssertEqual(lsb.meanAbsDiff, 0.0, accuracy: 0.01)
        XCTAssertEqual(lsb.max, 0)
    }

    // MARK: - Helpers

    private func writePlainSDRHEIC(size: PixelSize, to url: URL) throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = CIContext(options: [
            .workingColorSpace: displayP3,
            .outputColorSpace: displayP3,
            .cacheIntermediates: false,
        ])
        let image = CIImage(
            color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: displayP3)!
        ).cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        try context.writeHEIFRepresentation(
            of: image,
            to: url,
            format: .RGBA8,
            colorSpace: displayP3,
            options: [:]
        )
    }

    /// Builds a real `DeliveryReport` from the verifier's checks, so the report initializer's
    /// PASS/failures derivation and canonical ordering stay covered by the M4 tests.
    private func makeReport(fixture: Fixture, checks: [DeliveryReport.Check]) throws -> DeliveryReport {
        let hdrBytes = (try? FileManager.default.attributesOfItem(atPath: fixture.encodedHEIC.path)[.size] as? Int) ?? 0
        let fallbackBytes = (try? FileManager.default.attributesOfItem(atPath: fixture.fallbackHEIC.path)[.size] as? Int) ?? 0
        func artifact(_ url: URL, bytes: Int) -> DeliveryReport.FileArtifact {
            DeliveryReport.FileArtifact(
                file: url.lastPathComponent,
                bytes: bytes,
                sha256: (try? TestFixtures.sha256(ofFileAt: url)) ?? ""
            )
        }
        let profileReport = try DeliveryReport.ProfileReport(
            profile: DeliveryReport.ProfileReference(options: fixture.profile),
            render: DeliveryReport.Render(
                width: fixture.size.width,
                height: fixture.size.height,
                headroomCap: fixture.recipe.hdr.headroomCap,
                authoredPeak: Double(fixture.authoredPeak),
                fractionAboveOne: fixture.fractionAboveOne,
                fractionAtCap: fixture.fractionAtCap,
                previewLongEdge: PreviewRenderer.previewLongEdge(for: fixture.size, limit: 2560)
            ),
            artifacts: DeliveryReport.Artifacts(
                hdrHEIC: artifact(fixture.encodedHEIC, bytes: hdrBytes),
                sdrHEIC: artifact(fixture.fallbackHEIC, bytes: fallbackBytes),
                recipeJSON: DeliveryReport.FileArtifact(file: "fixture.recipe.json", bytes: 0, sha256: "")
            ),
            checks: checks,
            timings: DeliveryReport.Timings(
                decodeSeconds: 0,
                renderSeconds: 0,
                previewSeconds: 0,
                encodeSeconds: 0,
                verifySeconds: 0,
                totalSeconds: 0
            )
        )
        return try DeliveryReport(
            provenance: DeliveryReport.Provenance(encoderVersion: "coreimage-1"),
            source: DeliveryReport.SourceIdentity(
                path: "fixture/base.tif",
                sha256: fixture.sourceSHA256,
                width: fixture.size.width,
                height: fixture.size.height,
                profileName: "Display P3",
                bitsPerComponent: 16
            ),
            recipe: DeliveryReport.RecipeReference(recipe: fixture.recipe, renderKey: try fixture.recipe.renderKey()),
            profiles: [profileReport]
        )
    }
}
