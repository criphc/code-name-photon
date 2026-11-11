import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import EngineKit

/// `ThumbnailRenderer` tests (ADR-0013): the filmstrip thumbnail is a 512-high Display P3 HEIC
/// produced by ImageIO from the source TIFF — never by `PreviewBaseRenderer`.
///
/// Every source is generated at run time (16-bit Display P3 TIFF, the shape of a Capture One
/// export), so the suite needs no `samples/` and no `work/`.
final class ThumbnailRendererTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = try TestFixtures.makeTemporaryDirectory(function: "thumbnail-renderer")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: - Harness

    private func outputDirectory() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            "no image properties for \(url.path)"
        )
    }

    private var displayP3Name: String? {
        CGColorSpace(name: CGColorSpace.displayP3)?.name as String?
    }

    /// Re-wraps `source` with a TIFF orientation tag, so the renderer's orientation guard can be
    /// exercised (the pixels are irrelevant: orientation is checked before anything is decoded).
    private func writeOrientedCopy(of source: URL, orientation: Int, to url: URL) throws {
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination), "cannot write the oriented fixture")
        XCTAssertEqual(
            try properties(of: url)[kCGImagePropertyOrientation] as? Int,
            orientation,
            "the fixture must really carry orientation \(orientation)"
        )
    }

    // MARK: - The happy path

    func testRenderProducesA512HighDisplayP3HEIC() throws {
        let source = temporaryDirectory.appendingPathComponent("landscape.tif")
        try TestFixtures.writeGradientP3TIFF(size: PixelSize(width: 900, height: 600), to: source)
        let output = try outputDirectory()

        let result = try ThumbnailRenderer.render(sourceURL: source, to: output)

        // File name carries the height and the renderer tag (the cache key's file-name half).
        XCTAssertEqual(result.url.lastPathComponent, "thumbnail-512-v1.heic")
        XCTAssertEqual(ThumbnailRenderer.fileName(), "thumbnail-512-v1.heic")
        XCTAssertEqual(ThumbnailRenderer.fileName(height: 256), "thumbnail-256-v1.heic")
        XCTAssertEqual(result.format, "heic-10-p3")

        // Height first: a 3:2 landscape is 768×512. Long-edge sizing would have produced 512×341.
        XCTAssertEqual(result.size, PixelSize(width: 768, height: 512))

        // The facts describe the file on disk, and the atomic temp file is gone.
        let attributes = try FileManager.default.attributesOfItem(atPath: result.url.path)
        XCTAssertEqual(result.bytes, (attributes[.size] as? NSNumber)?.intValue)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.sha256.count, 64)
        XCTAssertEqual(result.sha256, try TestFixtures.sha256(ofFileAt: result.url))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: output.path),
            ["thumbnail-512-v1.heic"],
            "the temp file must be renamed away, not left beside the thumbnail"
        )

        // ImageIO can open it, it is 512 high, and it is Display P3 — the filmstrip's contract.
        let heic = try properties(of: result.url)
        XCTAssertEqual(heic[kCGImagePropertyPixelHeight] as? Int, 512)
        XCTAssertEqual(heic[kCGImagePropertyPixelWidth] as? Int, 768)
        XCTAssertEqual(heic[kCGImagePropertyProfileName] as? String, "Display P3")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.colorSpace?.name as String?, displayP3Name)
    }

    /// The `max(1, width / height)` clamp: a portrait source is still 512 high, never upscaled.
    func testPortraitSourceIsAlso512High() throws {
        let source = temporaryDirectory.appendingPathComponent("portrait.tif")
        try TestFixtures.writeGradientP3TIFF(size: PixelSize(width: 600, height: 900), to: source)

        let result = try ThumbnailRenderer.render(sourceURL: source, to: try outputDirectory())

        XCTAssertEqual(result.size, PixelSize(width: 341, height: 512))
    }

    /// A panorama must not produce an enormous HEIC. The old path (downscaling the 2560 px preview
    /// base) could never be wider than 2560, so the width cap keeps that bound: without it a
    /// 4000×200 source would render 4000 px wide.
    func testPanoramaIsCappedAt2560Wide() throws {
        let source = temporaryDirectory.appendingPathComponent("panorama.tif")
        try TestFixtures.writeGradientP3TIFF(size: PixelSize(width: 4000, height: 200), to: source)

        let result = try ThumbnailRenderer.render(sourceURL: source, to: try outputDirectory())

        XCTAssertLessThanOrEqual(result.size.width, 2560, "a panorama must not exceed the width cap")
        XCTAssertLessThanOrEqual(result.size.height, 512)
        XCTAssertEqual(result.size, PixelSize(width: 2560, height: 128), "the cap bounds the width, not the aspect")
    }

    // MARK: - Refusals (checked before anything is written)

    func testNonDisplayP3SourceIsRefusedBeforeWriting() throws {
        let source = temporaryDirectory.appendingPathComponent("srgb.tif")
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try TestFixtures.writeColourTIFF(
            size: PixelSize(width: 900, height: 600),
            colour: try XCTUnwrap(CIColor(red: 0, green: 1, blue: 0, alpha: 1, colorSpace: sRGB)),
            colourSpace: sRGB,
            to: source
        )
        let output = try outputDirectory()

        XCTAssertThrowsError(try ThumbnailRenderer.render(sourceURL: source, to: output)) { error in
            guard let photonError = error as? PhotonError, case .unsupportedSource = photonError else {
                return XCTFail("expected unsupportedSource, got \(error)")
            }
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: output.path),
            [],
            "a refused source must leave no thumbnail behind"
        )
    }

    func testRotatedSourceIsRefused() throws {
        let plain = temporaryDirectory.appendingPathComponent("plain.tif")
        try TestFixtures.writeGradientP3TIFF(size: PixelSize(width: 900, height: 600), to: plain)
        let rotated = temporaryDirectory.appendingPathComponent("rotated.tif")
        try writeOrientedCopy(of: plain, orientation: 6, to: rotated)
        let output = try outputDirectory()

        XCTAssertThrowsError(try ThumbnailRenderer.render(sourceURL: rotated, to: output)) { error in
            XCTAssertEqual(error as? PhotonError, .unsupportedOrientation(6))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testUnreadableSourceIsRefused() throws {
        let source = temporaryDirectory.appendingPathComponent("broken.tif")
        try Data("this is not a TIFF".utf8).write(to: source)
        let output = try outputDirectory()

        XCTAssertThrowsError(try ThumbnailRenderer.render(sourceURL: source, to: output)) { error in
            guard let photonError = error as? PhotonError, case .sourceUnreadable = photonError else {
                return XCTFail("expected sourceUnreadable, got \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }
}
