import Foundation
import ImageIO
let url = URL(fileURLWithPath: "/Users/criphc/Sites/llm-photon/work/lead-smoke/out/hdr.heic")
let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any] {
  print("keys:", info.keys.map { $0 as String })
  if let md = info[kCGImageAuxiliaryDataInfoMetadata] {
    print("metadata type:", type(of: md))
    print("metadata:", md)
    if let d = md as? [CFString: Any] {
      for (k,v) in d { print("  ", k, "=", v) }
    }
  }
  if let desc = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] { print("desc:", desc) }
  if let cs = info[kCGImageAuxiliaryDataInfoColorSpace] { print("cs:", cs) }
  if let data = info[kCGImageAuxiliaryDataInfoData] as? Data { print("data bytes:", data.count, "head:", data.prefix(16) as Any) }
}
// XMP / other metadata items
for t in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
  if let d = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any], let sub = d[t] { print(t, sub) }
}
