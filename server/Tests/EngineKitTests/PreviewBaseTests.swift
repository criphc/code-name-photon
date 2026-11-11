import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import EngineKit

/// The M2.1 wire format: a 16-bit Display P3 PNG of the SDR base. These tests pin the properties
/// the iPad shader depends on (bit depth, ICC profile, no alpha, exact geometry, determinism).
final class PreviewBaseTests: XCTestCase {
    private func temporarySource(
        gradient: PixelSize = PixelSize(width: 240, height: 160)
    ) throws -> (directory: URL, source: URL) {
        let directory = try TestFixtures.makeTemporaryDirectory()
        let source = directory.appendingPathComponent("source.tif")
        try TestFixtures.writeGradientP3TIFF(size: gradient, to: source)
        return (directory, source)
    }

    func testRenders16BitP3PNGWithExpectedMetadata() throws {
        let fixture = try temporarySource()
        let out = fixture.directory.appendingPathComponent("item")
        let result = try PreviewBaseRenderer.render(sourceURL: fixture.source, longEdge: 120, to: out)

        XCTAssertEqual(result.base.size, PixelSize(width: 120, height: 80))
        XCTAssertEqual(result.longEdge, 120)
        XCTAssertEqual(result.base.format, "png-16-p3")
        XCTAssertEqual(result.workingSpace, "linear-extended-DisplayP3-float32")
        XCTAssertEqual(result.sourceSHA256, try TestFixtures.sha256(ofFileAt: fixture.source))
        XCTAssertEqual(result.base.sha256, try TestFixtures.sha256(ofFileAt: result.base.url))

        let data = try Data(contentsOf: result.base.url)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(result.base.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyDepth] as? NSNumber)?.intValue, 16)
        // ImageIO omits kCGImagePropertyHasAlpha for 16-bit RGB PNGs; assert via the decoded image.
        XCTAssertNotEqual((properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue, true)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertFalse(
            [CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(decoded.alphaInfo),
            "base PNG must have no alpha channel, got \(decoded.alphaInfo.rawValue)"
        )
        XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "Display P3")
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 120)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 80)

        let encodedBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: result.base.url.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertEqual(result.base.bytes, encodedBytes)
    }

    func testPNGIsDeterministic() throws {
        let fixture = try temporarySource()
        let first = try PreviewBaseRenderer.render(
            sourceURL: fixture.source, longEdge: 120,
            to: fixture.directory.appendingPathComponent("a")
        )
        let second = try PreviewBaseRenderer.render(
            sourceURL: fixture.source, longEdge: 120,
            to: fixture.directory.appendingPathComponent("b")
        )
        XCTAssertEqual(first.base.sha256, second.base.sha256)
        XCTAssertEqual(first.base.bytes, second.base.bytes)
    }

    func testNeverUpscales() throws {
        let fixture = try temporarySource(gradient: PixelSize(width: 96, height: 64))
        let result = try PreviewBaseRenderer.render(
            sourceURL: fixture.source, longEdge: 2560,
            to: fixture.directory.appendingPathComponent("item")
        )
        XCTAssertEqual(result.base.size, PixelSize(width: 96, height: 64))
    }

    func testUniformValueSurvivesThePNG16RoundTrip() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        let source = directory.appendingPathComponent("uniform.tif")
        try TestFixtures.writeUniformP3TIFF(size: PixelSize(width: 64, height: 48), linearValue: 0.5, to: source)
        let result = try PreviewBaseRenderer.render(
            sourceURL: source, longEdge: 64,
            to: directory.appendingPathComponent("item")
        )

        let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [.workingColorSpace: linearP3, .outputColorSpace: linearP3, .cacheIntermediates: false])
        let image = try XCTUnwrap(CIImage(contentsOf: result.base.url))
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 32, y: 24, width: 1, height: 1),
            format: .RGBAf, colorSpace: linearP3
        )
        XCTAssertEqual(pixel[0], 0.5, accuracy: 0.002)
        XCTAssertEqual(pixel[1], 0.5, accuracy: 0.002)
        XCTAssertEqual(pixel[2], 0.5, accuracy: 0.002)
    }

    // MARK: - Atomic write (review P1-7)

    /// `base.bytes`/`base.sha256` always describe the final `preview-base.png` — including after a
    /// re-render replaces it, which is the whole point of the atomic rename. (The "no `.tmp` after
    /// a render" half of P1-7 is pinned by `PipelineAtomicityTests`.)
    func testReportedBytesAndSHA256MatchTheFinalFileAfterReRender() throws {
        let fixture = try temporarySource()
        let out = fixture.directory.appendingPathComponent("item")
        let first = try PreviewBaseRenderer.render(sourceURL: fixture.source, longEdge: 120, to: out)

        let firstData = try Data(contentsOf: first.base.url)
        XCTAssertEqual(first.base.bytes, firstData.count)
        XCTAssertEqual(first.base.sha256, try TestFixtures.sha256(ofFileAt: first.base.url))

        // Same directory, different target size: the old PNG must be replaced in one step and the
        // reported facts must be re-measured on the new file, not carried over.
        let second = try PreviewBaseRenderer.render(sourceURL: fixture.source, longEdge: 60, to: out)
        XCTAssertEqual(second.base.url, first.base.url, "the final path must stay preview-base.png")
        XCTAssertEqual(second.base.size, PixelSize(width: 60, height: 40))
        XCTAssertNotEqual(second.base.sha256, first.base.sha256)

        let secondData = try Data(contentsOf: second.base.url)
        XCTAssertEqual(secondData.count, second.base.bytes)
        XCTAssertEqual(second.base.sha256, try TestFixtures.sha256(ofFileAt: second.base.url))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(secondData as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(PixelSize(width: decoded.width, height: decoded.height), PixelSize(width: 60, height: 40))

        let entries = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(entries, [PreviewBaseRenderer.fileName], "re-render left extra files: \(entries)")
    }
}
