import CoreGraphics
import CoreImage
import Foundation

/// The one place that turns a Stage-1 working buffer into a Core Graphics / Core Image image.
///
/// Core Image never owns a buffer it is merely handed: the first version of the preview path
/// passed a local `Data` to the bitmap-data initializer, which neither copies nor keeps the data
/// alive, so a later filter could read freed heap memory (M1: one preview out of four decoded
/// 25 % RMSE away with a 149× `tmap` peak; later runs were "correct" by heap luck — docs/reference/encoder.md).
///
/// Every image here is therefore built on the explicit ownership chain
/// `CIImage` → `CGImage` → `CGDataProvider` → `Data` (a copy of `image.pixels`). The provider
/// retains its `CFData`, and the `CGImage` retains the provider, so the pixels stay valid for as
/// long as any render can ask for them. Do not hand a local `Data` to Core Image's bitmap-data
/// initializer anywhere in this package (review P1-3); go through one of these helpers instead.
enum ImageBuffers {
    /// Linear extended Display P3 float32 — the Stage-1 working space.
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// The working buffer as a float32 RGBA `CGImage` in the working space.
    ///
    /// 32-bit float components, RGBA (premultipliedLast; alpha is always 1.0 in the working
    /// buffer, so premultiplication is a no-op), little-endian. `byteOrder32Little` is required:
    /// without it Core Image reads this bitmap as all zeros on this machine.
    ///
    /// No cell is copied beyond `Data(buffer:)`'s single copy, and that copy is owned by the
    /// returned image's provider.
    static func floatRGBA(_ image: LinearImage) throws -> CGImage {
        let width = image.size.width
        let height = image.size.height
        let data = image.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw PhotonError.invalidImage(
                reason: "cannot create a data provider for the \(image.size) working buffer"
            )
        }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.floatComponents.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 32,
            bitsPerPixel: 128,
            bytesPerRow: width * 16,
            space: linearP3,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PhotonError.invalidImage(
                reason: "cannot create a CGImage for the \(image.size) working buffer"
            )
        }
        return cgImage
    }

    /// The working buffer as a Core Image image; no colour conversion (already linear P3 float32).
    ///
    /// The returned `CIImage` owns its pixels through `floatRGBA`'s chain, so it is safe to put
    /// through a filter graph and render later.
    static func ciImage(_ image: LinearImage) throws -> CIImage {
        CIImage(cgImage: try floatRGBA(image))
    }
}

/// The shared 16-bit Display P3 `CGImage` both SDR-base writers encode from.
///
/// `TIFFWriter.writeSDRBase` (M1 preview base / M4 delivery) and `PNGWriter.writeSDRBase` (the
/// M2.1 base sent to the iPad) used to assemble this CGImage twice. `SDRQuantiser` already owned
/// the transfer + quantisation; this owns the sample layout (48 bpp, no alpha, little-endian
/// 16-bit, Display P3 ICC), so the two paths cannot drift apart (review P1-11). One pixel-level
/// equivalence test covers both (`SDRBaseWriterTests`).
enum SDRBaseCGImage {
    /// 16-bit Display P3 RGB, no alpha, from the linear-P3 working buffer.
    ///
    /// Samples outside 0…1 are clamped by `SDRQuantiser` (the 16-bit format has no room for
    /// them); that is the one place Stage 1 quantises, and this helper deliberately does not
    /// change the semantics when the two writers call it.
    ///
    /// - Throws: `PhotonError.invalidImage` for NaN / infinite samples, a zero-sized buffer, or if
    ///   the data provider / `CGImage` cannot be created.
    static func make(from image: LinearImage) throws -> CGImage {
        guard SampleMath.allFinite(image.pixels) else {
            throw PhotonError.invalidImage(
                reason: "cannot build a 16-bit SDR base from NaN or infinite samples"
            )
        }
        guard image.size.width > 0, image.size.height > 0 else {
            throw PhotonError.invalidImage(
                reason: "cannot build a 16-bit SDR base from a zero-sized image (\(image.size))"
            )
        }
        let encoded = SDRQuantiser.encodedSamples(image)
        // The provider retains the CFData (which owns the only copy of `encoded`), and the CGImage
        // retains the provider — so the samples outlive this scope for every consumer.
        let data = encoded.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw PhotonError.invalidImage(
                reason: "CGDataProvider could not take the \(image.size) SDR base samples"
            )
        }
        // 48 bpp, no alpha, little-endian 16-bit samples, tagged with the Display P3 ICC profile.
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        )
        guard let cgImage = CGImage(
            width: image.size.width,
            height: image.size.height,
            bitsPerComponent: 16,
            bitsPerPixel: 48,
            bytesPerRow: image.size.width * 3 * MemoryLayout<UInt16>.size,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PhotonError.invalidImage(
                reason: "CGImage creation failed for the \(image.size) SDR base"
            )
        }
        return cgImage
    }

    /// 8-bit Display P3 RGB, no alpha, from the linear-P3 working buffer.
    ///
    /// The 8-bit profile and the SDR fallback need a 3-sample base: `writeHEIFRepresentation` with
    /// an RGBA input writes an alpha channel, which the delivery's `alpha` check rejects. The
    /// samples are the same `SDRQuantiser.encoded16` curve reduced to 8 bits.
    static func make8Bit(from image: LinearImage) throws -> CGImage {
        guard SampleMath.allFinite(image.pixels) else {
            throw PhotonError.invalidImage(
                reason: "cannot build an 8-bit SDR base from NaN or infinite samples"
            )
        }
        guard image.size.width > 0, image.size.height > 0 else {
            throw PhotonError.invalidImage(
                reason: "cannot build an 8-bit SDR base from a zero-sized image (\(image.size))"
            )
        }
        let encoded = SDRQuantiser.encodedSamples(image)
        var bytes = [UInt8](repeating: 0, count: encoded.count)
        for index in 0..<encoded.count {
            bytes[index] = UInt8((Int(encoded[index]) + 128) / 257)
        }
        let data = bytes.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw PhotonError.invalidImage(reason: "CGDataProvider could not take the 8-bit SDR base samples")
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let cgImage = CGImage(
            width: image.size.width,
            height: image.size.height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: image.size.width * 3,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PhotonError.invalidImage(reason: "CGImage creation failed for the 8-bit SDR base")
        }
        return cgImage
    }
}
