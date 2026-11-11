// make_pair.swift — deterministic synthetic base+HDR pair for M0 gain-map verification.
//
// base.tif : 1024x768, 16-bit, tagged Display P3, uniform linear 0.5 grey.
// hdr.tif  : 1024x768, 32-bit float, extended linear Display P3, horizontal ramp
//            linear 0.02 (left) -> 4.00 (right edge). Authored peak = 4.0 linear.
//
// Run:  export TMPDIR="$PWD/.tmp"; swift -module-cache-path "$PWD/.mc" make_pair.swift [outdir]
// Exits non-zero if read-back checks fail (float/HDR values did not survive).

import Foundation
import CoreImage
import ImageIO
import CoreGraphics

let outDir: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}()
let baseURL = outDir.appendingPathComponent("base.tif")
let hdrURL = outDir.appendingPathComponent("hdr.tif")

let W = 1024
let H = 768
let rect = CGRect(x: 0, y: 0, width: W, height: H)

let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctx = CIContext(options: [
    .workingColorSpace: linP3,
    .outputColorSpace: linP3,
    .cacheIntermediates: false,
])

// MARK: - Authoring

// Base: uniform linear 0.5 in extended linear P3, encoded to 16-bit gamma P3 TIFF.
let grey = CIImage(
    color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0, colorSpace: linP3)!
).cropped(to: rect)

// HDR: horizontal linear ramp 0.02 -> 4.0 in extended linear P3.
let gradient = CIFilter(name: "CILinearGradient", parameters: [
    "inputPoint0": CIVector(x: 0, y: 0),
    "inputPoint1": CIVector(x: CGFloat(W), y: 0),
    "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1.0, colorSpace: linP3)!,
    "inputColor1": CIColor(red: 4.00, green: 4.00, blue: 4.00, alpha: 1.0, colorSpace: linP3)!,
])!.outputImage!.cropped(to: rect)

print("-- writing base.tif  (RGBA16, Display P3, uniform linear 0.5, \(W)x\(H))")
try ctx.writeTIFFRepresentation(of: grey, to: baseURL, format: .RGBA16, colorSpace: p3, options: [:])
print("-- writing hdr.tif   (RGBAf, extendedLinearDisplayP3, ramp 0.02..4.00 linear, \(W)x\(H))")
try ctx.writeTIFFRepresentation(of: gradient, to: hdrURL, format: .RGBAf, colorSpace: linP3, options: [:])

// MARK: - Read-back verification

var failures: [String] = []

func renderRGBAf(_ image: CIImage) -> [Float] {
    let w = Int(image.extent.width)
    let h = Int(image.extent.height)
    var buf = [Float](repeating: .nan, count: w * h * 4)
    ctx.render(image, toBitmap: &buf, rowBytes: w * MemoryLayout<Float>.size * 4,
               bounds: image.extent, format: .RGBAf, colorSpace: linP3)
    return buf
}

func describeTIFF(_ url: URL) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        failures.append("cannot open \(url.lastPathComponent)"); return
    }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    print("  \(url.lastPathComponent): bytes=\(((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1)",
          "size=\(props[kCGImagePropertyPixelWidth] ?? "?")x\(props[kCGImagePropertyPixelHeight] ?? "?")",
          "depth=\(props[kCGImagePropertyDepth] ?? "?")",
          "profile=\(props[kCGImagePropertyProfileName] ?? "nil")",
          "colorModel=\(props[kCGImagePropertyColorModel] ?? "?")")
    if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        print("    CGImage bps=\(img.bitsPerComponent) bpp=\(img.bitsPerPixel) cs=\(img.colorSpace?.name as Any)")
    }
}

print("-- read-back")
describeTIFF(baseURL)
describeTIFF(hdrURL)

// Base read-back: must be spatially uniform (variance ~0) and linear ~0.5.
guard let baseSrc = CGImageSourceCreateWithURL(baseURL as CFURL, nil),
      let baseImg = CGImageSourceCreateImageAtIndex(baseSrc, 0, nil) else {
    fatalError("base.tif unreadable")
}
let baseCI = CIImage(cgImage: baseImg)
let baseBuf = renderRGBAf(baseCI)
func stats(_ buf: [Float], channels: Int) -> [(mean: Double, min: Double, max: Double, var: Double)] {
    let n = buf.count / 4
    return (0..<channels).map { c in
        var sum = 0.0, sum2 = 0.0, mn = Double.infinity, mx = -Double.infinity
        for i in 0..<n {
            let v = Double(buf[i * 4 + c])
            sum += v; sum2 += v * v
            if v < mn { mn = v }
            if v > mx { mx = v }
        }
        let m = sum / Double(n)
        let variance = sum2 / Double(n) - m * m
        return (m, mn, mx, variance)
    }
}
let bStats = stats(baseBuf, channels: 3)
print("  base decoded linear P3 RGB stats:")
for (c, s) in bStats.enumerated() {
    print(String(format: "    ch%d mean=%.6f min=%.6f max=%.6f var=%.3e", c, s.mean, s.min, s.max, s.var))
    if s.var > 1e-12 || abs(s.mean - 0.5) > 2e-3 || s.max - s.min > 2e-3 {
        failures.append("base ch\(c) not uniform linear 0.5 (mean \(s.mean), var \(s.var))")
    }
}

// HDR read-back: peak at right edge must be > 3.9; ramp monotonic-ish.
let hdrOpts: [CIImageOption: Any] = [.expandToHDR: true]
guard let hdrCI = CIImage(contentsOf: hdrURL, options: hdrOpts) else { fatalError("hdr.tif unreadable") }
print("  hdr CIImage extent=\(hdrCI.extent) cs=\(hdrCI.colorSpace?.name as Any)")
let hdrBuf = renderRGBAf(hdrCI)
let hW = Int(hdrCI.extent.width)
let hH = Int(hdrCI.extent.height)
func hdrPixel(_ x: Int, _ y: Int) -> [Float] {
    let i = (y * hW + x) * 4
    return Array(hdrBuf[i..<(i + 3)])
}
var maxR: Float = -1, minR: Float = .infinity
for y in 0..<hH { for x in 0..<hW {
    let v = hdrBuf[(y * hW + x) * 4]
    if v > maxR { maxR = v }
    if v < minR { minR = v }
}}
let left = hdrPixel(0, hH / 2)
let right = hdrPixel(hW - 1, hH / 2)
print(String(format: "  hdr linear P3: min=%.5f peak=%.5f  left(x=0)=%.5f  right(x=%d)=%.5f",
             minR, maxR, left[0], hW - 1, right[0]))
for frac in [0.25, 0.5, 0.75] {
    let x = Int(Double(hW) * frac)
    print(String(format: "    x=%4d (%.2f): %.5f", x, frac, hdrPixel(x, hH / 2)[0]))
}
if maxR <= 3.9 {
    failures.append(String(format: "hdr peak %.5f did not survive (>3.9 required)", maxR))
}
if abs(right[0] - 4.0) > 0.2 {
    failures.append("hdr right edge \(right[0]) not ~4.0")
}
// 32-bit float check: TIFF depth/props should say 32.
let hdrProps = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(hdrURL as CFURL, nil)!, 0, nil) as? [CFString: Any] ?? [:]
if let depth = hdrProps[kCGImagePropertyDepth] as? Int, depth != 32 {
    failures.append("hdr.tif depth reported \(depth), expected 32")
}
// Determinism: same input always produces same bytes (no time/random in authoring).

if failures.isEmpty {
    print("OK: pair written and verified (peak \(maxR) > 3.9; base uniform linear 0.5).")
    exit(0)
} else {
    print("FAIL:")
    for f in failures { print("  - \(f)") }
    exit(1)
}
