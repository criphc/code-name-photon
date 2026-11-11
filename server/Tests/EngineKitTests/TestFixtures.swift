import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import EngineKit

/// Shared, deterministic test fixtures. Generated at run time into a temporary directory —
/// tests must not depend on `samples/` (gitignored) or on `work/`.
enum TestFixtures {
    static func makeTemporaryDirectory(function: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-tests-\(function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 16-bit Display P3 TIFF with a horizontal linear-light gradient (0.02 → 0.98), no alpha.
    /// This is an SDR source in the shape of a Capture One export.
    @discardableResult
    static func writeGradientP3TIFF(size: PixelSize, to url: URL) throws -> URL {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
        let gradient = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: CGFloat(size.width), y: 0),
                "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1, colorSpace: linP3)!,
                "inputColor1": CIColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1, colorSpace: linP3)!,
            ]
        )!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        try context.writeTIFFRepresentation(of: gradient, to: url, format: .RGBA16, colorSpace: p3, options: [:])
        return url
    }

    /// Uniform 16-bit Display P3 TIFF with the given linear value (for mask-threshold tests).
    @discardableResult
    static func writeUniformP3TIFF(size: PixelSize, linearValue: Float, to url: URL) throws -> URL {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
        let image = CIImage(
            color: CIColor(red: CGFloat(linearValue), green: CGFloat(linearValue), blue: CGFloat(linearValue), alpha: 1, colorSpace: linP3)!
        ).cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: p3, options: [:])
        return url
    }

    /// `baseValue` everywhere except one `spotValue` pixel at the centre, written through the
    /// production 3-sample base writer (`TIFFWriter.writeSDRBase`) — a real base layout, and the
    /// only highlight in the frame (for the preview-collapse fail-fast test).
    @discardableResult
    static func writeSpotP3TIFF(
        size: PixelSize,
        baseValue: Float,
        spotValue: Float,
        to url: URL
    ) throws -> URL {
        var image = LinearImage(
            size: size,
            repeating: RGBA(r: baseValue, g: baseValue, b: baseValue)
        )
        image.setPixel(
            x: size.width / 2,
            y: size.height / 2,
            RGBA(r: spotValue, g: spotValue, b: spotValue)
        )
        try TIFFWriter.writeSDRBase(image, to: url)
        return url
    }

    /// A 16-bit TIFF of one uniform `colour`, encoded in and tagged with `colourSpace` — the shape of
    /// a Capture One export in a foreign profile (Adobe RGB 1998, sRGB). `SourceColourTests` uses
    /// this to prove those sources are refused by `SourceDecoder` (review P1-4).
    @discardableResult
    static func writeColourTIFF(
        size: PixelSize,
        colour: CIColor,
        colourSpace: CGColorSpace,
        to url: URL
    ) throws -> URL {
        let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
        let image = CIImage(color: colour)
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: colourSpace, options: [:])
        return url
    }

    /// 8-bit TIFF with **no embedded ICC profile**: a device-RGB bitmap written through
    /// `CGImageDestination` with no properties. The "untagged source" case of review P1-4.
    @discardableResult
    static func writeUntaggedTIFF(
        size: PixelSize,
        rgb: (r: Double, g: Double, b: Double),
        to url: URL
    ) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw PhotonError.invalidImage(reason: "cannot create the untagged fixture bitmap")
        }
        context.setFillColor(CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let cgImage = context.makeImage() else {
            throw PhotonError.invalidImage(reason: "cannot snapshot the untagged fixture bitmap")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot create a TIFF destination")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotonError.writeFailed(path: url.path, reason: "TIFF destination finalize failed")
        }
        return url
    }

    static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func srcProfileName(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyProfileName] as? String
    }
}
