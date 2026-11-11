import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// Contract tests for the external encoder shell-out (the migration **oracle**; the production
/// writer is `CoreImageHEICEncoder`): configuration validation, executable discovery, the exact
/// documented command line, and one real encode on a tiny generated pair.
///
/// `tools/toGainMapHDR` is an independent MIT clone that the repo does not track; when it is
/// missing the oracle tests skip (the in-process writer's tests cover the production path).
final class EncoderTests: XCTestCase {
    // MARK: - Locating the real tool

    /// `server/Tests/EngineKitTests/EncoderTests.swift` → the repository root.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EngineKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // server
            .deletingLastPathComponent() // repo root
    }

    private static var repoEncoderURL: URL {
        repositoryRoot.appendingPathComponent(Encoder.defaultRelativePath)
    }

    /// Returns the repo oracle, or skips the oracle-only test with installation instructions.
    private static func requireRepoEncoder() throws -> URL {
        guard Encoder.isExecutable(repoEncoderURL) else {
            throw XCTSkip("""
                the external oracle is not installed at \(repoEncoderURL.path); clone \
                tools/toGainMapHDR and build bin/toGainMapHDR to run the oracle tests. The \
                production Core Image writer is covered by CoreImageHEICEncoderTests.
                """)
        }
        return repoEncoderURL
    }

    // MARK: - Configuration

    func testConfigurationDefaultsMatchDocumentedFlags() throws {
        let configuration = try EncoderConfiguration(executableURL: URL(fileURLWithPath: "/tmp/toGainMapHDR"))
        XCTAssertEqual(configuration.quality, 0.85)
        XCTAssertEqual(configuration.depth, 8)
    }

    func testConfigurationRejectsQualityOutOfRange() throws {
        for quality in [-0.001, 1.001, .nan] {
            assertInvalidRecipe(field: "encoder.quality") {
                _ = try EncoderConfiguration(executableURL: URL(fileURLWithPath: "/tmp/e"), quality: quality)
            }
        }
    }

    func testConfigurationRejectsDepthOutside8And10() throws {
        for depth in [0, 6, 7, 9, 12, 16] {
            assertInvalidRecipe(field: "encoder.depth") {
                _ = try EncoderConfiguration(executableURL: URL(fileURLWithPath: "/tmp/e"), depth: depth)
            }
        }
        XCTAssertNoThrow(try EncoderConfiguration(executableURL: URL(fileURLWithPath: "/tmp/e"), depth: 8))
        XCTAssertNoThrow(try EncoderConfiguration(executableURL: URL(fileURLWithPath: "/tmp/e"), depth: 10))
    }

    // MARK: - Executable discovery

    func testResolveExplicitMissingThrowsEncoderMissing() {
        let missing = URL(fileURLWithPath: "/definitely/not/here/toGainMapHDR")
        XCTAssertThrowsError(try Encoder.resolveExecutable(explicit: missing, environment: [:])) { error in
            guard case let PhotonError.encoderMissing(path)? = error as? PhotonError else {
                return XCTFail("expected encoderMissing, got \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testResolveExplicitNonExecutableThrowsEncoderMissing() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plainFile = directory.appendingPathComponent("toGainMapHDR")
        try Data("not a binary".utf8).write(to: plainFile)
        XCTAssertThrowsError(try Encoder.resolveExecutable(explicit: plainFile, environment: [:])) { error in
            guard case PhotonError.encoderMissing? = error as? PhotonError else {
                return XCTFail("expected encoderMissing, got \(error)")
            }
        }
    }

    func testResolveUsesEnvironmentVariable() throws {
        // /bin/ls is an executable file, which is all discovery checks.
        let resolved = try Encoder.resolveExecutable(
            explicit: nil,
            environment: ["PHOTON_ENCODER": "/bin/ls"]
        )
        XCTAssertEqual(resolved.path, "/bin/ls")
    }

    func testResolveRejectsBadEnvironmentVariable() {
        XCTAssertThrowsError(
            try Encoder.resolveExecutable(explicit: nil, environment: ["PHOTON_ENCODER": "/nope/toGainMapHDR"])
        ) { error in
            guard case PhotonError.encoderMissing? = error as? PhotonError else {
                return XCTFail("expected encoderMissing, got \(error)")
            }
        }
    }

    func testResolveFindsRepoToolFromPackageDirectory() throws {
        let expected = try Self.requireRepoEncoder()
        // `swift test` runs with the package directory as the working directory (server/);
        // discovery must walk up to the repo root.
        let resolved = try Encoder.resolveExecutable(explicit: nil, environment: [:])
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            expected.standardizedFileURL.path,
            "expected the repo tool when the working directory is server/"
        )
    }

    // MARK: - The command line (docs/reference/encoder.md)

    func testCommandMatchesTheDocumentedForm() throws {
        let configuration = try EncoderConfiguration(executableURL: URL(fileURLWithPath: "/enc"))
        let arguments = Encoder.arguments(
            hdrTIFF: URL(fileURLWithPath: "/w/hdr.tif"),
            baseTIFF: URL(fileURLWithPath: "/w/sdr.tif"),
            outputDirectory: URL(fileURLWithPath: "/w/out"),
            headroomCap: 2.5,
            configuration: configuration
        )
        XCTAssertEqual(arguments, [
            "/w/hdr.tif", "/w/out",
            "-b", "/w/sdr.tif",
            "-R", "2.5",
            "-d", "8",
            "-q", "0.85",
            "-c", "p3",
        ])
        // M0 measured that -H corrupts the headroom metadata and clips highlights.
        XCTAssertFalse(arguments.contains("-H"))
    }

    // MARK: - Real encode (tiny synthetic pair)

    /// The one end-to-end encode test: a 96×64 base+HDR pair through the real `toGainMapHDR`.
    /// Review P1-5: `ftyp` used to be the whole assertion, so a plain SDR HEIC could pass. It now
    /// asserts the ISO gain-map aux, `contentHeadroom` within 5 % of the 2.5 cap (either number
    /// ImageIO reports), no alpha and the exact size — via `EncodedHEICValidator`, the production
    /// gate — and keeps the wrong-headroom rejection.
    func testEncodeTinyPairProducesGainMapHEIC() throws {
        let encoderURL = try Self.requireRepoEncoder()
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = PixelSize(width: 96, height: 64)
        let baseURL = directory.appendingPathComponent("base.tif")

        // The base must be the 3-sample TIFF `TIFFWriter` writes, not the 4-channel RGBA16
        // `TestFixtures.writeGradientP3TIFF` fixture: the probe showed a 4-channel base makes the
        // encoded HEIC carry an alpha plane, while this layout yields the alpha-free deliverable.
        var basePixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = Float(x) / Float(size.width - 1)
                let value = 0.02 + (0.98 - 0.02) * t
                let index = (y * size.width + x) * 4
                basePixels[index] = value
                basePixels[index + 1] = value
                basePixels[index + 2] = value
            }
        }
        let base = try LinearImage(size: size, pixels: basePixels)
        try TIFFWriter.writeSDRBase(base, to: baseURL)

        // The HDR input must be a 4-channel RGBAf float TIFF ("docs/reference/encoder.md") — TIFFWriter owns
        // that layout; the buffer itself is the same uniform-grey-to-known-peak pair as M0.
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = Float(x) / Float(size.width - 1)
                let value = 0.05 + (2.5 - 0.05) * t
                let index = (y * size.width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let hdr = try LinearImage(size: size, pixels: pixels)
        let hdrURL = directory.appendingPathComponent("hdr.tif")
        try TIFFWriter.writeHDR(hdr, to: hdrURL)

        let outputDirectory = directory.appendingPathComponent("encoded", isDirectory: true)
        let configuration = try EncoderConfiguration(executableURL: encoderURL, quality: 0.85, depth: 8)
        let encoder = Encoder(configuration: configuration)
        let encoded = try encoder.encode(
            hdrTIFF: hdrURL,
            baseTIFF: baseURL,
            outputDirectory: outputDirectory,
            headroomCap: 2.5
        )

        XCTAssertEqual(encoded.lastPathComponent, "hdr.heic", "the tool names output after the HDR stem")
        let data = try Data(contentsOf: encoded)
        XCTAssertGreaterThan(data.count, 0)
        let header = [UInt8](data.prefix(12))
        XCTAssertEqual(Array(header[4..<8]), Array("ftyp".utf8), "not an ISO BMFF file: \(header)")

        // The read-back contract (review P0-1, tightened by P1-5): `ftyp` alone is not evidence —
        // a plain SDR HEIC carries it too. Assert the structural gain-map facts through ImageIO
        // (`EncodedHEICValidator`, the same gate `Pipeline.prepare` uses) and the advertised
        // headroom here: ISO auxiliary gain map, SDR decode without alpha, exact dimensions, and
        // a 5 % headroom match (the delivery report's gate — ADR-0012; the structural validator
        // leaves that match to the verifier).
        let facts = try EncodedHEICValidator.validate(encoded, expectedSize: size)
        XCTAssertTrue(facts.isoGainMapPresent, "the encoded pair must carry an ISO auxiliary gain map")
        XCTAssertTrue(facts.hdrDecoded, "kCGImageSourceDecodeRequest=kCGImageSourceDecodeToHDR must succeed")
        XCTAssertFalse(facts.sdrHasAlpha, "the preserved base is 3-sample RGB, so the HEIC has no alpha")
        XCTAssertEqual(facts.width, size.width, "encoded width")
        XCTAssertEqual(facts.height, size.height, "encoded height")
        let headroomCandidates = [facts.contentHeadroom, facts.calculatedContentHeadroom].filter { $0 > 1.0 }
        XCTAssertFalse(
            headroomCandidates.isEmpty,
            "no headroom advertised (contentHeadroom \(facts.contentHeadroom), "
                + "calculatedContentHeadroom \(facts.calculatedContentHeadroom))"
        )
        XCTAssertTrue(
            headroomCandidates.contains { abs($0 / 2.5 - 1.0) <= EncodedHEICValidator.headroomTolerance },
            "advertised headroom must be within 5 % of the 2.5 cap; got contentHeadroom "
                + "\(facts.contentHeadroom), calculatedContentHeadroom \(facts.calculatedContentHeadroom)"
        )

    }

    /// The failure mode review P0-1 found: a peak-0.5 pair encodes with **exit 0** and a HEIC
    /// path, but the file is a plain SDR HEIC (no ISO gain map). The validator must reject it;
    /// the pipeline refuses the pair before the encoder ever runs
    /// (`DeterminismTests.testPrepareRefusesARenderBelowTheAuthoredPeakFloor`).
    func testDimPairEncodesToPlainSDRAndTheValidatorRejectsIt() throws {
        let encoderURL = try Self.requireRepoEncoder()
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = PixelSize(width: 96, height: 64)
        let baseURL = directory.appendingPathComponent("base.tif")
        try TIFFWriter.writeSDRBase(
            LinearImage(size: size, repeating: RGBA(r: 0.1, g: 0.1, b: 0.1)),
            to: baseURL
        )

        // HDR peak 0.5: below the 1.05 floor, so there is no headroom for the tool to advertise.
        var hdrPixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = Float(x) / Float(size.width - 1)
                let value = 0.05 + (0.5 - 0.05) * t
                let index = (y * size.width + x) * 4
                hdrPixels[index] = value
                hdrPixels[index + 1] = value
                hdrPixels[index + 2] = value
            }
        }
        let hdrURL = directory.appendingPathComponent("hdr.tif")
        try TIFFWriter.writeHDR(try LinearImage(size: size, pixels: hdrPixels), to: hdrURL)

        let outputDirectory = directory.appendingPathComponent("encoded", isDirectory: true)
        let configuration = try EncoderConfiguration(executableURL: encoderURL, quality: 0.85, depth: 8)
        let encoder = Encoder(configuration: configuration)

        // Exit 0 is not a success signal for this tool: it still returns an encoded path.
        let encoded = try encoder.encode(
            hdrTIFF: hdrURL,
            baseTIFF: baseURL,
            outputDirectory: outputDirectory,
            headroomCap: 2.5
        )

        let facts = try EncodedHEICValidator.inspect(encoded)
        XCTAssertFalse(facts.isoGainMapPresent, "a peak-0.5 pair cannot carry an ISO gain map")
        XCTAssertLessThanOrEqual(facts.contentHeadroom, 1.0, "plain SDR advertises no headroom")

        XCTAssertThrowsError(
            try EncodedHEICValidator.validate(encoded, expectedSize: size)
        ) { error in
            guard case let PhotonError.encoderOutputInvalid(_, reason)? = error as? PhotonError else {
                return XCTFail("expected encoderOutputInvalid, got \(error)")
            }
            XCTAssertTrue(
                reason.contains("ISO") || reason.contains("gain-map"),
                "the reason must name the missing ISO gain map: \(reason)"
            )
        }
    }

    // MARK: - Helpers

    private func assertInvalidRecipe(
        field: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case let PhotonError.invalidRecipe(actualField, _)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(actualField, field, file: file, line: line)
        }
    }
}
