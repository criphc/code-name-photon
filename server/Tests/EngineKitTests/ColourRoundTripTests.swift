import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EngineKit

/// M1-A acceptance tests: decode → identity SDR base → TIFF writes → decode/read back.
///
/// Everything is generated at run time by `TestFixtures` (no `samples/`, no `work/`), and the
/// images are deliberately small so the suite stays well under the 5 s budget. The TIFF routes
/// and layout assertions mirror what M0 measured (docs/archive/stage-1/03-considerations-beyond-the-plan.md §3,
/// docs/archive/stage-1/05-encoder-verification.md §6).
final class ColourRoundTripTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = try TestFixtures.makeTemporaryDirectory(function: "colour-round-trip")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: - Decode determinism

    func testDecodeIsDeterministicAndReportsSourceLayout() throws {
        let size = PixelSize(width: 96, height: 32)
        let url = temporaryDirectory.appendingPathComponent("gradient.tif")
        try TestFixtures.writeGradientP3TIFF(size: size, to: url)

        let first = try SourceDecoder.decode(url: url)
        let second = try SourceDecoder.decode(url: url)

        XCTAssertEqual(first.size, size)
        XCTAssertEqual(first.bitsPerComponent, 16)
        XCTAssertEqual(first.linear.size, size)
        XCTAssertTrue(first.linear.isOpaque, "decode must force alpha to 1")

        // Deterministic: same file through the same route yields identical samples and identity.
        XCTAssertEqual(first.linear.pixels, second.linear.pixels)
        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(first.sha256, try TestFixtures.sha256(ofFileAt: url))

        // The fixture is a 16-bit Display P3 TIFF written by Core Image.
        let profile = try XCTUnwrap(first.profileName)
        XCTAssertTrue(profile.contains("P3"), "unexpected profile name '\(profile)'")
    }

    // MARK: - SDR base round trip (16-bit Display P3, no alpha)

    func testSDRBaseRoundTripStaysWithinDeltaE2000Budgets() throws {
        let size = PixelSize(width: 128, height: 32)
        let sourceURL = temporaryDirectory.appendingPathComponent("gradient-source.tif")
        try TestFixtures.writeGradientP3TIFF(size: size, to: sourceURL)

        let decoded = try SourceDecoder.decode(url: sourceURL)
        XCTAssertEqual(decoded.size, size)

        // c1_match_v1 is an identity tone map: a new buffer, every sample unchanged.
        let toneMap = try ToneMapKind.named("c1_match_v1")
        XCTAssertEqual(toneMap.name, "c1_match_v1")
        let base = try ToneMapper.sdrBase(from: decoded.linear, toneMap: toneMap)
        XCTAssertEqual(base.pixels, decoded.linear.pixels, "c1_match_v1 must not touch a sample")
        XCTAssertTrue(base.isOpaque)

        let sdrURL = temporaryDirectory.appendingPathComponent("sdr.tif")
        try TIFFWriter.writeSDRBase(base, to: sdrURL)

        // Read-back layout: 16 bpc, 3 samples (no alpha), Display P3 profile, orientation 1.
        let properties = try Self.properties(of: sdrURL)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "Display P3")

        let cgImage = try XCTUnwrap(Self.makeImage(at: sdrURL))
        XCTAssertEqual(cgImage.bitsPerComponent, 16)
        XCTAssertEqual(cgImage.bitsPerPixel / cgImage.bitsPerComponent, 3, "SDR base must have no alpha sample")
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            break
        default:
            XCTFail("SDR base unexpectedly carries alpha (\(cgImage.alphaInfo.rawValue))")
        }

        // Decode the written TIFF back and compare colour: 16-bit display-referred round trip.
        let roundTripped = try SourceDecoder.decode(url: sdrURL)
        XCTAssertEqual(roundTripped.size, size)
        XCTAssertEqual(roundTripped.bitsPerComponent, 16)

        let deltas = try Self.deltaE2000(between: decoded.linear, and: roundTripped.linear)
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let p95 = Self.percentile(deltas, 0.95)
        let maxDelta = deltas.max() ?? 0
        print(String(
            format: "SDR base round trip (16-bit Display P3): n=%d ΔE2000 mean=%.8f p95=%.8f max=%.8f",
            deltas.count, mean, p95, maxDelta
        ))
        XCTAssertLessThan(mean, 0.5, "mean ΔE2000 after the 16-bit round trip")
        XCTAssertLessThan(p95, 1.0, "p95 ΔE2000 after the 16-bit round trip")
    }

    // MARK: - Writer determinism

    func testTIFFWritesAreDeterministic() throws {
        let gradientURL = temporaryDirectory.appendingPathComponent("det-source.tif")
        try TestFixtures.writeGradientP3TIFF(size: PixelSize(width: 32, height: 8), to: gradientURL)
        let decoded = try SourceDecoder.decode(url: gradientURL)
        let base = try ToneMapper.sdrBase(from: decoded.linear, toneMap: .c1MatchV1)

        let sdrA = temporaryDirectory.appendingPathComponent("sdr-a.tif")
        let sdrB = temporaryDirectory.appendingPathComponent("sdr-b.tif")
        try TIFFWriter.writeSDRBase(base, to: sdrA)
        try TIFFWriter.writeSDRBase(base, to: sdrB)
        XCTAssertEqual(try TestFixtures.sha256(ofFileAt: sdrA), try TestFixtures.sha256(ofFileAt: sdrB))
        XCTAssertEqual(try Data(contentsOf: sdrA), try Data(contentsOf: sdrB))

        let hdrImage = try LinearImage(size: PixelSize(width: 2, height: 2), pixels: [
            0.5, 1.5, 2.5, 1, 1.0, 1.0, 1.0, 1,
            2.5, 0.5, 1.5, 1, 0.0, 0.5, 1.0, 1,
        ])
        let hdrA = temporaryDirectory.appendingPathComponent("hdr-a.tif")
        let hdrB = temporaryDirectory.appendingPathComponent("hdr-b.tif")
        try TIFFWriter.writeHDR(hdrImage, to: hdrA)
        try TIFFWriter.writeHDR(hdrImage, to: hdrB)
        XCTAssertEqual(try TestFixtures.sha256(ofFileAt: hdrA), try TestFixtures.sha256(ofFileAt: hdrB))
        XCTAssertEqual(try Data(contentsOf: hdrA), try Data(contentsOf: hdrB))
    }

    // MARK: - Source contract

    func testDecodeRejectsNonIdentityOrientation() throws {
        let gradientURL = temporaryDirectory.appendingPathComponent("orientation-source.tif")
        try TestFixtures.writeGradientP3TIFF(size: PixelSize(width: 8, height: 4), to: gradientURL)
        let orientedURL = temporaryDirectory.appendingPathComponent("orientation-6.tif")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gradientURL as CFURL, nil))
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            orientedURL as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let properties = try Self.properties(of: orientedURL)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)

        XCTAssertThrowsError(try SourceDecoder.decode(url: orientedURL)) { error in
            guard case let PhotonError.unsupportedOrientation(orientation)? = error as? PhotonError else {
                return XCTFail("expected unsupportedOrientation, got \(error)")
            }
            XCTAssertEqual(orientation, 6)
        }
    }

    func testDecodeRejectsNonImageFiles() throws {
        let url = temporaryDirectory.appendingPathComponent("not-an-image.tif")
        try Data("this is not a TIFF".utf8).write(to: url)
        XCTAssertThrowsError(try SourceDecoder.decode(url: url)) { error in
            guard case PhotonError.sourceUnreadable? = error as? PhotonError else {
                return XCTFail("expected sourceUnreadable, got \(error)")
            }
        }
        XCTAssertThrowsError(try SourceDecoder.sha256(ofFileAt: temporaryDirectory.appendingPathComponent("missing.bin"))) { error in
            guard case PhotonError.sourceUnreadable? = error as? PhotonError else {
                return XCTFail("expected sourceUnreadable, got \(error)")
            }
        }
    }

    // MARK: - Streaming SHA-256

    func testSHA256MatchesWholeFileCryptoKitHash() throws {
        // A >8 MB file crosses the streaming chunk boundary; include a fixture TIFF too.
        var data = Data(count: 9 * 1024 * 1024 + 123)
        for index in data.indices {
            data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
        }
        let bigURL = temporaryDirectory.appendingPathComponent("big.bin")
        try data.write(to: bigURL)
        let expected = try TestFixtures.sha256(ofFileAt: bigURL)
        XCTAssertEqual(try SourceDecoder.sha256(ofFileAt: bigURL), expected)
        XCTAssertEqual(expected.count, 64)
        XCTAssertEqual(expected, expected.lowercased())

        let gradientURL = temporaryDirectory.appendingPathComponent("sha-source.tif")
        try TestFixtures.writeGradientP3TIFF(size: PixelSize(width: 16, height: 4), to: gradientURL)
        XCTAssertEqual(
            try SourceDecoder.sha256(ofFileAt: gradientURL),
            try TestFixtures.sha256(ofFileAt: gradientURL)
        )
    }

    // MARK: - Tone map contract

    func testToneMapperRejectsUnknownNamesAndNonFiniteInput() throws {
        XCTAssertEqual(try ToneMapKind.named("c1_match_v1"), .c1MatchV1)
        XCTAssertThrowsError(try ToneMapKind.named("film_v2")) { error in
            guard case let PhotonError.invalidRecipe(field, _)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)")
            }
            XCTAssertEqual(field, "base.tone_map")
        }

        var nanPixels = [Float](repeating: 0.5, count: 2 * 2 * 4)
        nanPixels[3] = 1
        nanPixels[0] = .nan
        let nonFinite = try LinearImage(size: PixelSize(width: 2, height: 2), pixels: nanPixels)
        XCTAssertThrowsError(try ToneMapper.sdrBase(from: nonFinite, toneMap: .c1MatchV1)) { error in
            guard case PhotonError.invalidImage? = error as? PhotonError else {
                return XCTFail("expected invalidImage, got \(error)")
            }
        }

        // Value semantics: mutating the returned base must not touch the decoded source.
        let sourceImage = try LinearImage(size: PixelSize(width: 2, height: 1), pixels: [
            0.1, 0.2, 0.3, 1, 0.4, 0.5, 0.6, 1,
        ])
        var base = try ToneMapper.sdrBase(from: sourceImage, toneMap: .c1MatchV1)
        base.setPixel(x: 0, y: 0, RGBA(r: 9, g: 9, b: 9))
        XCTAssertEqual(sourceImage.pixel(x: 0, y: 0), RGBA(r: 0.1, g: 0.2, b: 0.3))
    }

    // MARK: - Helpers

    private static func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.lastPathComponent)")
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private static func makeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func deltaE2000(between lhs: LinearImage, and rhs: LinearImage) throws -> [Double] {
        guard lhs.size == rhs.size else {
            throw PhotonError.dimensionMismatch(
                expectedWidth: lhs.size.width,
                expectedHeight: lhs.size.height,
                actualWidth: rhs.size.width,
                actualHeight: rhs.size.height
            )
        }
        var deltas: [Double] = []
        deltas.reserveCapacity(lhs.size.pixelCount)
        var index = 0
        while index < lhs.pixels.count {
            let a = RGBA(r: lhs.pixels[index], g: lhs.pixels[index + 1], b: lhs.pixels[index + 2])
            let b = RGBA(r: rhs.pixels[index], g: rhs.pixels[index + 1], b: rhs.pixels[index + 2])
            deltas.append(Colorimetry.deltaE2000(a, b))
            index += 4
        }
        return deltas
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}
