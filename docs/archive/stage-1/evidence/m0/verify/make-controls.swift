//
//  make-controls.swift — self-test fixtures for tools/verify-heic.
//
//  Writes plain SDR HEICs (no gain map) plus the SDR base TIFFs used to
//  exercise verify-heic's negative path, the base-preservation check and the
//  alpha-difference path. Everything lands in the directory passed as argv[1]
//  (default: work/m0/verify/out).
//
//  Build: export TMPDIR="$PWD/.tmp"; swiftc -module-cache-path "$PWD/.mc" -O make-controls.swift -o make-controls
//

import Foundation
import ImageIO
import CoreGraphics
import CoreImage

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "work/m0/verify/out"
let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
let linearDisplayP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let width = 320
let height = 200

func checkerImage(withAlpha: Bool) -> CGImage {
    let bytesPerRow = width * 4
    let alphaInfo: CGImageAlphaInfo = withAlpha ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: displayP3,
                                  bitmapInfo: alphaInfo.rawValue) else {
        fatalError("cannot create CGContext")
    }
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let u = Double(x) / Double(width - 1)
            let v = Double(y) / Double(height - 1)
            var r = 0.08 + 0.84 * u
            var g = 0.15 + 0.70 * v
            var b = 0.90 - 0.60 * u * v
            if x > width * 7 / 10 && y > height * 6 / 10 {
                (r, g, b) = (0.98, 0.92, 0.85)
            }
            if x < width / 6 && y > height * 4 / 5 {
                (r, g, b) = (0.03, 0.03, 0.04)
            }
            var a = 1.0
            if withAlpha {
                if x < width / 3 { a = 0.5 }
                if x > width * 2 / 3 && y < height / 3 { a = 0.0 }
            }
            let offset = y * bytesPerRow + x * 4
            pixels[offset + 0] = UInt8(max(0, min(255, (r * a * 255.0).rounded())))
            pixels[offset + 1] = UInt8(max(0, min(255, (g * a * 255.0).rounded())))
            pixels[offset + 2] = UInt8(max(0, min(255, (b * a * 255.0).rounded())))
            pixels[offset + 3] = UInt8(max(0, min(255, (a * 255.0).rounded())))
        }
    }
    guard let image = context.makeImage() else { fatalError("cannot make CGImage") }
    return image
}

func writeImage(_ image: CGImage, to url: URL, type: String, quality: Double?) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
        fatalError("cannot create CGImageDestination for \(url.path)")
    }
    var properties: [CFString: Any] = [:]
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("cannot finalize \(url.path)")
    }
}

func writeHEICFromCI(_ image: CIImage, to url: URL, options: [CIImageRepresentationOption: Any]) {
    let context = CIContext(options: [.workingColorSpace: linearDisplayP3,
                                     .outputColorSpace: linearDisplayP3,
                                     .cacheIntermediates: false])
    do {
        try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8,
                                            colorSpace: displayP3, options: options)
    } catch {
        fatalError("CI HEIF write failed for \(url.path): \(error)")
    }
}

func writeTIFFFromCI(_ image: CIImage, to url: URL) {
    let context = CIContext(options: [.workingColorSpace: linearDisplayP3,
                                     .outputColorSpace: linearDisplayP3,
                                     .cacheIntermediates: false])
    do {
        try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16,
                                            colorSpace: displayP3, options: [:])
    } catch {
        fatalError("CI TIFF write failed for \(url.path): \(error)")
    }
}

// 1. Plain SDR P3 HEIC, no alpha, no gain map: the primary negative control.
let opaque = checkerImage(withAlpha: false)
let sdrHEIC = outURL.appendingPathComponent("sdr-p3.heic")
writeImage(opaque, to: sdrHEIC, type: "public.heic", quality: 0.9)

// 2. Plain SDR P3 HEIC with an alpha channel: exercises alpha handling.
let alpha = checkerImage(withAlpha: true)
let alphaHEIC = outURL.appendingPathComponent("sdr-p3-alpha.heic")
writeImage(alpha, to: alphaHEIC, type: "public.heic", quality: 0.9)

// 3. 16-bit Display P3 TIFF of the same checker content: non-uniform base check.
let checkerCI = CIImage(cgImage: opaque)
let checkerTIFF = outURL.appendingPathComponent("checker-base.tif")
writeTIFFFromCI(checkerCI, to: checkerTIFF)

// 4. Uniform mid-grey base + matching plain SDR HEIC: strict uniform-base check
//    (decoded base variance must be exactly 0; this is the encoder's -b
//    contract). Both files are written from the same 8-bit P3 CGImage so any
//    difference is the HEVC codec, not a colour-pipeline mismatch.
func uniformImage(_ value: UInt8) -> CGImage {
    let bytesPerRow = width * 4
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: displayP3,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("cannot create uniform CGContext")
    }
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for offset in stride(from: 0, to: bytesPerRow * height, by: 4) {
        pixels[offset + 0] = value
        pixels[offset + 1] = value
        pixels[offset + 2] = value
        pixels[offset + 3] = 255
    }
    return context.makeImage()!
}

let uniform = uniformImage(128)
let greyTIFF = outURL.appendingPathComponent("uniform-base.tif")
writeImage(uniform, to: greyTIFF, type: "public.tiff", quality: nil)
let greyHEIC = outURL.appendingPathComponent("uniform-sdr.heic")
writeImage(uniform, to: greyHEIC, type: "public.heic", quality: 1.0)

let files = [sdrHEIC, alphaHEIC, checkerTIFF, greyTIFF, greyHEIC]
print("wrote controls to \(outURL.path):")
for file in files {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: file.path)) ?? [:]
    let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
    print("  \(file.lastPathComponent)  \(size) bytes")
}
