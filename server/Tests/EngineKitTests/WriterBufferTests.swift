import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// Review P1-3: `TIFFWriter.writeHDR` must build its `CIImage` through the shared provider-backed
/// ownership chain (ImageBuffers: `CIImage` → `CGImage` → `CGDataProvider` → `Data`), not through
/// Core Image's bitmap-data initializer, which docs/reference/encoder.md forbids. These tests pin what that route
/// has to preserve:
///
/// - values above 1.0 (the whole point of the HDR rendition) and negative / out-of-range samples
///   survive the float-TIFF write exactly, with no NaN;
/// - the same buffer written twice produces byte-identical files
///   (determinism, docs/archive/stage-1/04-stage-1-plan.md M1).
final class WriterBufferTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestFixtures.makeTemporaryDirectory(function: "writer-buffer")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    /// 4×3 RGBAf: authored HDR values including the M0 4.0-linear peak, a 100× extreme, and
    /// negative / just-below-zero samples. Alpha is exactly 1 in every pixel.
    private static let pixels: [Float] = [
        0.5, 1.5, 2.5, 1,
        2.5, 0.5, 1.5, 1,
        1.5, 2.5, 0.5, 1,
        4.0, 0.0, 1.0, 1,
        -0.25, -1.0, -0.0001, 1,
        0.0, -2.5, 0.25, 1,
        1.000001, 0.999999, 0.0, 1,
        -0.5, 1.0, -1.5, 1,
        0.5, -0.5, 1.5, 1,
        -3.5, 2.5, 0.125, 1,
        0.75, 0.25, -0.75, 1,
        100.0, -100.0, 1.0, 1,
    ]

    private func makeHDRImage() throws -> LinearImage {
        try LinearImage(size: PixelSize(width: 4, height: 3), pixels: Self.pixels)
    }

    /// The image is RGBAf (32-bit float, 4 samples), tagged "Display P3 Linear", and every sample
    /// — including the negative and >1 ones — reads back within 1e-6 with no NaN.
    func testHDRFloatTIFFRoundTripsOutOfRangeSamplesExactly() throws {
        let url = directory.appendingPathComponent("hdr.tif")
        try TIFFWriter.writeHDR(try makeHDRImage(), to: url)

        // Layout: 32-bit float, RGBA (4 samples), extended linear Display P3 ICC.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 32)
        XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "Display P3 Linear")
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(cgImage.bitsPerComponent, 32)
        XCTAssertEqual(cgImage.bitsPerPixel / cgImage.bitsPerComponent, 4, "HDR TIFF must be RGBAf")
        XCTAssertEqual(cgImage.width, 4)
        XCTAssertEqual(cgImage.height, 3)

        // Pixel read-back through ImageIO/Core Image in the linear extended P3 working space.
        let readBack = try renderLinearPixels(of: url)
        XCTAssertEqual(readBack.count, Self.pixels.count)
        XCTAssertFalse(readBack.contains { $0.isNaN }, "the float round trip produced NaN")
        var worstError: Float = 0
        for index in 0..<Self.pixels.count {
            worstError = max(worstError, abs(readBack[index] - Self.pixels[index]))
        }
        XCTAssertLessThanOrEqual(worstError, 1e-6, "a float sample changed through the TIFF round trip")
        for index in 0..<Self.pixels.count {
            XCTAssertEqual(readBack[index], Self.pixels[index], accuracy: 1e-6, "HDR sample \(index)")
        }

        // The properties the encoder depends on, called out explicitly.
        XCTAssertEqual(readBack[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(readBack[1], 1.5, accuracy: 1e-6)
        XCTAssertEqual(readBack[2], 2.5, accuracy: 1e-6)
        XCTAssertEqual(readBack[3 * 4 + 0], 4.0, accuracy: 1e-6, "the 4.0-linear peak must not clip")
        XCTAssertEqual(readBack[11 * 4 + 0], 100.0, accuracy: 1e-6, "the 100× extreme must not clip")
        XCTAssertEqual(readBack[4 * 4 + 0], -0.25, accuracy: 1e-6, "negative samples must not be clamped")
        XCTAssertEqual(readBack[11 * 4 + 1], -100.0, accuracy: 1e-6)
        for pixel in 0..<(readBack.count / 4) {
            XCTAssertEqual(readBack[pixel * 4 + 3], 1.0, accuracy: 1e-6, "alpha stays opaque")
        }
    }

    /// Same input, two writes, identical bytes — including the new provider-backed CIImage route.
    func testHDRFloatTIFFWritesAreByteIdentical() throws {
        let image = try makeHDRImage()
        let first = directory.appendingPathComponent("hdr-a.tif")
        let second = directory.appendingPathComponent("hdr-b.tif")
        try TIFFWriter.writeHDR(image, to: first)
        try TIFFWriter.writeHDR(image, to: second)

        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertEqual(try TestFixtures.sha256(ofFileAt: first), try TestFixtures.sha256(ofFileAt: second))
        XCTAssertGreaterThan(try Data(contentsOf: first).count, 0)
    }

    // MARK: - Helpers

    /// Renders a written image back to linear extended Display P3 `RGBAf` samples.
    private func renderLinearPixels(of url: URL) throws -> [Float] {
        let linearP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .outputColorSpace: linearP3,
            .cacheIntermediates: false,
        ])
        let image = try XCTUnwrap(
            CIImage(contentsOf: url, options: [.expandToHDR: true]),
            "cannot read back \(url.path)"
        )
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixels = [Float](repeating: .nan, count: width * height * 4)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf,
            colorSpace: linearP3
        )
        return pixels
    }
}
