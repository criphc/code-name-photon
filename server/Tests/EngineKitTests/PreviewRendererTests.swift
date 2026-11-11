import XCTest
@testable import EngineKit

/// Tests for the preview pair builder — in particular the Core Image buffer lifetime contract
/// and the Lanczos boundary contract.
///
/// The lifetime bug that motivated this file: a `CIImage` created over a local `Data` buffer
/// through Core Image's bitmap-data initializer can read freed heap memory on a later render.
/// The ownership chain is now pinned by `WriterBufferTests`; the old in-process heap-churn test
/// was removed because this macOS release retains the small buffer, so it could not fail.
///
/// The boundary bug (review P1-2): the Lanczos filter sampled past the image extent as transparent
/// black, so downscaling a uniform 0.5 image returned 0.4402 at the first-row corner and 0.5104 on
/// the second row. The tests below assert every pixel, including all four edges and corners.
final class PreviewRendererTests: XCTestCase {
    private let cap: Float = 2.5

    // MARK: - Fixtures

    private func makeImage(
        width: Int,
        height: Int,
        _ value: (Int, Int) -> RGBA
    ) throws -> LinearImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = value(x, y)
                let index = (y * width + x) * 4
                pixels[index] = pixel.r
                pixels[index + 1] = pixel.g
                pixels[index + 2] = pixel.b
                pixels[index + 3] = pixel.a
            }
        }
        return try LinearImage(size: PixelSize(width: width, height: height), pixels: pixels)
    }

    /// Native-size render through the same Core Image path `downscale` uses.
    private func renderNative(_ image: LinearImage) throws -> LinearImage {
        let ciImage = try PreviewRenderer.ciImage(image)
        return try PreviewRenderer.render(
            ciImage,
            size: image.size,
            context: PreviewRenderer.makeContext()
        )
    }

    private func assertSample(
        _ rendered: LinearImage,
        equals expected: [Float],
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rendered.pixels.count, expected.count, file: file, line: line)
        for index in 0..<min(rendered.pixels.count, expected.count) {
            XCTAssertEqual(rendered.pixels[index], expected[index], accuracy: accuracy,
                           "sample \(index)", file: file, line: line)
        }
    }

    // MARK: - a. Identity render

    func testCIImageRenderAtNativeSizeMatchesSourcePixels() throws {
        let size = PixelSize(width: 8, height: 6)
        var expected = [Float](repeating: 0, count: size.pixelCount * 4)
        for index in 0..<size.pixelCount {
            let x = Float(index % size.width) / 7
            let y = Float(index / size.width) / 5
            let offset = index * 4
            // Uneven values, including authored HDR range above 1.0; alpha exactly 1.
            expected[offset] = 0.05 + 1.8 * x
            expected[offset + 1] = 0.2 + 0.6 * y
            expected[offset + 2] = 1.4 - 1.2 * x
            expected[offset + 3] = 1
        }
        let image = try LinearImage(size: size, pixels: expected)
        let rendered = try renderNative(image)
        assertSample(rendered, equals: expected, accuracy: 1e-6)
        XCTAssertTrue(rendered.isOpaque)
    }

    // MARK: - b. Lifetime regression

    // The CIImage ownership chain is pinned by WriterBufferTests; no per-process heap-churn guard.

    // MARK: - c. Downscale determinism

    func testDownscaleIsBitIdenticalAcrossCalls() throws {
        let size = PixelSize(width: 200, height: 100)
        let base = try makeImage(width: size.width, height: size.height) { x, y in
            RGBA(
                r: 0.05 + 0.9 * Float(x) / 199,
                g: 0.1 + 0.5 * Float(y) / 99,
                b: 0.2 + 0.7 * Float(x) / 199,
                a: 1
            )
        }
        let hdr = try makeImage(width: size.width, height: size.height) { x, y in
            let lift: Float = x > 120 ? 2.4 : 0.9
            return RGBA(r: lift, g: lift * 0.75, b: lift * 0.5, a: 1)
        }

        let first = try PreviewRenderer.downscale(base: base, hdr: hdr, longEdge: 80, headroomCap: cap)
        let second = try PreviewRenderer.downscale(base: base, hdr: hdr, longEdge: 80, headroomCap: cap)
        XCTAssertEqual(first.size, PixelSize(width: 80, height: 40))
        XCTAssertEqual(first.base.size, second.base.size)
        XCTAssertEqual(first.base.pixels, second.base.pixels, "base preview is not deterministic")
        XCTAssertEqual(first.hdr.pixels, second.hdr.pixels, "HDR preview is not deterministic")
    }

    // MARK: - d. Downscale correctness

    /// Review P1-2: before `lanczos` clamped the source extent, the filter sampled past the edge as
    /// transparent black. A uniform 0.5 image measurably came back 0.4402 at the first-row corner,
    /// 0.4693 in the "interior" (row 0), 0.5104 on row 1 and 0.5000 only at the centre; the
    /// `margin = 8` this test used to have was hiding exactly that. Every pixel — all four edges
    /// and all four corners included — must now be the constant.
    func testDownscaleOfUniformValueStaysUniformBelowCap() throws {
        let size = PixelSize(width: 200, height: 100)
        let base = try makeImage(width: size.width, height: size.height) { _, _ in
            RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)
        }
        let pair = try PreviewRenderer.downscale(base: base, hdr: base, longEdge: 80, headroomCap: cap)
        XCTAssertEqual(pair.size, PixelSize(width: 80, height: 40))
        XCTAssertEqual(pair.base.size, pair.hdr.size)
        XCTAssertLessThanOrEqual(pair.hdr.maxChannel, cap)
        XCTAssertTrue(pair.base.isOpaque)
        XCTAssertTrue(pair.hdr.isOpaque)

        // No margin: the constant must survive the resample untouched everywhere, borders included.
        for y in 0..<pair.size.height {
            for x in 0..<pair.size.width {
                let basePixel = pair.base.pixel(x: x, y: y)
                let hdrPixel = pair.hdr.pixel(x: x, y: y)
                XCTAssertEqual(Double(basePixel.r), 0.5, accuracy: 1e-5, "base (\(x),\(y))")
                XCTAssertEqual(Double(basePixel.g), 0.5, accuracy: 1e-5, "base (\(x),\(y))")
                XCTAssertEqual(Double(basePixel.b), 0.5, accuracy: 1e-5, "base (\(x),\(y))")
                XCTAssertEqual(Double(hdrPixel.r), 0.5, accuracy: 1e-5, "hdr (\(x),\(y))")
                XCTAssertEqual(Double(hdrPixel.g), 0.5, accuracy: 1e-5, "hdr (\(x),\(y))")
                XCTAssertEqual(Double(hdrPixel.b), 0.5, accuracy: 1e-5, "hdr (\(x),\(y))")
            }
        }
    }

    /// Review P1-2 boundary regression on a non-constant image: the frame edge must not be pushed
    /// toward transparent black. The step sits in the middle of the 200 px source and Lanczos'
    /// support is a few *output* pixels, so the first/last 10 of 80 output columns are pure
    /// constant regions: with the source extent clamped they must match the interior of their own
    /// region exactly, while the old transparent-black sampling darkened the first/last row and
    /// column by up to ~0.08. Normal Lanczos ringing around the step itself is allowed.
    ///
    /// The comparisons are edge-vs-interior rather than edge-vs-literal: Core Image's working format
    /// is half float, so a 0.75 constant lands at 0.74951 (1 ULP, 2⁻¹¹) even in the interior.
    func testDownscaleOfAStepDoesNotDarkenTheFrameEdges() throws {
        let size = PixelSize(width: 200, height: 100)
        let left: Float = 0.25
        let right: Float = 0.75
        let base = try makeImage(width: size.width, height: size.height) { x, _ in
            let value = x < size.width / 2 ? left : right
            return RGBA(r: value, g: value, b: value, a: 1)
        }
        let pair = try PreviewRenderer.downscale(base: base, hdr: base, longEdge: 80, headroomCap: cap)
        XCTAssertEqual(pair.size, PixelSize(width: 80, height: 40))

        // Reference columns well inside each constant region, away from the central step.
        let leftReference = pair.base.pixel(x: 8, y: pair.size.height / 2)
        let rightReference = pair.base.pixel(x: pair.size.width - 8, y: pair.size.height / 2)
        XCTAssertEqual(Double(leftReference.r), Double(left), accuracy: 1e-3, "left constant region")
        XCTAssertEqual(Double(rightReference.r), Double(right), accuracy: 1e-3, "right constant region")

        for y in 0..<pair.size.height {
            for x in 0..<10 {
                assertEdgeSampleMatches(pair.base.pixel(x: x, y: y), reference: leftReference, "(\(x),\(y)) left edge")
            }
            for x in (pair.size.width - 10)..<pair.size.width {
                assertEdgeSampleMatches(pair.base.pixel(x: x, y: y), reference: rightReference, "(\(x),\(y)) right edge")
            }
        }

        // The step is vertical only, so every row must be identical: top and bottom rows prove the
        // vertical boundary is not darkened even where the frame carries structure elsewhere.
        for x in 0..<pair.size.width {
            let middle = pair.base.pixel(x: x, y: pair.size.height / 2)
            assertEdgeSampleMatches(pair.base.pixel(x: x, y: 0), reference: middle, "top row x=\(x)")
            assertEdgeSampleMatches(
                pair.base.pixel(x: x, y: pair.size.height - 1),
                reference: middle,
                "bottom row x=\(x)"
            )
        }

        // Ringing is allowed around the step and at the boundary, but a whole-frame darkening
        // (transparent-black contamination) is not: values must stay within the normal overshoot
        // band of the two source levels.
        var minimum: Float = .infinity
        var maximum: Float = -.infinity
        for index in stride(from: 0, to: pair.base.pixels.count, by: 4) {
            let value = pair.base.pixels[index]
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        XCTAssertGreaterThanOrEqual(Double(minimum), Double(left) - 0.1, "edge/step undershoot beyond normal ringing")
        XCTAssertLessThanOrEqual(Double(maximum), Double(right) + 0.1, "edge/step overshoot beyond normal ringing")
    }

    /// An edge sample must equal the interior of its own constant region. 1e-3 is the Core Image
    /// half-float working precision (2⁻¹¹); the old transparent-black sampling was off by ~0.08.
    private func assertEdgeSampleMatches(
        _ pixel: RGBA,
        reference: RGBA,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Double(pixel.r), Double(reference.r), accuracy: 1e-3, label, file: file, line: line)
        XCTAssertEqual(Double(pixel.g), Double(reference.g), accuracy: 1e-3, label, file: file, line: line)
        XCTAssertEqual(Double(pixel.b), Double(reference.b), accuracy: 1e-3, label, file: file, line: line)
    }

    // MARK: - e. HDR clamp after resampling

    func testHDRClampAppliesAfterLanczosResample() throws {
        let size = PixelSize(width: 64, height: 64)
        let base = try makeImage(width: size.width, height: size.height) { _, _ in
            RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1)
        }
        // A block far above the cap: Lanczos spreads it (and rings), the preview must clamp.
        let hdr = try makeImage(width: size.width, height: size.height) { x, y in
            let insideBlock = (24..<40).contains(x) && (24..<40).contains(y)
            let value: Float = insideBlock ? 10 : 0.1
            return RGBA(r: value, g: value, b: value, a: 1)
        }
        let lowerCap: Float = 2.0
        let pair = try PreviewRenderer.downscale(base: base, hdr: hdr, longEdge: 32, headroomCap: lowerCap)
        XCTAssertEqual(pair.size, PixelSize(width: 32, height: 32))
        XCTAssertLessThanOrEqual(pair.hdr.maxChannel, lowerCap, "resampled HDR must not exceed the cap")
        XCTAssertEqual(pair.hdr.maxChannel, lowerCap, accuracy: 1e-6, "the >cap impulse must be clamped, not lost")
        XCTAssertGreaterThan(pair.hdr.maxChannel, 1.0)
    }
}
