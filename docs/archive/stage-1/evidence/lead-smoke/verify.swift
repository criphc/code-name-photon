import Foundation
import ImageIO
import CoreGraphics
import CoreImage

let path = "/Users/criphc/Sites/llm-photon/work/lead-smoke/out/hdr.heic"
let url = URL(fileURLWithPath: path)
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { fatalError("no src") }
let count = CGImageSourceGetCount(src)
print("count:", count)
print("type:", CGImageSourceGetType(src) as Any)
if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
  print("props keys:", props.keys.map { $0 as String }.sorted())
  print("profile:", props[kCGImagePropertyProfileName] as Any, "depth:", props[kCGImagePropertyDepth] as Any)
  if let aux = props[kCGImagePropertyAuxiliaryData] as? [[CFString: Any]] {
    for a in aux { print("aux:", a[kCGImagePropertyAuxiliaryDataType] as Any, "keys:", a.keys.map { $0 as String }) }
  } else { print("aux: none in properties") }
}
// plain SDR decode
if let sdr = CGImageSourceCreateImageAtIndex(src, 0, nil) {
  print("SDR decode:", sdr.width, "x", sdr.height, "bps", sdr.bitsPerComponent, "bpp", sdr.bitsPerPixel, "cs", sdr.colorSpace?.name as Any, "headroom", sdr.contentHeadroom, "calc", sdr.calculatedContentHeadroom)
}
// aux data info
for t in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
  if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, t) as? [CFString: Any] {
    print("aux info", t, "keys:", info.keys.map { $0 as String })
  } else { print("aux info", t, "= nil") }
}
// HDR decode
let opts: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
var err: NSError?
if let hdr = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
  print("HDR decode:", hdr.width, "x", hdr.height, "bps", hdr.bitsPerComponent, "bpp", hdr.bitsPerPixel, "cs", hdr.colorSpace?.name as Any, "headroom", hdr.contentHeadroom, "calc", hdr.calculatedContentHeadroom)
  // sample pixels via CIContext to linear P3
  let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  let ctx = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
  let ci = CIImage(cgImage: hdr)
  var buf = [Float](repeating: 0, count: 4)
  for x in [0, 64, 128, 192, 255] {
    ctx.render(ci, toBitmap: &buf, rowBytes: 16, bounds: CGRect(x: x, y: 64, width: 1, height: 1), format: .RGBAf, colorSpace: linP3)
    print("HDR px", x, buf)
  }
} else { print("HDR decode failed:", err as Any) }
// base comparison: decode base tif to linear P3 and compare with SDR decode of heic
