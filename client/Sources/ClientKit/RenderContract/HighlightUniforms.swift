import Foundation
import ContractKit

/// The uniform block shared by the Metal shader port and the CPU contract maths.
///
/// This type is the *layout contract* for
/// `client/Sources/ClientKit/Shaders/HighlightShape.msl`: both sides declare the same eight 4-byte
/// slots, so the shader parity test (`client/Tests/ClientKitTests/ShaderParityTests.swift`) can
/// exercise the very same MSL source the iPad app renders with. Change one side only together with
/// the other.
///
/// Semantics come from `ContractKit.HighlightShape` and docs/reference/client.md, control model:
/// `mask = smoothstep(start, start+transition, rec709Luma(base))`,
/// `gain = 2^(liftStops*mask)`, `authored = min(base*gain, headroomCap)`.
/// `displayHeadroom` is *presentation* only: the EDR display's current headroom
/// (`UIScreen.currentEDRHeadroom`), used by the overlay and the readout, never by the maths.
public struct HighlightUniforms: Equatable, Sendable {
    /// Mask threshold on linear Rec.709 luma, `0...1`.
    public var start: Float
    /// Stops of gain at full mask, `0...4`.
    public var liftStops: Float
    /// Roll-off width above `start`, `0.001...1`.
    public var transition: Float
    /// Absolute linear clamp on the authored rendition, `1...8` (from the recipe; the UI presents
    /// it in stops).
    public var headroomCap: Float
    /// Currently available EDR headroom as a linear multiplier `>= 1` (1.0 = no HDR).
    public var displayHeadroom: Float
    /// `JudgeRenderMode.rawValue`; kept as UInt32 so the MSL struct layout is unambiguous.
    public var mode: UInt32
    /// Padding to a 32-byte block; must stay zero.
    public var pad0: UInt32
    /// Padding to a 32-byte block; must stay zero.
    public var pad1: UInt32

    public init(
        start: Float = 0.62,
        liftStops: Float = 1.4,
        transition: Float = 0.28,
        headroomCap: Float = Float(Recipe.HDR.defaultHeadroomCap),
        displayHeadroom: Float = 1,
        mode: JudgeRenderMode = .authored
    ) {
        self.start = start
        self.liftStops = liftStops
        self.transition = transition
        self.headroomCap = headroomCap
        self.displayHeadroom = displayHeadroom
        self.mode = mode.rawValue
        self.pad0 = 0
        self.pad1 = 0
    }

    /// Builds the uniforms from the validated recipe maths plus the presentation inputs.
    public init(
        shape: HighlightShape,
        displayHeadroom: Float,
        mode: JudgeRenderMode
    ) {
        self.init(
            start: shape.start,
            liftStops: shape.liftStops,
            transition: shape.transition,
            headroomCap: shape.headroomCap,
            displayHeadroom: displayHeadroom,
            mode: mode
        )
    }

    /// Byte length passed to `MTLRenderCommandEncoder.setBytes` / `setVertexBytes`.
    public static let byteCount = 32
}

/// What the shader should render for the current frame.
///
/// - `authored`: the authored HDR rendition (`base * gain`, clamped to the cap).
/// - `compare`: the same base texture with gain = 1 — the hold-to-compare SDR view.
/// - `overlay`: false-colour bands, see `OverlayBands`.
public enum JudgeRenderMode: UInt32, Sendable {
    case authored = 0
    case compare = 1
    case overlay = 2
}

/// Which fact the overlay should show for a pixel, from the *authored* value
/// (after the headroom cap) and the currently available display headroom.
///
/// The MR3 overlay must keep these two facts distinguishable (docs/reference/client.md, control model):
/// "authored above SDR white" is an authoring statement; "beyond the currently available
/// headroom" is a presentation statement that moves with brightness / HAGC.
public enum OverlayBand: Equatable, Sendable, CaseIterable {
    /// Authored value `<= 1.0` (at or below reference white): draw the dimmed base.
    case withinSDR
    /// Authored value `> 1.0` and `<= displayHeadroom`: authored above SDR white, presentable.
    case aboveSDR
    /// Authored value `> displayHeadroom`: authored beyond what the display can show now.
    case beyondHeadroom
}

/// CPU definition of the overlay bands. The shader implements the same three-way test;
/// `ShaderParityTests.testOverlayBandsMatchCPUClassification` pins this classification to the
/// docs/reference/client.md, control model semantics.
public enum OverlayBands {
    /// Classifies one pixel by its largest authored R/G/B sample.
    ///
    /// - Parameters:
    ///   - authoredPeak: `max(r,g,b)` of the authored rendition (post headroom cap).
    ///   - displayHeadroom: the EDR display's current linear headroom, `>= 1`.
    @inline(__always)
    public static func classify(authoredPeak: Float, displayHeadroom: Float) -> OverlayBand {
        if authoredPeak > displayHeadroom { return .beyondHeadroom }
        if authoredPeak > 1 { return .aboveSDR }
        return .withinSDR
    }

    /// Convenience for a whole pixel.
    @inline(__always)
    public static func classify(
        authored: RGBA,
        displayHeadroom: Float
    ) -> OverlayBand {
        classify(authoredPeak: max(authored.r, max(authored.g, authored.b)), displayHeadroom: displayHeadroom)
    }
}
