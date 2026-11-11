import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ContractKit

/// Facts about the SDR base PNG that the BaseStore/UI can show, established by validation.
public struct BaseFacts: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let colorSpaceName: String
    public let hasAlpha: Bool
    public let byteCount: Int

    public init(
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        colorSpaceName: String,
        hasAlpha: Bool,
        byteCount: Int
    ) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.colorSpaceName = colorSpaceName
        self.hasAlpha = hasAlpha
        self.byteCount = byteCount
    }
}

/// Why an SDR base PNG cannot be used for judging.
public enum BasePNGError: Error, Equatable, Sendable {
    /// The bytes are not a decodable image (or the linearising context could not be created).
    case invalidData
    /// The PNG is not 16 bits per component; Stage 1 delivers 16-bit only (docs/reference/wire.md, M2.1 wire contract).
    case not16Bit(actual: Int)
    /// The PNG carries an alpha channel; Stage 1 delivers RGB with no alpha (decision 5).
    case hasAlpha
    /// The PNG's colour space is not Display P3; a non-P3 base must never be clamped.
    case notDisplayP3(name: String)
    /// The decoded geometry disagrees with `PreviewMetadata.base`.
    case dimensionMismatch(expected: PixelSize, actual: PixelSize)
    /// The downloaded bytes disagree with `PreviewMetadata.base.sha256` (truncated/corrupt).
    case hashMismatch(expected: String, actual: String)
    /// The PNG is not the `png-16-p3` deliverable (wrong declared format, working space, or a
    /// pixel layout other than 48-bit RGB).
    case formatUnexpected(String)
}

/// The BaseStore decode path: validate the downloaded 16-bit Display P3 PNG, then linearise it
/// into the Stage-1 working buffer (linear extended Display P3, RGBA Float32, row 0 = top row,
/// alpha 1) for the shader and `HighlightShape`.
///
/// Verified decode recipe (probed on this machine against the real 2560×1707 trial base):
/// ImageIO `CGImageSourceCreateWithData` → `CGImageSourceCreateImageAtIndex`; require 16 bits
/// per component, `alphaInfo == .none`, the Display P3 colour-space name and an ICC profile;
/// then draw into a `CGContext` in `extendedLinearDisplayP3` with 32-bit float components. That
/// context yields exactly the contract's working buffer, and CoreGraphics applies the encoded
/// (sRGB-curve) → linear transfer while drawing. Nothing here clamps or tone-maps: a non-P3
/// source is refused with its actual profile name, never silently converted.
public enum BasePNG {
    /// The only base format the M2.1 server delivers (`PreviewMetadata.BaseInfo.format`).
    public static let expectedFormat = "png-16-p3"
    /// The working space the shader expects (`PreviewMetadata.BaseInfo.workingSpace`).
    public static let expectedWorkingSpace = "linear-extended-DisplayP3-float32"

    // MARK: - Validation

    /// Validates the downloaded PNG against the metadata the Mac advertised.
    ///
    /// Order: declared format/working space → SHA-256 of the bytes → ImageIO decode → geometry →
    /// 16-bit / no alpha / Display P3 + ICC. The hash is checked *before* decoding, so a truncated
    /// or corrupted 22 MB transfer is reported as such and never reaches ImageIO.
    ///
    /// - Throws: `BasePNGError`.
    public static func validate(
        data: Data,
        expected: PreviewMetadata.BaseInfo
    ) throws -> BaseFacts {
        let image = try validatedImage(data: data, expected: expected)
        return facts(for: image, byteCount: data.count)
    }

    /// Validates, then linearises in one decode (the BaseStore hot path).
    ///
    /// - Throws: `BasePNGError` from validation, `PhotonError.invalidImage` only if the decoded
    ///   buffer cannot form a `LinearImage` (cannot happen for a validated PNG).
    public static func load(
        data: Data,
        expected: PreviewMetadata.BaseInfo
    ) throws -> LinearImage {
        let image = try validatedImage(data: data, expected: expected)
        return try linearise(image: image)
    }

    // MARK: - Linearisation

    /// Linearises any decodable PNG into the Stage-1 working buffer.
    ///
    /// This is the shader's input space: linear extended Display P3, `1.0` = SDR reference white,
    /// RGBA Float32 interleaved, row-major with row 0 the top row, alpha 1.0. Use `load(data:
    /// expected:)` on the wire path: this entry point does not validate the base contract.
    ///
    /// - Throws: `BasePNGError.invalidData` if the bytes do not decode or the context fails.
    public static func linearise(data: Data) throws -> LinearImage {
        try linearise(image: decodeImage(data))
    }

    // MARK: - Internals

    private static func validatedImage(
        data: Data,
        expected: PreviewMetadata.BaseInfo
    ) throws -> CGImage {
        guard expected.format == expectedFormat else {
            throw BasePNGError.formatUnexpected(
                "base format '\(expected.format)' (this build decodes '\(expectedFormat)' only)"
            )
        }
        guard expected.workingSpace == expectedWorkingSpace else {
            throw BasePNGError.formatUnexpected(
                "working space '\(expected.workingSpace)' (the shader expects '\(expectedWorkingSpace)')"
            )
        }
        let actualHash = sha256Hex(data)
        guard actualHash.caseInsensitiveCompare(expected.sha256) == .orderedSame else {
            throw BasePNGError.hashMismatch(expected: expected.sha256, actual: actualHash)
        }

        let image = try decodeImage(data)
        let actualSize = PixelSize(width: image.width, height: image.height)
        let expectedSize = PixelSize(width: expected.width, height: expected.height)
        guard actualSize == expectedSize else {
            throw BasePNGError.dimensionMismatch(expected: expectedSize, actual: actualSize)
        }

        guard image.bitsPerComponent == 16 else {
            throw BasePNGError.not16Bit(actual: image.bitsPerComponent)
        }
        guard image.alphaInfo == .none else {
            throw BasePNGError.hasAlpha
        }
        let colorSpaceName = (image.colorSpace?.name as String?) ?? ""
        guard colorSpaceName == displayP3ColorSpaceName else {
            throw BasePNGError.notDisplayP3(name: colorSpaceName.isEmpty ? "(none)" : colorSpaceName)
        }
        guard image.colorSpace?.copyICCData() != nil else {
            throw BasePNGError.formatUnexpected("the base PNG carries no ICC profile")
        }
        guard image.bitsPerPixel == 48 else {
            throw BasePNGError.formatUnexpected(
                "expected 48 bits per pixel (16-bit RGB, no alpha), got \(image.bitsPerPixel)"
            )
        }
        return image
    }

    private static func facts(for image: CGImage, byteCount: Int) -> BaseFacts {
        let colorSpaceName = (image.colorSpace?.name as String?) ?? ""
        return BaseFacts(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            colorSpaceName: colorSpaceName,
            hasAlpha: image.alphaInfo != .none,
            byteCount: byteCount
        )
    }

    private static func decodeImage(_ data: Data) throws -> CGImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BasePNGError.invalidData
        }
        return image
    }

    /// Draws the decoded 16-bit P3 image into the linear extended Display P3 float buffer.
    ///
    /// The buffer is allocated once and the drawing fills it in place; the `CGImage` is released
    /// as soon as this function returns (only the `LinearImage` floats survive).
    private static func linearise(image: CGImage) throws -> LinearImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw BasePNGError.invalidData }

        var pixels = [Float](repeating: 0, count: width * height * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            // Verified on this machine: RGBA Float32 linear extended Display P3, row 0 = top row,
            // alpha 1.0. The colour-space conversion applies the encoded → linear transfer.
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 32,
                bytesPerRow: width * 16,
                space: linearP3ColorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw BasePNGError.invalidData }
        return try LinearImage(size: PixelSize(width: width, height: height), pixels: pixels)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Colour spaces

    private static let displayP3ColorSpaceName: String = {
        CGColorSpace(name: CGColorSpace.displayP3)!.name as String? ?? "kCGColorSpaceDisplayP3"
    }()

    private static let linearP3ColorSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    }()
}
