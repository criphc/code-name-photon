@testable import ClientKit
import ContractKit
import CryptoKit
import Foundation
import Metal
import XCTest

/// The M3.3 "one maths" parity gate: the MSL kernel the iOS app runtime-compiles
/// (`client/Sources/ClientKit/Shaders/HighlightShape.msl`, shipped as a `ClientKit` package
/// resource and read through `ShaderResource`, never compiled by Xcode or the Metal toolchain)
/// against the CPU contract (`ContractKit.HighlightShape` / `HDRRendition`).
///
/// Gate (`docs/reference/client.md`, one maths, one parity gate): the maximum absolute error over every
/// rendered sample is ≤ 1e-4 linear on (a) a fixed analytic fixture grid that actually covers
/// mask = 0, the transition region, mask = 1 and the engaged headroom cap, and (b) the decoded
/// trial base (opt-in evidence run: set `PHOTON_TRIAL_BASE_PARITY=1`).
///
/// The GPU side is the real pipeline, exactly like the app: a
/// `texture2d<float, access::read>` holding the linear extended Display P3 RGBA Float32 base,
/// a `.rgba32Float` output texture, the 32-byte `HighlightUniforms` block at buffer(0) and
/// `dispatchThreads` with 16×16 threadgroups. The CPU side is `HDRRendition.render(base:shape:)`
/// (the same Float pipeline), so a mismatch means the MSL port and the contract have diverged.
///
/// Runs under `swift test` on the macOS host (no simulator, no Xcode-only target, no
/// `Bundle.main`). The analytic cases are unconditional: a missing Metal device or a compile
/// failure fails the test (ADR-0008), never a skip.
final class ShaderParityTests: XCTestCase {
    // MARK: - Gate constants

    /// `docs/reference/client.md`, one maths, one parity gate: absolute error on every rendered sample, in linear light.
    private static let parityTolerance: Float = 1e-4
    /// Hold-to-compare is the base texture itself (`gain = 1`), not a second tone map.
    private static let compareTolerance: Float = 1e-6
    /// The overlay is a false-colour guide, not a rendition: the docs pin the band colours.
    private static let overlayTolerance: Float = 1e-3

    /// The fixed fixture grid. 128×64 is small enough to be fast and large enough that the
    /// analytic ramp crosses every region with hundreds of samples in each.
    private static let fixtureWidth = 128
    private static let fixtureHeight = 64

    // MARK: - Test 0: the gate compiles the packaged MSL, byte for byte

    /// Proves the resource the gate compiles is the package's bundled copy of the checked-in MSL:
    /// the URL lives in a `.bundle` (not a repo path, not `Bundle.main`) and the sha256 matches
    /// `client/Sources/ClientKit/Shaders/HighlightShape.msl`.
    func testPackagedShaderIsTheCheckedInSource() throws {
        guard let packagedURL = TestSupport.shaderURL else {
            XCTFail("HighlightShape.msl is missing from the ClientKit resource bundle")
            return
        }
        let packagedPath = packagedURL.standardizedFileURL.path
        XCTAssertTrue(
            packagedPath.contains(".bundle/"),
            "the parity gate must compile the packaged MSL, not a repo path; got \(packagedPath)"
        )

        let packaged = try Data(contentsOf: packagedURL)
        let checkedIn = try Data(contentsOf: TestSupport.checkedInShaderURL)
        let packagedSHA = sha256Hex(packaged)
        XCTAssertEqual(
            packagedSHA,
            sha256Hex(checkedIn),
            "the packaged MSL must be byte-identical to client/Sources/ClientKit/Shaders/HighlightShape.msl"
        )
        print("PARITY shader packaged path=\(packagedPath) sha256=\(packagedSHA)")
    }

    // MARK: - Test 1: fixed grid, documented default recipe

    func testFixtureGridParity() throws {
        let harness = try ShaderHarness()
        // The uniform block is a raw `setBytes` layout contract with the MSL struct.
        XCTAssertEqual(
            MemoryLayout<HighlightUniforms>.stride,
            HighlightUniforms.byteCount,
            "HighlightUniforms must stay the same 32-byte block the MSL struct declares"
        )

        let base = makeFixtureBase()
        let shape = try HighlightShape(start: 0.62, liftStops: 1.4, transition: 0.28, headroomCap: 2.5)

        // The gate must not be able to pass on a fixture that never reaches a region.
        assertFixtureChannelsVary(base: base)
        let coverage = makeCoverage(base: base, shape: shape)
        XCTAssertGreaterThan(coverage.maskZero, 100, "fixture must cover luma <= start (mask 0), got \(coverage.maskZero)")
        XCTAssertGreaterThan(coverage.transition, 100, "fixture must cover the smoothstep transition, got \(coverage.transition)")
        XCTAssertGreaterThan(coverage.maskOne, 100, "fixture must cover luma >= start + transition (mask 1), got \(coverage.maskOne)")
        XCTAssertGreaterThan(coverage.capEngaged, 100, "fixture must reach base * gain > headroomCap (cap engaged), got \(coverage.capEngaged)")

        let expected = try HDRRendition.render(base: base, shape: shape).image
        let report = try performParity(
            harness: harness,
            label: "fixture / default recipe",
            base: base,
            shape: shape,
            expected: expected,
            tolerance: Self.parityTolerance
        )
        printFixtureSummary(test: "fixed-grid", shape: shape, mode: .authored, base: base, report: report, coverage: coverage)
    }

    // MARK: - Test 2: the same grid through the edge recipes

    func testFixtureGridParityEdgeRecipes() throws {
        let harness = try ShaderHarness()
        let base = makeFixtureBase()

        // Edge recipes from docs/reference/client.md, control model and the recipe schema ranges: no lift, a start the
        // fixture luma never reaches, a transition wider than the whole ramp, both extremes at
        // once, and both ends of the delivered cap range.
        let recipes: [(name: String, shape: HighlightShape)] = [
            ("lift-0", try HighlightShape(start: 0.62, liftStops: 0, transition: 0.28, headroomCap: 2.5)),
            ("start-1", try HighlightShape(start: 1, liftStops: 1.4, transition: 0.28, headroomCap: 2.5)),
            ("transition-1", try HighlightShape(start: 0.62, liftStops: 1.4, transition: 1, headroomCap: 2.5)),
            ("start-0-lift-4", try HighlightShape(start: 0, liftStops: 4, transition: 0.28, headroomCap: 2.5)),
            ("cap-1.5", try HighlightShape(start: 0.62, liftStops: 1.4, transition: 0.28, headroomCap: 1.5)),
            ("cap-8", try HighlightShape(start: 0, liftStops: 4, transition: 0.28, headroomCap: 8)),
        ]

        for recipe in recipes {
            let expected = try HDRRendition.render(base: base, shape: recipe.shape).image
            let report = try performParity(
                harness: harness,
                label: "fixture / \(recipe.name)",
                base: base,
                shape: recipe.shape,
                expected: expected,
                tolerance: Self.parityTolerance
            )
            if recipe.name == "lift-0" {
                // lift = 0 must be the base, exactly: mask == 0 ⇒ gain 1 and exp2(0) == 1,
                // then min(base, 2.5) keeps the fixture (all samples ≤ 1) untouched.
                XCTAssertEqual(
                    report.maxError.magnitude,
                    0,
                    "lift 0 must pass the base through exactly, got max abs error \(format(report.maxError.magnitude))"
                )
            }
            printFixtureSummary(test: "edge-recipe", shape: recipe.shape, mode: .authored, base: base, report: report)
        }
    }

    // MARK: - Test 3: hold-to-compare returns the base

    func testCompareModeReturnsBase() throws {
        let harness = try ShaderHarness()
        let base = makeFixtureBase()
        let shape = try HighlightShape(start: 0.62, liftStops: 1.4, transition: 0.28, headroomCap: 2.5)

        // Guard against a vacuous pass: if the authored path happened to equal the base for the
        // whole fixture, "compare == base" would prove nothing about the mode switch.
        let authored = try HDRRendition.render(base: base, shape: shape).image
        let authoredDelta = maximumError(gpu: authored, cpu: base)
        XCTAssertGreaterThan(
            authoredDelta.magnitude,
            0.5,
            "the default recipe must visibly change the fixture before compare mode is meaningful"
        )

        let report = try performParity(
            harness: harness,
            label: "fixture / compare mode",
            base: base,
            shape: shape,
            mode: .compare,
            expected: base,
            tolerance: Self.compareTolerance
        )
        printFixtureSummary(test: "compare-mode", shape: shape, mode: .compare, base: base, report: report)
    }

    // MARK: - Test 4: overlay bands

    func testOverlayBandsMatchCPUClassification() throws {
        let harness = try ShaderHarness()
        let base = makeFixtureBase()
        let shape = try HighlightShape(start: 0.62, liftStops: 1.4, transition: 0.28, headroomCap: 2.5)
        let displayHeadroom: Float = 2.0

        let authored = try HDRRendition.render(base: base, shape: shape).image
        let expectation = makeOverlayExpectation(base: base, authored: authored, displayHeadroom: displayHeadroom)
        XCTAssertGreaterThan(expectation.withinSDR, 0, "fixture must have authored ≤ 1.0 pixels (withinSDR)")
        XCTAssertGreaterThan(expectation.aboveSDR, 0, "fixture must have 1.0 < authored ≤ displayHeadroom pixels (aboveSDR)")
        XCTAssertGreaterThan(expectation.beyondHeadroom, 0, "fixture must have authored > displayHeadroom pixels (beyondHeadroom)")

        let report = try performParity(
            harness: harness,
            label: "fixture / overlay mode (headroom 2.0)",
            base: base,
            shape: shape,
            mode: .overlay,
            displayHeadroom: displayHeadroom,
            expected: expectation.image,
            tolerance: Self.overlayTolerance
        )
        print(
            "PARITY fixture test=overlay-bands recipe={\(describe(shape))} headroom=\(format(displayHeadroom)) "
                + "pixels=\(base.size.pixelCount) maxAbsError=\(format(report.maxError.magnitude)) "
                + "tolerance=\(format(report.tolerance)) "
                + "bands{withinSDR=\(expectation.withinSDR) aboveSDR=\(expectation.aboveSDR) beyondHeadroom=\(expectation.beyondHeadroom)}"
        )
    }

    // MARK: - Test 5: the decoded trial base (opt-in evidence run)

    func testTrialBaseParity() throws {
        guard ProcessInfo.processInfo.environment["PHOTON_TRIAL_BASE_PARITY"] == "1" else {
            throw XCTSkip(
                "opt-in evidence run: set PHOTON_TRIAL_BASE_PARITY=1 to run the trial-base parity "
                    + "(needs Metal and the gitignored work/m21-final/preview-base.png)"
            )
        }
        guard let data = try TestSupport.loadWorkBasePNG() else {
            // Opted in but the gitignored fixture is gone: that is a broken evidence run, not a
            // reason to go green, so fail instead of skipping (ADR-0008).
            XCTFail(
                "PHOTON_TRIAL_BASE_PARITY=1 but the trial base PNG is missing; expected "
                    + "work/m21-final/preview-base.png or PHOTON_M3_BASE_PNG — required for M3.6 evidence"
            )
            return
        }
        let harness = try ShaderHarness()
        let base = try BasePNG.linearise(data: data)

        XCTAssertEqual(base.size.width, 2560, "trial base must be the 2560 px SDR base the server serves")
        XCTAssertEqual(base.size.height, 1707, "trial base must be 2560x1707")
        XCTAssertTrue(base.isFinite, "trial base must decode to finite linear samples")

        let trialFile = relativeWorkPath()
        let defaultShape = try HighlightShape(start: 0.62, liftStops: 1.4, transition: 0.28, headroomCap: 2.5)
        let liftZeroShape = try HighlightShape(start: 0.62, liftStops: 0, transition: 0.28, headroomCap: 2.5)

        let defaultExpected = try HDRRendition.render(base: base, shape: defaultShape).image
        let defaultReport = try performParity(
            harness: harness,
            label: "trial base / default recipe",
            base: base,
            shape: defaultShape,
            expected: defaultExpected,
            tolerance: Self.parityTolerance
        )
        print(
            "PARITY trial file=\(trialFile) size=\(base.size.width)x\(base.size.height) "
                + "recipe={\(describe(defaultShape))} pixels=\(base.size.pixelCount) "
                + "maxAbsError=\(format(defaultReport.maxError.magnitude)) tolerance=\(format(defaultReport.tolerance))"
        )

        let liftZeroExpected = try HDRRendition.render(base: base, shape: liftZeroShape).image
        let liftZeroReport = try performParity(
            harness: harness,
            label: "trial base / lift-0",
            base: base,
            shape: liftZeroShape,
            expected: liftZeroExpected,
            tolerance: Self.parityTolerance
        )
        print(
            "PARITY trial file=\(trialFile) size=\(base.size.width)x\(base.size.height) "
                + "recipe={\(describe(liftZeroShape))} pixels=\(base.size.pixelCount) "
                + "maxAbsError=\(format(liftZeroReport.maxError.magnitude)) tolerance=\(format(liftZeroReport.tolerance))"
        )
    }

    // MARK: - Fixture

    /// The fixed 128×64 analytic base.
    ///
    /// `g` is a linear-light ramp (0.02…1.0) in x; `r` and `b` swing around it with a chroma
    /// profile in y. All three channels vary over the grid and every channel stays in 0…1, so the
    /// grid is a plausible SDR base rather than a grey ramp: luma and chroma are independent.
    /// The ramp crosses luma < start (mask 0), the smoothstep transition, luma > start +
    /// transition (mask 1, gain 2.639), and reaches base * gain > 2.5 so the cap engages.
    private func makeFixtureBase() -> LinearImage {
        TestSupport.makeLinearImage(width: Self.fixtureWidth, height: Self.fixtureHeight) { x, y in
            let u = Float(x) / Float(Self.fixtureWidth - 1)
            let v = Float(y) / Float(Self.fixtureHeight - 1)
            let ramp = 0.02 + 0.98 * u
            let chroma = 2 * v - 1
            return RGBA(
                r: ramp * (0.86 + 0.14 * chroma),
                g: ramp,
                b: ramp * (0.90 + 0.10 * chroma),
                a: 1
            )
        }
    }

    /// Fails if the fixture degenerates into a grey ramp or a single-channel image.
    private func assertFixtureChannelsVary(
        base: LinearImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var rMin = Float.greatestFiniteMagnitude
        var rMax = -Float.greatestFiniteMagnitude
        var gMin = Float.greatestFiniteMagnitude
        var gMax = -Float.greatestFiniteMagnitude
        var bMin = Float.greatestFiniteMagnitude
        var bMax = -Float.greatestFiniteMagnitude
        var maxChannelSpread: Float = 0

        for y in 0 ..< base.size.height {
            for x in 0 ..< base.size.width {
                let pixel = base.pixel(x: x, y: y)
                rMin = min(rMin, pixel.r)
                rMax = max(rMax, pixel.r)
                gMin = min(gMin, pixel.g)
                gMax = max(gMax, pixel.g)
                bMin = min(bMin, pixel.b)
                bMax = max(bMax, pixel.b)
                let spread = max(pixel.r, max(pixel.g, pixel.b)) - min(pixel.r, min(pixel.g, pixel.b))
                maxChannelSpread = max(maxChannelSpread, spread)
            }
        }

        XCTAssertGreaterThan(rMax - rMin, 0.2, "fixture red must vary over the grid", file: file, line: line)
        XCTAssertGreaterThan(gMax - gMin, 0.2, "fixture green must vary over the grid", file: file, line: line)
        XCTAssertGreaterThan(bMax - bMin, 0.2, "fixture blue must vary over the grid", file: file, line: line)
        XCTAssertGreaterThan(maxChannelSpread, 0.05, "fixture must not be a pure grey ramp", file: file, line: line)
    }

    /// Counts pixels in each region the gate claims to cover.
    private struct FixtureCoverage {
        var maskZero = 0
        var transition = 0
        var maskOne = 0
        var capEngaged = 0
    }

    private func makeCoverage(base: LinearImage, shape: HighlightShape) -> FixtureCoverage {
        var coverage = FixtureCoverage()
        for y in 0 ..< base.size.height {
            for x in 0 ..< base.size.width {
                let pixel = base.pixel(x: x, y: y)
                let luma = pixel.rec709Luma
                let mask = shape.mask(luma: luma)
                if mask == 0 {
                    coverage.maskZero += 1
                } else if mask == 1 {
                    coverage.maskOne += 1
                } else {
                    coverage.transition += 1
                }
                let peak = max(pixel.r, max(pixel.g, pixel.b))
                if peak * shape.gain(luma: luma) > shape.headroomCap {
                    coverage.capEngaged += 1
                }
            }
        }
        return coverage
    }

    // MARK: - Overlay expectation

    /// CPU expectation for the overlay false colours, from the same three-way classification the
    /// docs pin (`OverlayBands.classify` on the *authored* peak, after the cap).
    private struct OverlayExpectation {
        let image: LinearImage
        let withinSDR: Int
        let aboveSDR: Int
        let beyondHeadroom: Int
    }

    private func makeOverlayExpectation(
        base: LinearImage,
        authored: LinearImage,
        displayHeadroom: Float
    ) -> OverlayExpectation {
        var image = LinearImage(size: base.size, repeating: .black)
        var withinSDR = 0
        var aboveSDR = 0
        var beyondHeadroom = 0

        for y in 0 ..< base.size.height {
            for x in 0 ..< base.size.width {
                let basePixel = base.pixel(x: x, y: y)
                let authoredPixel = authored.pixel(x: x, y: y)
                let authoredPeak = max(authoredPixel.r, max(authoredPixel.g, authoredPixel.b))
                let band = OverlayBands.classify(authoredPeak: authoredPeak, displayHeadroom: displayHeadroom)
                let shown: RGBA
                switch band {
                case .withinSDR:
                    // Dimmed luma of the untouched base (docs/reference/client.md, control model).
                    let luma = basePixel.rec709Luma * 0.25
                    shown = RGBA(r: luma, g: luma, b: luma, a: 1)
                    withinSDR += 1
                case .aboveSDR:
                    shown = RGBA(r: 1.0, g: 0.85, b: 0.10, a: 1)
                    aboveSDR += 1
                case .beyondHeadroom:
                    shown = RGBA(r: 1.0, g: 0.10, b: 0.55, a: 1)
                    beyondHeadroom += 1
                }
                image.setPixel(x: x, y: y, shown)
            }
        }
        return OverlayExpectation(image: image, withinSDR: withinSDR, aboveSDR: aboveSDR, beyondHeadroom: beyondHeadroom)
    }

    // MARK: - Parity plumbing

    private struct MaxError {
        var magnitude: Float = 0
        var x = 0
        var y = 0
        var channel = 0
        var gpu: Float = 0
        var cpu: Float = 0
    }

    private struct ParityReport {
        let label: String
        let pixelCount: Int
        let tolerance: Float
        let maxError: MaxError
    }

    /// Runs the kernel for `shape`/`mode`, compares every r,g,b,a sample with `expected`
    /// (the CPU contract output) and asserts the gate.
    @discardableResult
    private func performParity(
        harness: ShaderHarness,
        label: String,
        base: LinearImage,
        shape: HighlightShape,
        mode: JudgeRenderMode = .authored,
        displayHeadroom: Float = 1,
        expected: LinearImage,
        tolerance: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ParityReport {
        XCTAssertEqual(
            expected.size,
            base.size,
            "\(label): CPU expectation must have the base geometry",
            file: file,
            line: line
        )
        let uniforms = HighlightUniforms(shape: shape, displayHeadroom: displayHeadroom, mode: mode)
        let gpu = try harness.render(base: base, uniforms: uniforms)
        XCTAssertEqual(gpu.size, base.size, "\(label): GPU output geometry", file: file, line: line)

        let maxError = maximumError(gpu: gpu, cpu: expected)
        let basePixel = base.pixel(
            x: min(maxError.x, base.size.width - 1),
            y: min(maxError.y, base.size.height - 1)
        )
        let message = "\(label): {\(describe(shape))} mode=\(modeName(mode)) "
            + "max abs error \(format(maxError.magnitude)) > \(format(tolerance)) linear at "
            + "x=\(maxError.x) y=\(maxError.y) channel=\(channelName(maxError.channel)) "
            + "base=(\(format(basePixel.r)), \(format(basePixel.g)), \(format(basePixel.b))) "
            + "cpu=\(format(maxError.cpu)) gpu=\(format(maxError.gpu)); "
            + "checked \(base.size.pixelCount) pixels / \(base.size.pixelCount * 4) samples"
        XCTAssertLessThanOrEqual(maxError.magnitude, tolerance, message, file: file, line: line)

        return ParityReport(
            label: label,
            pixelCount: base.size.pixelCount,
            tolerance: tolerance,
            maxError: maxError
        )
    }

    /// Max absolute per-channel difference between two same-size images.
    private func maximumError(gpu: LinearImage, cpu: LinearImage) -> MaxError {
        var result = MaxError()
        guard gpu.size == cpu.size else {
            result.magnitude = .infinity
            return result
        }
        let width = gpu.size.width
        gpu.pixels.withUnsafeBufferPointer { gpuPixels in
            cpu.pixels.withUnsafeBufferPointer { cpuPixels in
                var index = 0
                while index < gpuPixels.count {
                    for channel in 0 ..< 4 {
                        let gpuValue = gpuPixels[index + channel]
                        let cpuValue = cpuPixels[index + channel]
                        // Never let NaN == NaN pass silently.
                        let error: Float = (gpuValue.isFinite && cpuValue.isFinite)
                            ? abs(gpuValue - cpuValue)
                            : .infinity
                        if error > result.magnitude {
                            let pixel = index / 4
                            result = MaxError(
                                magnitude: error,
                                x: pixel % width,
                                y: pixel / width,
                                channel: channel,
                                gpu: gpuValue,
                                cpu: cpuValue
                            )
                        }
                    }
                    index += 4
                }
            }
        }
        return result
    }

    private func printFixtureSummary(
        test: String,
        shape: HighlightShape,
        mode: JudgeRenderMode,
        base: LinearImage,
        report: ParityReport,
        coverage: FixtureCoverage? = nil
    ) {
        var line = "PARITY fixture test=\(test) recipe={\(describe(shape))} mode=\(modeName(mode)) "
            + "size=\(base.size.width)x\(base.size.height) pixels=\(report.pixelCount) "
            + "maxAbsError=\(format(report.maxError.magnitude)) tolerance=\(format(report.tolerance))"
        if let coverage {
            line += " regions{mask0=\(coverage.maskZero) transition=\(coverage.transition) "
                + "mask1=\(coverage.maskOne) capEngaged=\(coverage.capEngaged)}"
        }
        print(line)
    }

    private func relativeWorkPath() -> String {
        guard let url = TestSupport.workBasePNGURL else { return "unknown" }
        let root = TestSupport.repositoryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    private func describe(_ shape: HighlightShape) -> String {
        "start=\(format(shape.start)) lift=\(format(shape.liftStops)) "
            + "transition=\(format(shape.transition)) cap=\(format(shape.headroomCap))"
    }

    private func modeName(_ mode: JudgeRenderMode) -> String {
        switch mode {
        case .authored: return "authored"
        case .compare: return "compare"
        case .overlay: return "overlay"
        }
    }

    private func channelName(_ channel: Int) -> String {
        ["r", "g", "b", "a"][channel]
    }
}

// MARK: - GPU harness

/// Compiles the app's MSL resource with the runtime Metal compiler (the same path the iPad app
/// takes) and runs `highlightShapeKernel` once per image.
private final class ShaderHarness {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        let device = try TestSupport.metalDevice()
        self.device = device
        let library = try TestSupport.makeShaderLibrary(device: device)
        guard let function = library.makeFunction(name: "highlightShapeKernel") else {
            throw ShaderParityError.missingKernelFunction
        }
        pipeline = try device.makeComputePipelineState(function: function)
        guard let queue = device.makeCommandQueue() else {
            throw ShaderParityError.cannotCreateCommandQueue
        }
        self.queue = queue
    }

    /// Uploads `base` as a `.rgba32Float` read texture, dispatches the kernel, waits for the GPU
    /// and copies the `.rgba32Float` result back. Shared storage is coherent on Apple silicon
    /// after `waitUntilCompleted`.
    func render(base: LinearImage, uniforms: HighlightUniforms) throws -> LinearImage {
        let width = base.size.width
        let height = base.size.height
        let bytesPerRow = width * MemoryLayout<Float>.size * 4

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        inputDescriptor.storageMode = .shared
        inputDescriptor.usage = .shaderRead
        guard let inputTexture = device.makeTexture(descriptor: inputDescriptor) else {
            throw ShaderParityError.cannotCreateTexture("base \(width)x\(height) rgba32Float")
        }
        base.pixels.withUnsafeBytes { raw in
            inputTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .shaderWrite
        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw ShaderParityError.cannotCreateTexture("output \(width)x\(height) rgba32Float")
        }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw ShaderParityError.cannotCreateCommandBuffer
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ShaderParityError.cannotCreateComputeEncoder
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: HighlightUniforms.byteCount, index: 0)
        }
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw ShaderParityError.commandBufferFailed(String(describing: error))
        }

        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            outputTexture.getBytes(
                raw.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return try LinearImage(size: base.size, pixels: pixels)
    }
}

// MARK: - Errors and formatting

private enum ShaderParityError: Error, CustomStringConvertible {
    case missingKernelFunction
    case cannotCreateCommandQueue
    case cannotCreateCommandBuffer
    case cannotCreateComputeEncoder
    case cannotCreateTexture(String)
    case commandBufferFailed(String)

    var description: String {
        switch self {
        case .missingKernelFunction:
            return "HighlightShape.msl has no highlightShapeKernel function"
        case .cannotCreateCommandQueue:
            return "could not create a Metal command queue"
        case .cannotCreateCommandBuffer:
            return "could not create a Metal command buffer"
        case .cannotCreateComputeEncoder:
            return "could not create a Metal compute command encoder"
        case let .cannotCreateTexture(what):
            return "could not create Metal texture: \(what)"
        case let .commandBufferFailed(message):
            return "highlightShapeKernel command buffer failed: \(message)"
        }
    }
}

private func format(_ value: Float) -> String {
    String(format: "%.9g", value)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
