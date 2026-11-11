import Foundation
import XCTest
@testable import ContractKit

/// The binding mask/gain maths (docs/reference/recipe.md, maths):
/// `m = smoothstep(start, start + transition, luma)`, `gain = 2^(lift_stops · m)`,
/// where `luma` is `RGBA.rec709Luma` of the linear base.
///
/// These tests are pure maths — no samples/, no Core Image, no encoder.
final class MaskMathTests: XCTestCase {
    private let start: Float = 0.62
    private let liftStops: Float = 1.4
    private let transition: Float = 0.28
    private let headroomCap: Float = 2.5

    private func makeShape(
        start: Float? = nil,
        liftStops: Float? = nil,
        transition: Float? = nil,
        headroomCap: Float? = nil
    ) -> HighlightShape {
        try! HighlightShape(
            start: start ?? self.start,
            liftStops: liftStops ?? self.liftStops,
            transition: transition ?? self.transition,
            headroomCap: headroomCap ?? self.headroomCap
        )
    }

    private var top: Float { start + transition }

    private func assertInvalid(
        field: String,
        start: Float = 0.62,
        liftStops: Float = 1.4,
        transition: Float = 0.28,
        headroomCap: Float = 2.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try HighlightShape(start: start, liftStops: liftStops, transition: transition, headroomCap: headroomCap),
            file: file,
            line: line
        ) { error in
            guard case let PhotonError.invalidRecipe(name, _)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(name, field, file: file, line: line)
        }
    }

    // MARK: - Construction / validation

    func testAcceptsDocumentedBoundaryValues() {
        XCTAssertNoThrow(try HighlightShape(start: 0, liftStops: 0, transition: 0.001, headroomCap: 1))
        XCTAssertNoThrow(try HighlightShape(start: 1, liftStops: 4, transition: 1, headroomCap: 8))
        XCTAssertNoThrow(try HighlightShape(start: 0.62, liftStops: 1.4, transition: 0.28, headroomCap: 2.5))
        // The convenience initializer from the documented default recipe yields the same shape.
        XCTAssertEqual(
            try! HighlightShape(recipe: Recipe.HDR()),
            makeShape(headroomCap: Float(Recipe.HDR.defaultHeadroomCap))
        )
    }

    func testRejectsOutOfRangeOrNonFiniteFields() {
        assertInvalid(field: "hdr.start", start: -0.001)
        assertInvalid(field: "hdr.start", start: 1.001)
        assertInvalid(field: "hdr.start", start: .nan)
        assertInvalid(field: "hdr.start", start: .infinity)
        assertInvalid(field: "hdr.lift_stops", liftStops: -0.001)
        assertInvalid(field: "hdr.lift_stops", liftStops: 4.001)
        assertInvalid(field: "hdr.lift_stops", liftStops: .nan)
        assertInvalid(field: "hdr.transition", transition: 0)
        assertInvalid(field: "hdr.transition", transition: 0.0009)
        assertInvalid(field: "hdr.transition", transition: 1.001)
        assertInvalid(field: "hdr.transition", transition: .nan)
        assertInvalid(field: "hdr.headroom_cap", headroomCap: 0.999)
        assertInvalid(field: "hdr.headroom_cap", headroomCap: 8.001)
        assertInvalid(field: "hdr.headroom_cap", headroomCap: .nan)
    }

    func testRecipeInitializerRejectsBadRecipeRanges() {
        XCTAssertThrowsError(try HighlightShape(recipe: Recipe.HDR(start: 1.5))) { error in
            guard case let PhotonError.invalidRecipe(field, _)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)")
            }
            XCTAssertEqual(field, "hdr.start")
        }
        XCTAssertThrowsError(try HighlightShape(recipe: Recipe.HDR(headroomCap: 0.5))) { error in
            guard case let PhotonError.invalidRecipe(field, _)? = error as? PhotonError else {
                return XCTFail("expected invalidRecipe, got \(error)")
            }
            XCTAssertEqual(field, "hdr.headroom_cap")
        }
    }

    // MARK: - Mask boundaries

    func testMaskIsZeroAtAndBelowStart() {
        let shape = makeShape()
        XCTAssertEqual(shape.mask(luma: 0), 0, "luma 0 is always outside the lift")
        XCTAssertEqual(shape.mask(luma: -1), 0)
        XCTAssertEqual(shape.mask(luma: -1e6), 0)
        XCTAssertEqual(shape.mask(luma: start - 0.001), 0)
        // Exactly on the threshold the smoothstep starts at 0 (the ramp is to the right).
        XCTAssertEqual(shape.mask(luma: start), 0)
    }

    func testMaskIsExactlyOneAtAndAboveTop() {
        let shape = makeShape()
        XCTAssertEqual(shape.mask(luma: top), 1)
        XCTAssertEqual(shape.mask(luma: top + 1e-4), 1)
        XCTAssertEqual(shape.mask(luma: 1), 1)
        XCTAssertEqual(shape.mask(luma: 2), 1)
        XCTAssertEqual(shape.mask(luma: 1e6), 1)
    }

    func testMaskMidpointIsHalf() {
        let shape = makeShape()
        let mid = start + transition / 2
        XCTAssertEqual(shape.mask(luma: mid), 0.5, accuracy: 1e-4)
        // Smoothstep is symmetric around its midpoint.
        let below = shape.mask(luma: mid - 0.05)
        let above = shape.mask(luma: mid + 0.05)
        XCTAssertEqual(below + above, 1, accuracy: 1e-4)
    }

    func testMaskIsTinyJustInsideStart() {
        let shape = makeShape()
        // Quadratic onset: mask ≈ 3·(Δ/transition)² for small Δ.
        let delta: Float = 1e-3
        let value = shape.mask(luma: start + delta)
        XCTAssertGreaterThan(value, 0)
        XCTAssertLessThan(value, 1e-4)
        let tiny = shape.mask(luma: start + 1e-5)
        XCTAssertLessThan(tiny, 1e-6)
    }

    // MARK: - Shape of the curve

    func testMaskIsMonotoneAndContinuous() {
        let shape = makeShape()
        var previous = shape.mask(luma: 0)
        let steps = 15000
        for index in 1...steps {
            let luma = Float(index) / Float(steps) * 1.5
            let value = shape.mask(luma: luma)
            XCTAssertGreaterThanOrEqual(value, previous, "mask must not decrease at luma \(luma)")
            XCTAssertLessThan(value - previous, 0.01, "mask has a jump at luma \(luma)")
            XCTAssertTrue(value.isFinite)
            previous = value
        }
    }

    func testMaskIsC1AtBothBoundaries() {
        // smoothstep meets 0 at `start` and 1 at `start+transition` with zero slope: the
        // one-sided finite difference must stay tiny, and it must shrink with the step.
        let shape = makeShape()
        let step: Float = 1e-5
        let slopeAtStart = (shape.mask(luma: start + step) - shape.mask(luma: start)) / step
        let slopeAtTop = (shape.mask(luma: top) - shape.mask(luma: top - step)) / step
        XCTAssertLessThan(abs(slopeAtStart), 1e-3, "mask must be C¹ at start (zero slope)")
        XCTAssertLessThan(abs(slopeAtTop), 1e-3, "mask must be C¹ at top (zero slope)")
        // Halving the step halves the finite difference (quadratic onset, not a kink).
        let coarseSlope = (shape.mask(luma: start + 1e-4) - shape.mask(luma: start)) / 1e-4
        XCTAssertLessThan(abs(coarseSlope), 1e-2)
        // The middle of the ramp has the steepest slope: 6·0.25/transition.
        let mid = start + transition / 2
        let h: Float = 1e-4
        let midSlope = (shape.mask(luma: mid + h) - shape.mask(luma: mid - h)) / (2 * h)
        XCTAssertEqual(midSlope, 6 * 0.25 / transition, accuracy: 0.02)
    }

    // MARK: - Gain

    func testGainIsExactlyOneWhereMaskIsZero() {
        let shape = makeShape()
        for luma: Float in [0, 0.3, 0.5, 0.6, start] {
            XCTAssertEqual(shape.gain(luma: luma), 1.0, "gain must be exactly 1 below the threshold")
        }
    }

    func testGainReachesFullLiftAtTop() {
        let shape = makeShape()
        let expected = exp2(liftStops)
        XCTAssertEqual(expected, 2.6390157, accuracy: 1e-6)
        // Same expression as the renderer: mask 1 ⇒ exp2(liftStops · 1) exactly.
        XCTAssertEqual(shape.gain(luma: top), expected)
        XCTAssertEqual(shape.gain(luma: 1), expected)
        XCTAssertEqual(shape.gain(luma: 2), expected)
        XCTAssertEqual(shape.gain(luma: 1e6), expected)
    }

    func testLiftZeroIsIdentityEverywhere() {
        let shape = makeShape(liftStops: 0)
        let steps = 5000
        for index in 0...steps {
            let luma = Float(index) / Float(steps) * 2 - 0.5
            XCTAssertEqual(shape.gain(luma: luma), 1.0, "lift 0 must be the identity at luma \(luma)")
        }
    }

    func testGainIsMonotoneNonDecreasingInLuma() {
        let shape = makeShape()
        var previous = shape.gain(luma: 0)
        let steps = 10000
        for index in 1...steps {
            let luma = Float(index) / Float(steps) * 1.5
            let gain = shape.gain(luma: luma)
            XCTAssertGreaterThanOrEqual(gain, previous, "gain decreased at luma \(luma)")
            XCTAssertGreaterThanOrEqual(gain, 1)
            XCTAssertLessThanOrEqual(gain, 16)
            XCTAssertTrue(gain.isFinite)
            previous = gain
        }
    }

    func testMaskAndGainAreNaNFreeForExtremeLuma() {
        let shape = makeShape()
        let extremes: [Float] = [.nan, -.infinity, .infinity, -.greatestFiniteMagnitude, .greatestFiniteMagnitude, -1e30, 1e30]
        XCTAssertEqual(shape.mask(luma: .nan), 0, "NaN luma is treated as below the threshold")
        XCTAssertEqual(shape.mask(luma: -.infinity), 0)
        XCTAssertEqual(shape.mask(luma: .infinity), 1)
        for luma in extremes {
            let mask = shape.mask(luma: luma)
            let gain = shape.gain(luma: luma)
            XCTAssertTrue(mask.isFinite, "mask(\(luma)) must be finite")
            XCTAssertTrue(gain.isFinite, "gain(\(luma)) must be finite")
            XCTAssertGreaterThanOrEqual(mask, 0)
            XCTAssertLessThanOrEqual(mask, 1)
            XCTAssertGreaterThanOrEqual(gain, 1)
            XCTAssertLessThanOrEqual(gain, 16)
        }
    }

    // MARK: - Per-channel independence (one luma ⇒ one gain for R/G/B)

    /// A chromatic pixel and a grey pixel with *bit-identical* Float Rec.709 luma must receive
    /// the same gain. The pair below was found by search: both `rec709Luma` values are exactly
    /// `Float(0.9)` (`0x3F666666`), the default recipe's roll-off top.
    func testSameLumaDifferentChromaGetsSameGain() throws {
        // cap 4: the pair's brightest channel would touch the default 2.5 cap, which would mask
        // the ratio this test measures. The gain maths is cap-independent.
        let shape = makeShape(headroomCap: 4)
        let grey = RGBA(r: 0.9, g: 0.9, b: 0.9)
        let chromatic = RGBA(r: 0.623, g: 0.978, b: 0.943)
        XCTAssertEqual(grey.rec709Luma, chromatic.rec709Luma, "fixture pair must share one luma")
        XCTAssertEqual(chromatic.rec709Luma, 0.9)

        let base = try LinearImage(
            size: PixelSize(width: 2, height: 1),
            pixels: [grey.r, grey.g, grey.b, grey.a, chromatic.r, chromatic.g, chromatic.b, chromatic.a]
        )
        let result = try HDRRendition.render(base: base, shape: shape)
        let expectedGain = shape.gain(luma: chromatic.rec709Luma)
        XCTAssertEqual(expectedGain, exp2(liftStops), accuracy: 1e-6)

        for (basePixel, hdrPixel) in [
            (grey, RGBA(r: result.image.pixels[0], g: result.image.pixels[1], b: result.image.pixels[2], a: result.image.pixels[3])),
            (chromatic, RGBA(r: result.image.pixels[4], g: result.image.pixels[5], b: result.image.pixels[6], a: result.image.pixels[7])),
        ] {
            XCTAssertEqual(hdrPixel.r / basePixel.r, expectedGain, accuracy: 1e-6)
            XCTAssertEqual(hdrPixel.g / basePixel.g, expectedGain, accuracy: 1e-6)
            XCTAssertEqual(hdrPixel.b / basePixel.b, expectedGain, accuracy: 1e-6)
        }
    }

    /// The same gain is applied to R, G and B of one pixel, even when the chroma is strong.
    func testAllChannelsOfOnePixelGetTheSameGain() throws {
        let shape = makeShape()
        let pixel = RGBA(r: 0.95, g: 0.63, b: 0.3)
        let base = try LinearImage(size: PixelSize(width: 1, height: 1), pixels: [pixel.r, pixel.g, pixel.b, pixel.a])
        let result = try HDRRendition.render(base: base, shape: shape)
        let k = result.image.pixels
        let luma = pixel.rec709Luma
        let expectedGain = shape.gain(luma: luma)
        XCTAssertGreaterThan(expectedGain, 1.05, "fixture must sit inside the roll-off")
        XCTAssertEqual(k[0] / pixel.r, expectedGain, accuracy: 1e-6)
        XCTAssertEqual(k[1] / pixel.g, expectedGain, accuracy: 1e-6)
        XCTAssertEqual(k[2] / pixel.b, expectedGain, accuracy: 1e-6)
        XCTAssertEqual(k[3], pixel.a, "alpha is copied untouched")
    }
}
