@testable import ClientKit
import ContractKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest

/// Shared fixtures for the macOS-side `ClientKitTests` target.
///
/// The iOS app itself never links this file; it exists so the pure client logic (wire models,
/// transport, recipe draft, base decode) and the shader parity gate can run on the Mac without
/// a simulator or the device. The GPU side compiles the packaged
/// `client/Sources/ClientKit/Shaders/HighlightShape.msl` through `ShaderResource` — the same
/// bytes the app compiles at runtime (a package resource, never a .metallib / Metal toolchain).
enum TestSupport {
    /// Repository root, derived from this file's path: `<repo>/client/Tests/ClientKitTests/TestSupport.swift`.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClientKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // client
            .deletingLastPathComponent() // repo root
    }

    /// The packaged MSL URL (`ShaderResource` is the single loader; there is no repo-path or
    /// `Bundle.main` fallback). The parity tests compile the bytes this URL points at.
    static var shaderURL: URL? {
        ShaderResource.url()
    }

    /// The checked-in source of the package resource, used **only** to prove the packaged bytes are
    /// the same file. The tests never compile this URL.
    static var checkedInShaderURL: URL {
        repositoryRoot.appendingPathComponent("client/Sources/ClientKit/Shaders/HighlightShape.msl")
    }

    /// The schema-0 golden fixtures live in exactly one place (the contract package resource);
    /// the client tests read the same files by relative path instead of keeping a second copy.
    static func wireFixtureData(_ side: String, _ name: String) throws -> Data {
        let url = repositoryRoot.appendingPathComponent(
            "contract/Tests/ContractKitTests/Fixtures/schema-0/\(side)/\(name).json"
        )
        return try Data(contentsOf: url)
    }

    /// The packaged MSL text the app and the parity gate both compile (ADR-0008).
    static var shaderSource: String {
        get throws {
            try ShaderResource.source()
        }
    }

    /// The 2560 px SDR base the M2.1 server serves for the trial image, when the local
    /// (gitignored) work tree has it. `PHOTON_M3_BASE_PNG` overrides the default path.
    static var workBasePNGURL: URL? {
        if let override = ProcessInfo.processInfo.environment["PHOTON_M3_BASE_PNG"] {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let url = repositoryRoot.appendingPathComponent("work/m21-final/preview-base.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func loadWorkBasePNG() throws -> Data? {
        guard let url = workBasePNGURL else { return nil }
        return try Data(contentsOf: url)
    }

    // MARK: - Colour spaces

    static func displayP3ColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.displayP3)!
    }

    static func linearDisplayP3ColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    }

    // MARK: - PNG fixtures

    /// Builds a 16-bit Display P3 PNG with no alpha from *encoded* (0...65535) RGB samples.
    ///
    /// The byte order is pinned to little-endian 16-bit so the samples survive the
    /// `CGBitmapContext` round trip (a big-endian context byte-swaps them).
    static func make16BitDisplayP3PNG(
        width: Int,
        height: Int,
        encodedRGB: (Int, Int) -> (r: UInt16, g: UInt16, b: UInt16)
    ) throws -> Data {
        var samples = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let rgb = encodedRGB(x, y)
                samples[index] = rgb.r
                samples[index + 1] = rgb.g
                samples[index + 2] = rgb.b
                samples[index + 3] = UInt16.max
            }
        }
        let image: CGImage = try samples.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 8,
                space: displayP3ColorSpace(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            )
            guard let context, let image = context.makeImage() else {
                throw TestSupportError.cannotCreateImage
            }
            return image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestSupportError.cannotCreateImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestSupportError.cannotCreateImage
        }
        return data as Data
    }

    /// A uniform synthetic base buffer in linear extended Display P3.
    static func makeLinearImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> RGBA
    ) -> LinearImage {
        var samples = [Float](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = pixel(x, y)
                let index = (y * width + x) * 4
                samples[index] = value.r
                samples[index + 1] = value.g
                samples[index + 2] = value.b
                samples[index + 3] = value.a
            }
        }
        return try! LinearImage(size: PixelSize(width: width, height: height), pixels: samples)
    }

    // MARK: - Metal

    /// The Mac GPU. Throws (and therefore fails the test) when the host has no Metal device:
    /// the parity gate must never turn a missing GPU into a green run (ADR-0008).
    static func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSupportError.noMetalDevice
        }
        return device
    }

    /// Compiles the packaged MSL resource with the runtime Metal compiler — the same
    /// `ShaderResource` bytes and the same `makeLibrary(source:)` path the app takes.
    static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = try shaderSource
        if let url = shaderURL {
            print("PARITY shader path=\(url.path) bytes=\(source.utf8.count)")
        }
        return try device.makeLibrary(source: source, options: nil)
    }
}

enum TestSupportError: Error {
    case cannotCreateImage
    case noMetalDevice
}
