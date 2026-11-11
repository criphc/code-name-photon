import CoreGraphics
import CoreImage

/// The one checked Core Image bitmap render.
///
/// `CIContext.render(_:toBitmap:...)` has no error channel. On a freshly created GPU-backed
/// context it can return before the GPU has written the destination, leaving the zero-initialized
/// buffer in place; measured 2026-11-09 on the `previewAgreement` path: 2–8 of 20 runs produced a
/// zero (or partially written) preview buffer (ΔE 7.75–51.1 instead of 1.17) while the delivered
/// HEIC was byte-identical (docs/plans/preview-agreement-investigation.md).
///
/// `CIRenderDestination` + `CIRenderTask.waitUntilCompleted()` waits for the GPU and throws on
/// failure, so a failed render becomes a visible error instead of a plausible-looking zero image.
/// Every bitmap render in EngineKit goes through here (preview, source decode, verifier strips).
///
/// One `CIContext` is shared by the whole package: the failure is a cold-context/first-render
/// race, and a shared context removes the repeated cold starts (and the repeated GPU command
/// queue setup) that make it likely. A discarded command buffer (GPU recovery) is retried once;
/// a persistent failure throws.
enum CIRender {
    /// The package-wide context: linear extended Display P3 in and out, no intermediate cache.
    ///
    /// `CIContext` is thread-safe; the store and the delivery pipeline serialise their renders
    /// anyway, and sharing one context is what keeps a cold GPU context from being created per
    /// preview/verification call.
    static let sharedContext = CIContext(options: [
        .workingColorSpace: ImageBuffers.linearP3,
        .outputColorSpace: ImageBuffers.linearP3,
        .cacheIntermediates: false,
    ])

    /// Renders `image`'s `bounds` into `buffer`, with destination row 0 = the top of `bounds`.
    ///
    /// That is the row mapping `CIContext.render(_:toBitmap:bounds:)` uses (see the strip comment
    /// in `DeliveryImageProbe`); `CIRenderDestination` defaults to bottom-up, so it is flipped here
    /// to keep the established mapping. The caller must keep `buffer` valid until this returns.
    ///
    /// - Throws: the `CIRenderTask` error when the GPU render fails, after one retry; never
    ///   returns a silent zero buffer.
    static func render(
        _ image: CIImage,
        toBitmap buffer: UnsafeMutableRawPointer,
        rowBytes: Int,
        bounds: CGRect,
        format: CIFormat,
        colorSpace: CGColorSpace,
        context: CIContext
    ) throws {
        let width = Int(bounds.width.rounded())
        let height = Int(bounds.height.rounded())
        guard width > 0, height > 0 else { return }

        // `startTask(toRender:to:)` is the whole-image path; strips need the source rect/point.
        let isWholeImage = bounds.equalTo(image.extent)
        var lastError: Error?
        for _ in 0..<2 {
            let destination = CIRenderDestination(
                bitmapData: buffer,
                width: width,
                height: height,
                bytesPerRow: rowBytes,
                format: format
            )
            destination.colorSpace = colorSpace
            destination.isFlipped = true
            do {
                let task: CIRenderTask
                if isWholeImage {
                    task = try context.startTask(toRender: image, to: destination)
                } else {
                    task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
                }
                try task.waitUntilCompleted()
                return
            } catch {
                // A discarded command buffer (GPU recovery) is transient; retry once with a fresh
                // destination. A deterministic parameter error will throw again and surface.
                lastError = error
            }
        }
        throw lastError ?? PhotonError.invalidImage(reason: "Core Image render failed without an error")
    }
}
