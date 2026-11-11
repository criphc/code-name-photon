import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// P1-4 regression tests: the Stage-1 colour contract at decode.
///
/// Stage 1 accepts **Display P3** sources only (docs/reference/colour.md). Before the fix, a non-P3
/// export was colour-managed into linear extended P3 anyway and then silently clamped by the 16-bit
/// base write: Adobe RGB (1998)'s saturated green lands at linear P3 `r ≈ −0.15` and came out as 0,
/// changing the authoritative Capture One SDR base with no warning. The tests below pin both the
/// rejection (with an actionable message) and the fact that the old path really did lose that colour.
final class SourceColourTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = try TestFixtures.makeTemporaryDirectory(function: "source-colour")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: - a) Adobe RGB (1998): the silently-clipped input

    func testAdobeRGBSaturatedGreenIsRejectedWithActionableMessage() throws {
        let size = PixelSize(width: 16, height: 8)
        let url = temporaryDirectory.appendingPathComponent("adobe-rgb-green.tif")
        let adobeRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        // Adobe RGB's saturated green: outside the Display P3 gamut, exactly the input that used to
        // be converted into linear P3 with a negative red and then quantised to 0.
        let saturatedGreen = CIColor(red: 0, green: 1, blue: 0, alpha: 1, colorSpace: adobeRGB)!
        try TestFixtures.writeColourTIFF(size: size, colour: saturatedGreen, colourSpace: adobeRGB, to: url)
        let profile = try XCTUnwrap(TestFixtures.srcProfileName(of: url))
        XCTAssertTrue(profile.contains("Adobe RGB"), "fixture profile should be Adobe RGB 1998, got '\(profile)'")

        // Prove the failure mode P1-4 removes: the colour-managed working buffer really is outside
        // Display P3, and the 16-bit quantiser used to clamp that negative sample to 0.
        let preFixWorkingBuffer = try Self.renderLinearP3Samples(of: url)
        XCTAssertLessThan(
            preFixWorkingBuffer[0],
            -0.1,
            "Adobe RGB saturated green should decode to a clearly negative linear-P3 red"
        )
        XCTAssertEqual(
            SDRQuantiser.encoded16(preFixWorkingBuffer[0]),
            0,
            "the pre-fix path clamped the negative red to 0 — precisely the silent base change P1-4 forbids"
        )

        try assertRejected(url, namesProfile: "Adobe RGB (1998)")
    }

    // MARK: - b) sRGB and untagged sources are rejected too

    func testSRGBSourceIsRejected() throws {
        let size = PixelSize(width: 8, height: 4)
        let url = temporaryDirectory.appendingPathComponent("srgb-green.tif")
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let green = CIColor(red: 0, green: 1, blue: 0, alpha: 1, colorSpace: sRGB)!
        try TestFixtures.writeColourTIFF(size: size, colour: green, colourSpace: sRGB, to: url)
        let profile = try XCTUnwrap(TestFixtures.srcProfileName(of: url))
        XCTAssertTrue(profile.contains("sRGB"), "fixture profile should be sRGB, got '\(profile)'")

        try assertRejected(url, namesProfile: "sRGB")
    }

    func testUntaggedSourceIsRejected() throws {
        let url = temporaryDirectory.appendingPathComponent("untagged.tif")
        try TestFixtures.writeUntaggedTIFF(size: PixelSize(width: 8, height: 4), rgb: (0, 1, 0), to: url)
        XCTAssertNil(TestFixtures.srcProfileName(of: url), "fixture must not embed an ICC profile")

        // No profile means "not Display P3" like any other foreign profile: refuse, never guess.
        try assertRejected(url, namesProfile: "untagged")
    }

    // MARK: - c) Display P3 is still the accepted input

    func testDisplayP3SourceIsAccepted() throws {
        let size = PixelSize(width: 64, height: 16)
        let url = temporaryDirectory.appendingPathComponent("display-p3-source.tif")
        try TestFixtures.writeGradientP3TIFF(size: size, to: url)

        let decoded = try SourceDecoder.decode(url: url)
        XCTAssertEqual(decoded.size, size)
        XCTAssertEqual(decoded.bitsPerComponent, 16)
        XCTAssertTrue(decoded.linear.isOpaque)
        XCTAssertEqual(decoded.profileName, "Display P3")

        // The accepted path still does not clip: the 0.02…0.98 linear gradient survives into the
        // working buffer instead of being flattened at either end.
        let first = decoded.linear.pixel(x: 0, y: 0)
        let last = decoded.linear.pixel(x: size.width - 1, y: 0)
        XCTAssertGreaterThan(first.r, 0.0, "decode must not crush the dark end of the gradient to 0")
        XCTAssertLessThan(first.r, 0.05)
        XCTAssertGreaterThan(last.r, 0.95, "decode must not clip the bright end of the gradient early")
        XCTAssertLessThanOrEqual(last.r, 1.0)

        // Delta-E / full round-trip coverage lives in `ColourRoundTripTests`; this test only has to
        // keep the Display P3 input path open after the contract was added.
    }

    // MARK: - Helpers

    /// Asserts `SourceDecoder.decode` refuses `url` as `unsupportedSource` and that the message is
    /// actionable: it names the embedded profile, states the Display P3 requirement, says how to fix
    /// it, and points at the decision it comes from.
    private func assertRejected(
        _ url: URL,
        namesProfile: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(try SourceDecoder.decode(url: url), file: file, line: line) { error in
            guard case let PhotonError.unsupportedSource(reason)? = error as? PhotonError else {
                return XCTFail("expected unsupportedSource, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                reason.contains("embedded colour profile"),
                "reason should name the embedded profile: \(reason)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                reason.contains(namesProfile),
                "reason should name '\(namesProfile)': \(reason)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                reason.contains("is not Display P3"),
                "reason should state the Display P3 requirement: \(reason)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                reason.contains("export the SDR base as Display P3 from Capture One"),
                "reason should tell the user how to fix it: \(reason)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                reason.contains("docs/08") && reason.contains("§4"),
                "reason should cite docs/08 §4: \(reason)",
                file: file,
                line: line
            )
        }
    }

    /// Renders `url` through the pre-fix route — ImageIO `CGImage` → `CIImage` → linear extended
    /// Display P3 `RGBAf` — with no colour-space check, so a test can show what the decoder would
    /// have produced for a non-P3 source.
    private static func renderLinearP3Samples(of url: URL) throws -> [Float] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.lastPathComponent)")
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "cannot decode \(url.lastPathComponent)")
        let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .outputColorSpace: linearP3,
            .cacheIntermediates: false,
        ])
        var pixels = [Float](repeating: .nan, count: cgImage.width * cgImage.height * 4)
        context.render(
            CIImage(cgImage: cgImage),
            toBitmap: &pixels,
            rowBytes: cgImage.width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height),
            format: .RGBAf,
            colorSpace: linearP3
        )
        return pixels
    }
}
