import Foundation
import CoreImage
import ImageIO
import CoreGraphics

let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctx = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])

let W = 256, H = 128
// base: uniform grey (linear 0.5) -> encoded in P3 gamma via color conversion
let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)!).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
// hdr: horizontal ramp 0.02 -> 4.0 linear (use a gradient CIImage with explicit linear color space)
print("-- writing base (uniform 0.5 linear, P3 gamma 16-bit)")
try! ctx.writeTIFFRepresentation(of: grey, to: URL(fileURLWithPath: "/Users/criphc/Sites/llm-photon/work/lead-smoke/base.tif"), format: .RGBA16, colorSpace: p3, options: [:])
// gradient via CILinearGradient needs colors in working linear space
let g = CIFilter(name: "CILinearGradient", parameters: [
  "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(W), y: 0),
  "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1, colorSpace: linP3)!,
  "inputColor1": CIColor(red: 4.0, green: 4.0, blue: 4.0, alpha: 1, colorSpace: linP3)!])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
print("-- writing hdr (linear ramp 0.02..4.0, extended linear P3 float32)")
try! ctx.writeTIFFRepresentation(of: g, to: URL(fileURLWithPath: "/Users/criphc/Sites/llm-photon/work/lead-smoke/hdr.tif"), format: .RGBAf, colorSpace: linP3, options: [:])
// readback checks
func readback(_ p: String) {
  guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { print("no img \(p)"); return }
  print(p, "bps:", img.bitsPerComponent, "bpp:", img.bitsPerPixel, "cs:", img.colorSpace?.name as Any)
  let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
  print("  profile:", (props[kCGImagePropertyProfileName] ?? "nil"))
  if let ci = CIImage(contentsOf: URL(fileURLWithPath: p), options: [.expandToHDR: true]) {
    print("  ci:", ci.extent, "cs:", ci.colorSpace?.name as Any)
    func px(_ x: Int) -> [Float] {
      var buf = [Float](repeating: 0, count: 4)
      ctx.render(ci, toBitmap: &buf, rowBytes: 16, bounds: CGRect(x: x, y: 64, width: 1, height: 1), format: .RGBAf, colorSpace: linP3)
      return buf
    }
    for x in [0, 64, 128, 192, 255] { print("  px", x, px(x)) }
  }
}
readback("/Users/criphc/Sites/llm-photon/work/lead-smoke/base.tif")
readback("/Users/criphc/Sites/llm-photon/work/lead-smoke/hdr.tif")
