import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// Review P1-11: `TIFFWriter.writeSDRBase` and `PNGWriter.writeSDRBase` used to assemble the same
/// 16-bit Display P3 `CGImage` twice. Both now call `SDRBaseCGImage.make(from:)`; these tests are
/// the cross-path contract that keeps them from drifting apart again:
///
/// - the same generated base (gradient, one >1 sample, one negative sample) written as `sdr.tif`
///   and `base.png` decodes to the same 16-bit samples (2e-4 tolerance ≈ one 16-bit step in linear
///   light) in linear extended Display P3;
/// - both files are 16 bpc RGB, no alpha, ICC Display P3;
/// - the samples equal the `SDRQuantiser` encoding of the input (out-of-range values clamped).
///
/// No `samples/` and no encoder executable are involved.
final class SDRBaseWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestFixtures.makeTemporaryDirectory(function: "sdr-base-writer")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    /// A 32×8 base with a 0.02 → 0.98 gradient (the Capture One export range the fixture uses),
    /// plus one sample above 1.0 and one below 0.0 to pin the clamping semantics on both paths.
    private func makeSDRBase() throws -> LinearImage {
        let size = PixelSize(width: 32, height: 8)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = Float(x) / Float(size.width - 1)
                let value = 0.02 + (0.98 - 0.02) * t
                let index = (y * size.width + x) * 4
                // Uneven channels so a channel-swap regression cannot pass.
                pixels[index] = value
                pixels[index + 1] = 0.1 + 0.5 * value
                pixels[index + 2] = 0.25 + 0.5 * t
                pixels[index + 3] = 1
            }
        }
        pixels[(0 * size.width + 0) * 4] = 1.5 // > 1: clamped to white by 16-bit P3
        pixels[(0 * size.width + 0) * 4 + 1] = 1.5
        pixels[(0 * size.width + 0) * 4 + 2] = 1.5
        pixels[(0 * size.width + 1) * 4] = -0.25 // < 0: clamped to black by 16-bit P3
        pixels[(0 * size.width + 1) * 4 + 1] = -0.25
        pixels[(0 * size.width + 1) * 4 + 2] = -0.25
        return try LinearImage(size: size, pixels: pixels)
    }

    func testTIFFAndPNGBasePathsArePixelEquivalent() throws {
        let image = try makeSDRBase()
        let tiffURL = directory.appendingPathComponent("sdr.tif")
        let pngURL = directory.appendingPathComponent("base.png")
        try TIFFWriter.writeSDRBase(image, to: tiffURL)
        try PNGWriter.writeSDRBase(image, to: pngURL)

        // Both files: 16 bpc RGB (48 bpp), no alpha, Display P3 ICC, source dimensions.
        for url in [tiffURL, pngURL] {
            let layout = try layout(of: url)
            XCTAssertEqual(layout.width, image.size.width, "\(url.lastPathComponent) width")
            XCTAssertEqual(layout.height, image.size.height, "\(url.lastPathComponent) height")
            XCTAssertEqual(layout.bitsPerComponent, 16, "\(url.lastPathComponent) bit depth")
            XCTAssertEqual(layout.bitsPerPixel, 48, "\(url.lastPathComponent) bits per pixel")
            XCTAssertEqual(layout.samplesPerPixel, 3, "\(url.lastPathComponent) sample count")
            XCTAssertFalse(layout.hasAlpha, "\(url.lastPathComponent) must not carry alpha")
            XCTAssertEqual(layout.profileName, "Display P3", "\(url.lastPathComponent) ICC profile")
        }

        // Render both back to linear extended Display P3 RGBAf and compare sample by sample.
        let tiffLinear = try renderLinearPixels(of: tiffURL, size: image.size)
        let pngLinear = try renderLinearPixels(of: pngURL, size: image.size)
        XCTAssertEqual(tiffLinear.count, image.pixels.count)
        XCTAssertEqual(pngLinear.count, image.pixels.count)

        var worstCrossPathDelta: Float = 0
        for index in 0..<image.pixels.count where index % 4 != 3 {
            worstCrossPathDelta = max(worstCrossPathDelta, abs(tiffLinear[index] - pngLinear[index]))
        }
        XCTAssertLessThanOrEqual(
            worstCrossPathDelta,
            2e-4,
            "the M1 TIFF base and the M2.1 PNG base must be the same pixels (16-bit quantisation level)"
        )

        // Content: each read-back sample is the 16-bit quantisation of the input, clamped to 0…1.
        // This is what makes the equivalence meaningful (both paths wrong in the same way would
        // still pass the delta above).
        for index in 0..<image.pixels.count where index % 4 != 3 {
            let expected = expectedLinear(image.pixels[index])
            XCTAssertEqual(
                Double(tiffLinear[index]),
                expected,
                accuracy: 2e-4,
                "sdr.tif sample \(index): quantised value of \(image.pixels[index])"
            )
            XCTAssertEqual(
                Double(pngLinear[index]),
                expected,
                accuracy: 2e-4,
                "base.png sample \(index): quantised value of \(image.pixels[index])"
            )
        }

        // Clamping boundary samples explicitly (the >1 / negative ones written above).
        XCTAssertEqual(Double(tiffLinear[0]), 1.0, accuracy: 2e-4, ">1 sample clamps to white")
        XCTAssertEqual(Double(pngLinear[0]), 1.0, accuracy: 2e-4, ">1 sample clamps to white")
        XCTAssertEqual(Double(tiffLinear[4]), 0.0, accuracy: 2e-4, "negative sample clamps to black")
        XCTAssertEqual(Double(pngLinear[4]), 0.0, accuracy: 2e-4, "negative sample clamps to black")

        // Alpha is dropped by the 16-bit base, so the decode is opaque.
        for index in stride(from: 3, to: tiffLinear.count, by: 4) {
            XCTAssertEqual(tiffLinear[index], 1.0, accuracy: 2e-4)
            XCTAssertEqual(pngLinear[index], 1.0, accuracy: 2e-4)
        }
    }

    // MARK: - Helpers

    private struct Layout {
        let width: Int
        let height: Int
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let samplesPerPixel: Int
        let hasAlpha: Bool
        let profileName: String?
    }

    private func layout(of url: URL) throws -> Layout {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst:
            hasAlpha = false
        default:
            hasAlpha = true
        }
        return Layout(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel,
            samplesPerPixel: image.bitsPerPixel / image.bitsPerComponent,
            hasAlpha: hasAlpha,
            profileName: properties[kCGImagePropertyProfileName] as? String
        )
    }

    /// The linear value a 16-bit Display P3 sample must decode to, after the same clamp and
    /// transfer function `SDRQuantiser` applies.
    private func expectedLinear(_ input: Float) -> Double {
        let encoded = SDRQuantiser.encoded16(input)
        let displayReferenced = Double(encoded) / 65535.0
        if displayReferenced <= 0.04045 {
            return displayReferenced / 12.92
        }
        return pow((displayReferenced + 0.055) / 1.055, 2.4)
    }

    /// Renders a written 16-bit base back into linear extended Display P3 RGBAf samples through
    /// ImageIO + Core Image (the same read-back route the M2.1 preview uses).
    private func renderLinearPixels(of url: URL, size: PixelSize) throws -> [Float] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let linearP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .outputColorSpace: linearP3,
            .cacheIntermediates: false,
        ])
        var pixels = [Float](repeating: .nan, count: size.pixelCount * 4)
        context.render(
            CIImage(cgImage: cgImage),
            toBitmap: &pixels,
            rowBytes: size.width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
            format: .RGBAf,
            colorSpace: linearP3
        )
        return pixels
    }
}
