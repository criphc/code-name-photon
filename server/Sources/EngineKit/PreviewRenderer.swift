import CoreImage
import Foundation

/// Builds the ≤2560 px preview pair for `appctl prep` (the M1/M4 development artifact).
///
/// M2.1 sends only the SDR base, as a 16-bit PNG built by `PreviewBaseRenderer`, so nothing in
/// this pair — the rendered preview HEIC included — travels over the wire.
///
/// The preview must be produced by the same encoder and the same maths as the final delivery
/// (docs/archive/stage-1/04-stage-1-plan.md M0 risk table); M0 encoded the preview with the
/// same `-b -d 8 -q 0.85 -c p3` flags.
///
/// Downscaling happens in the same linear extended Display P3 float32 working space as the final
/// render, through Core Image's Lanczos kernel (the M0 reference flow used the same filter).
public enum PreviewRenderer {
    public struct Pair: Sendable {
        public let base: LinearImage
        public let hdr: LinearImage
        public let size: PixelSize

        public init(base: LinearImage, hdr: LinearImage, size: PixelSize) {
            self.base = base
            self.hdr = hdr
            self.size = size
        }
    }

    /// The long edge the preview would have for a given source (no upscaling: min(source, longEdge)).
    public static func previewLongEdge(for size: PixelSize, limit: Int) -> Int {
        let sourceLongEdge = max(size.width, size.height)
        guard limit > 0 else { return sourceLongEdge }
        return min(sourceLongEdge, limit)
    }

    /// Lanczos downscale of both images to `longEdge` (no upscale), then clamp the HDR preview
    /// back to `headroomCap` — Lanczos overshoots above the cap (M0 measured this) and the preview
    /// must judge the same headroom as the delivered file.
    ///
    /// The two outputs always have the same `size`, whatever the aspect ratio.
    public static func downscale(
        base: LinearImage,
        hdr: LinearImage,
        longEdge: Int,
        headroomCap: Float
    ) throws -> Pair {
        guard base.size == hdr.size else {
            throw PhotonError.invalidImage(reason: "preview base \(base.size) and hdr \(hdr.size) differ")
        }
        guard headroomCap.isFinite, headroomCap >= 1 else {
            throw PhotonError.invalidImage(reason: "preview headroom cap \(headroomCap) must be >= 1")
        }

        let targetSize = targetSize(for: base.size, longEdge: longEdge)
        if targetSize == base.size {
            // Source already fits the limit: no resampling, no upscale. Re-clamp the HDR copy so
            // the preview's peak is the authored cap even if the caller hands us unclamped pixels.
            let clampedHDR = try HeadroomCap.clamp(hdr, cap: headroomCap)
            return Pair(base: base, hdr: clampedHDR, size: targetSize)
        }

        let context = makeContext()
        let scaledBase = try render(
            Self.lanczos(try ciImage(base), to: targetSize),
            size: targetSize,
            context: context
        )
        let scaledHDR = try render(
            Self.lanczos(try ciImage(hdr), to: targetSize),
            size: targetSize,
            context: context
        )
        let clampedHDR = try HeadroomCap.clamp(scaledHDR, cap: headroomCap)
        return Pair(base: scaledBase, hdr: clampedHDR, size: targetSize)
    }

    /// Downscale only the SDR base (M2's 16-bit PNG preview path): no HDR rendition, no clamp.
    public static func downscaleBase(_ image: LinearImage, longEdge: Int) throws -> LinearImage {
        let targetSize = targetSize(for: image.size, longEdge: longEdge)
        if targetSize == image.size { return image }
        let context = makeContext()
        return try render(
            Self.lanczos(try ciImage(image), to: targetSize),
            size: targetSize,
            context: context
        )
    }

    // MARK: - Geometry

    /// The resampled size for `longEdge`, preserving the aspect ratio (long edge exactly `longEdge`).
    static func targetSize(for size: PixelSize, longEdge: Int) -> PixelSize {
        let sourceLongEdge = max(size.width, size.height)
        guard longEdge > 0, longEdge < sourceLongEdge else { return size }
        let ratio = Double(longEdge) / Double(sourceLongEdge)
        if size.width >= size.height {
            let height = max(1, Int((Double(size.height) * ratio).rounded()))
            return PixelSize(width: longEdge, height: height)
        } else {
            let width = max(1, Int((Double(size.width) * ratio).rounded()))
            return PixelSize(width: width, height: longEdge)
        }
    }

    // MARK: - Core Image

    private static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    static func makeContext() -> CIContext {
        // One shared context: a cold GPU context's first render is the flaky stage
        // (docs/plans/preview-agreement-investigation.md).
        CIRender.sharedContext
    }

    /// The working buffer as a Core Image image; no colour conversion (already linear P3 float32).
    ///
    /// **The buffer must be owned by the returned `CIImage`.** A first version passed a local
    /// `Data` straight to Core Image's bitmap-data initializer: Core Image neither copies it nor
    /// keeps it alive past the initializer's scope, so the first Lanczos render read freed heap
    /// memory (M1 integration: one preview out of four decoded 25 % RMSE away, `tmap` peak
    /// 149.7×; only the first run after a fresh heap was affected — later runs were "correct" by
    /// heap luck). Never go back to that initializer here.
    ///
    /// `ImageBuffers` owns the verified chain and keeps the pixels valid for every render:
    /// `CIImage` → `CGImage` → `CGDataProvider` → `Data` (a copy of `image.pixels`). It is shared
    /// with the writers, which need the same ownership guarantee for their float buffer (P1-3).
    static func ciImage(_ image: LinearImage) throws -> CIImage {
        try ImageBuffers.ciImage(image)
    }

    /// Lanczos resample + crop to the exact target pixel grid (the crop drops the filter's edge
    /// extent). `scale` covers the long edge; `aspectRatio` carries the short-edge ratio, the same
    /// parameterisation the M0 reference flow used.
    ///
    /// The source is clamped to its extent *before* filtering: otherwise Core Image samples past
    /// the extent as transparent black, which darkens and rings the outer 1–2 px (review P1-2;
    /// measured on a uniform 0.5 image: first-row corner 0.4402, "interior" 0.4693, second row
    /// 0.5104, centre 0.5000 — the constant comes back non-constant). `clampedToExtent()`
    /// replicates the edge pixels infinitely, so a constant resamples to that constant everywhere,
    /// borders and corners included, while interior pixels keep the filter's normal (allowed)
    /// ringing.
    ///
    /// Scale is computed from the *finite* source extent (the clamped image's extent is infinite);
    /// `CILanczosScaleTransform` accepts the infinite extent and leaves the interior unchanged —
    /// measured: a uniform input is exactly 0.5 on every sample and a gradient's interior moves by
    /// at most one half-float ULP (2⁻¹¹ ≈ 4.9e-4), while the old edge error was up to 0.077. The
    /// infinite result is cropped back to the exact origin-0 target rectangle.
    static func lanczos(_ image: CIImage, to target: PixelSize) -> CIImage {
        let extent = image.extent
        let scaleX = CGFloat(target.width) / extent.width
        let scaleY = CGFloat(target.height) / extent.height
        let scaled = image.clampedToExtent().applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scaleX,
                kCIInputAspectRatioKey: scaleY / scaleX,
            ]
        )
        return scaled.cropped(
            to: CGRect(x: 0, y: 0, width: CGFloat(target.width), height: CGFloat(target.height))
        )
    }

    /// Renders a Core Image image into the Stage-1 working buffer, in linear extended Display P3.
    ///
    /// The working-buffer contract is "alpha always 1.0" (`Geometry.swift`); Lanczos renders the
    /// alpha sample too and floating-point error can leave it at 0.999…, so it is pinned here.
    static func render(_ image: CIImage, size: PixelSize, context: CIContext) throws -> LinearImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        // Checked render: `CIContext.render(_:toBitmap:)` can silently leave a fresh GPU context's
        // destination zeroed (docs/plans/preview-agreement-investigation.md); `CIRender` waits and
        // throws instead.
        try CIRender.render(
            image,
            toBitmap: &pixels,
            rowBytes: size.width * 16,
            bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
            format: .RGBAf,
            colorSpace: linearP3,
            context: context
        )
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 1
        }
        return try LinearImage(size: size, pixels: pixels)
    }
}
