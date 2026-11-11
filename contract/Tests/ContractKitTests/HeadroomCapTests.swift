import Foundation
import XCTest
@testable import ContractKit

/// The headroom clamp is the *only* control of delivered headroom (M0 measured it; the archive's
/// docs/archive/stage-1/05-encoder-verification.md §2/§6): `-R` is inert with `-b`, so the HDR
/// rendition pixels themselves must be clamped. These
/// tests cover `HeadroomCap.clamp` and the end-to-end `HDRRendition.render` behaviour on
/// uniform and mixed SDR bases — pure maths, no samples/, no encoder.
final class HeadroomCapTests: XCTestCase {
    private let cap: Float = 2.5

    private func makeImage(_ pixels: [RGBA]) throws -> LinearImage {
        try LinearImage(
            size: PixelSize(width: pixels.count, height: 1),
            pixels: pixels.flatMap { [$0.r, $0.g, $0.b, $0.a] }
        )
    }

    private func makeShape(
        start: Float = 0.62,
        liftStops: Float = 1.4,
        transition: Float = 0.28,
        headroomCap: Float = 2.5
    ) -> HighlightShape {
        try! HighlightShape(start: start, liftStops: liftStops, transition: transition, headroomCap: headroomCap)
    }

    private func assertInvalidRecipe(_ body: @autoclosure () throws -> LinearImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case let PhotonError.invalidRecipe(field, _)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(field, "hdr.headroom_cap", file: file, line: line)
        }
    }

    private func assertInvalidImage(_ body: @autoclosure () throws -> LinearImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case PhotonError.invalidImage? = error as? PhotonError else {
                return XCTFail("expected invalidImage, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - HeadroomCap.clamp

    func testClampsHugeSamplesExactlyToCap() throws {
        let image = try makeImage([
            RGBA(r: 10, g: 5, b: 3, a: 1),
            RGBA(r: 2.5, g: 2.5, b: 2.5, a: 1),
            RGBA(r: 2.6, g: 1, b: 0.1, a: 1),
        ])
        let clamped = try HeadroomCap.clamp(image, cap: cap)
        XCTAssertEqual(clamped.pixels, [2.5, 2.5, 2.5, 1, 2.5, 2.5, 2.5, 1, 2.5, 1, 0.1, 1])
        XCTAssertEqual(clamped.size, image.size)
    }

    func testPreservesValuesAtOrBelowCapExactly() throws {
        let values: [Float] = [0, 0.001, 0.5, 1.0, 1.0001, 1.5, 2.4999998, 2.5, -0.5]
        let image = try makeImage(values.map { RGBA(r: $0, g: $0, b: $0, a: 1) })
        let clamped = try HeadroomCap.clamp(image, cap: cap)
        XCTAssertEqual(clamped.pixels, image.pixels, "values <= cap must be bit-exact")
    }

    func testCapOfOneIsAllowed() throws {
        let image = try makeImage([RGBA(r: 0.25, g: 1.0, b: 2.0, a: 1)])
        let clamped = try HeadroomCap.clamp(image, cap: 1)
        XCTAssertEqual(clamped.pixels, [0.25, 1, 1, 1])
    }

    func testClampIsIdempotent() throws {
        // Deterministic mixed content spanning below / at / above the cap.
        let values = (0..<200).map { index -> Float in Float(index % 97) / 20 - 0.5 }
        let image = try makeImage(values.map { RGBA(r: $0, g: $0 + 0.25, b: $0 + 1.5, a: 0.5) })
        let once = try HeadroomCap.clamp(image, cap: cap)
        let twice = try HeadroomCap.clamp(once, cap: cap)
        XCTAssertEqual(once.pixels, twice.pixels, "clamp must be idempotent")
        for index in stride(from: 0, to: twice.pixels.count, by: 4) {
            XCTAssertLessThanOrEqual(twice.pixels[index], cap)
            XCTAssertLessThanOrEqual(twice.pixels[index + 1], cap)
            XCTAssertLessThanOrEqual(twice.pixels[index + 2], cap)
            XCTAssertEqual(twice.pixels[index + 3], 0.5, "alpha must be copied untouched")
        }
    }

    func testAlphaIsNeverTouched() throws {
        let image = try makeImage([
            RGBA(r: 10, g: 10, b: 10, a: 0.25),
            RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0),
            RGBA(r: 3, g: 1, b: 0.5, a: 1.5),
        ])
        let clamped = try HeadroomCap.clamp(image, cap: cap)
        XCTAssertEqual([clamped.pixels[3], clamped.pixels[7], clamped.pixels[11]], [0.25, 0, 1.5])
        XCTAssertEqual([clamped.pixels[0], clamped.pixels[1], clamped.pixels[2]], [2.5, 2.5, 2.5])
    }

    func testClampRejectsCapBelowOneAndNonFiniteCaps() throws {
        let image = try makeImage([RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)])
        assertInvalidRecipe(try HeadroomCap.clamp(image, cap: 0.999))
        assertInvalidRecipe(try HeadroomCap.clamp(image, cap: -1))
        assertInvalidRecipe(try HeadroomCap.clamp(image, cap: .nan))
        assertInvalidRecipe(try HeadroomCap.clamp(image, cap: .infinity))
    }

    func testClampRejectsNonFiniteSamples() throws {
        let nanRed = try makeImage([RGBA(r: .nan, g: 0.5, b: 0.5, a: 1)])
        let infGreen = try makeImage([RGBA(r: 0.5, g: .infinity, b: 0.5, a: 1)])
        let nanAlpha = try makeImage([RGBA(r: 0.5, g: 0.5, b: 0.5, a: .nan)])
        assertInvalidImage(try HeadroomCap.clamp(nanRed, cap: cap))
        assertInvalidImage(try HeadroomCap.clamp(infGreen, cap: cap))
        assertInvalidImage(try HeadroomCap.clamp(nanAlpha, cap: cap))
    }

    func testClampDoesNotMutateTheInputImage() throws {
        let image = try makeImage([RGBA(r: 10, g: 0.5, b: 0.25, a: 1)])
        let before = image.pixels
        _ = try HeadroomCap.clamp(image, cap: cap)
        XCTAssertEqual(image.pixels, before, "LinearImage is a value type; clamp must return a new buffer")
    }

    // MARK: - HDRRendition.render

    func testMaskZeroPassesBaseThroughExactly() throws {
        // start 0.62 ⇒ a 0.5 base has mask 0, so the HDR rendition must equal the base bit-exactly.
        let base = LinearImage(size: PixelSize(width: 5, height: 2), repeating: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.75))
        let result = try HDRRendition.render(base: base, shape: makeShape())
        XCTAssertEqual(result.image.pixels, base.pixels, "mask 0 ⇒ no channel may change")
        XCTAssertEqual(result.authoredPeak, 0.5)
        XCTAssertEqual(result.fractionAboveOne, 0)
        XCTAssertEqual(result.fractionAtCap, 0)
        XCTAssertEqual(result.image.size, base.size)
    }

    /// The acceptance number the task board asked for: uniform 0.9 linear base, default recipe
    /// (start 0.62, lift 1.4, transition 0.28, cap 2.5).
    ///
    /// Measured: `luma(0.9) == Float(0.9) == start + transition` exactly (the default roll-off top
    /// *is* 0.9 in Float32), so the mask is exactly 1, the gain is exactly `2^1.4 = 2.6390157`, and
    /// the peak is `0.9 × 2.6390157 = 2.375114` — **below** the 2.5 cap. The cap does not engage
    /// until base ≈ 0.9473 (2.5 / 2.6390157). Every pixel is above SDR white, none is at the cap.
    func testUniformPointNineLumaWithDefaultRecipe() throws {
        let base = LinearImage(size: PixelSize(width: 3, height: 2), repeating: RGBA(r: 0.9, g: 0.9, b: 0.9, a: 1))
        let shape = makeShape()
        XCTAssertEqual(shape.mask(luma: RGBA(r: 0.9, g: 0.9, b: 0.9).rec709Luma), 1, "default top == 0.9 exactly")

        let result = try HDRRendition.render(base: base, shape: shape)
        let expectedGain: Float = exp2(1.4)
        let expectedValue = 0.9 * expectedGain

        XCTAssertEqual(result.authoredPeak, 2.375114, accuracy: 1e-4)
        XCTAssertEqual(result.authoredPeak, expectedValue, accuracy: 1e-6)
        XCTAssertLessThan(result.authoredPeak, 2.5 - 1e-3, "0.9 × 2^1.4 is below the 2.5 cap")
        for index in stride(from: 0, to: result.image.pixels.count, by: 4) {
            XCTAssertEqual(result.image.pixels[index], expectedValue, accuracy: 1e-6)
            XCTAssertEqual(result.image.pixels[index + 1], expectedValue, accuracy: 1e-6)
            XCTAssertEqual(result.image.pixels[index + 2], expectedValue, accuracy: 1e-6)
        }
        XCTAssertEqual(result.fractionAboveOne, 1.0, "every pixel is above SDR white")
        XCTAssertEqual(result.fractionAtCap, 0.0, "no pixel reached the cap")
        XCTAssertTrue(result.image.isFinite)
    }

    func testUniformPointNineFiveBaseIsClampedToCap() throws {
        // 0.95 × 2.6390157 = 2.5070 > 2.5 ⇒ the absolute clamp engages on every pixel.
        let base = LinearImage(size: PixelSize(width: 4, height: 1), repeating: RGBA(r: 0.95, g: 0.95, b: 0.95, a: 1))
        let result = try HDRRendition.render(base: base, shape: makeShape())
        XCTAssertEqual(result.authoredPeak, 2.5)
        for index in stride(from: 0, to: result.image.pixels.count, by: 4) {
            XCTAssertEqual(result.image.pixels[index], 2.5)
            XCTAssertEqual(result.image.pixels[index + 1], 2.5)
            XCTAssertEqual(result.image.pixels[index + 2], 2.5)
            XCTAssertEqual(result.image.pixels[index + 3], 1)
        }
        XCTAssertEqual(result.fractionAboveOne, 1.0)
        XCTAssertEqual(result.fractionAtCap, 1.0)
    }

    func testMixedImageFractionCounts() throws {
        // Grey pixels: 0.5 (mask 0), 1.0 (clamped), 0.6 (mask 0), 0.95 (clamped).
        let values: [Float] = [0.5, 1.0, 0.6, 0.95]
        let base = try makeImage(values.map { RGBA(r: $0, g: $0, b: $0, a: 1) })
        let result = try HDRRendition.render(base: base, shape: makeShape())
        XCTAssertEqual(result.authoredPeak, 2.5)
        XCTAssertEqual(result.fractionAboveOne, 0.5, "2 of 4 pixels are above 1.0")
        XCTAssertEqual(result.fractionAtCap, 0.5, "2 of 4 pixels sit exactly at the cap")
        XCTAssertEqual(result.image.pixels[0], 0.5)
        XCTAssertEqual(result.image.pixels[4], 2.5)
        XCTAssertEqual(result.image.pixels[8], 0.6)
        XCTAssertEqual(result.image.pixels[12], 2.5)
    }

    func testRenditionCopiesAlphaAndKeepsOneGainForAllChannels() throws {
        let base = try makeImage([
            RGBA(r: 0.5, g: 0.4, b: 0.3, a: 0.25),
            RGBA(r: 0.7, g: 0.8, b: 0.6, a: 0),
        ])
        let shape = makeShape(headroomCap: 4)
        let result = try HDRRendition.render(base: base, shape: shape)
        XCTAssertEqual(result.image.pixels[3], 0.25)
        XCTAssertEqual(result.image.pixels[7], 0)
        let k = result.image.pixels
        for pixel in 0..<2 {
            let offset = pixel * 4
            let r = k[offset]
            let g = k[offset + 1]
            let b = k[offset + 2]
            // One luma, therefore one gain: hdr.r/base.r == hdr.g/base.g == hdr.b/base.b.
            let scaleR = r / base.pixels[offset]
            let scaleG = g / base.pixels[offset + 1]
            let scaleB = b / base.pixels[offset + 2]
            XCTAssertEqual(scaleR, scaleG, accuracy: 1e-6)
            XCTAssertEqual(scaleG, scaleB, accuracy: 1e-6)
        }
    }

    func testRenditionMatchesHighlightShapeMathsOnARamp() throws {
        // The renderer inlines the mask/gain maths; it must not drift from HighlightShape.
        let shape = makeShape(headroomCap: 4)
        let values = (0..<101).map { Float($0) / 100 }
        let base = try makeImage(values.map { RGBA(r: $0, g: $0, b: $0, a: 1) })
        let result = try HDRRendition.render(base: base, shape: shape)
        for (index, value) in values.enumerated() {
            let luma = RGBA(r: value, g: value, b: value).rec709Luma
            let expected = value * shape.gain(luma: luma)
            for channel in 0..<3 {
                XCTAssertEqual(result.image.pixels[index * 4 + channel], expected, accuracy: 1e-6)
            }
        }
    }

    func testRenditionRejectsNonFiniteBase() throws {
        let nanBase = try makeImage([RGBA(r: .nan, g: 0.5, b: 0.5, a: 1)])
        let infBase = try makeImage([RGBA(r: 0.5, g: .infinity, b: 0.5, a: 1)])
        let shape = makeShape()
        XCTAssertThrowsError(try HDRRendition.render(base: nanBase, shape: shape)) { error in
            guard case PhotonError.invalidImage? = error as? PhotonError else {
                return XCTFail("expected invalidImage, got \(error)")
            }
        }
        XCTAssertThrowsError(try HDRRendition.render(base: infBase, shape: shape)) { error in
            guard case PhotonError.invalidImage? = error as? PhotonError else {
                return XCTFail("expected invalidImage, got \(error)")
            }
        }
    }

    func testRenderedBufferNeverExceedsCap() throws {
        let values = (0..<64).map { Float($0) / 21 - 0.5 } // spans negatives to ~2.5
        let base = try makeImage(values.map { RGBA(r: $0, g: $0 * 2, b: $0 * 3, a: 1) })
        let shape = makeShape(liftStops: 4) // hardest possible lift
        let result = try HDRRendition.render(base: base, shape: shape)
        for sample in result.image.pixels { XCTAssertLessThanOrEqual(sample, 2.5) }
        XCTAssertLessThanOrEqual(result.authoredPeak, 2.5)
        XCTAssertGreaterThanOrEqual(result.fractionAboveOne, 0)
        XCTAssertLessThanOrEqual(result.fractionAboveOne, 1)
        XCTAssertGreaterThanOrEqual(result.fractionAtCap, 0)
        XCTAssertLessThanOrEqual(result.fractionAtCap, 1)
    }
}
