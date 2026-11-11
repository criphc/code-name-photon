// probe.swift — authoritative ImageIO/container fact extractor for the M0 synthetic encoder matrix.
//
// For each output HEIC in <root>/out-*/hdr.heic plus the supplied base.tif / hdr.tif pair it reports:
//   * ftyp major brand + compatible brands (parsed from raw bytes), file size, sha256
//   * plain (SDR) decode: dims, bps, bpp, alpha, colour space/profile, contentHeadroom
//   * ISO 21496-1 gain map aux: presence, data description, colour space, HDRToneMap metadata tags
//   * Apple HDR gain map aux presence (control)
//   * kCGImageSourceDecodeToHDR decode: success, bps/bpp, colour space, contentHeadroom
//   * decoded HDR pixel peak / sample profile vs the authored hdr.tif ramp
//   * base preservation: HEIC SDR base vs supplied base.tif rendered to 8-bit Display P3,
//     per-channel meanAbsDiff / maxAbsDiff, and spatial variance of the uniform decoded base
//   * raw heif-info / heif-info -d / exiftool -a -G1 / xxd -l 64 text for provenance
//
// Run:  cd work/m0/synthetic
//       export TMPDIR="$PWD/.tmp"; swift -module-cache-path "$PWD/.mc" probe.swift > logs/probe.txt
// Writes logs/probe.json (full raw facts, JSON) and prints a human summary.

import Foundation
import CoreImage
import ImageIO
import CoreGraphics
import CryptoKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let logsDir = root.appendingPathComponent("logs", isDirectory: true)
try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

let W = 1024
let H = 768
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctxLin = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])

// MARK: - Small helpers

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func be32(_ d: Data, _ o: Int) -> Int {
    (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3])
}

func fourCC(_ v: Int) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "?"
}

func parseFTYP(_ data: Data) -> [String: Any] {
    guard data.count >= 16 else { return ["error": "too short"] }
    guard be32(data, 4) == be32(Data("ftyp".utf8), 0) else { return ["error": "no ftyp at offset 4"] }
    let size = be32(data, 0)
    let major = String(bytes: data[8..<12], encoding: .ascii) ?? "?"
    let minor = be32(data, 12)
    var compatible: [String] = []
    var o = 16
    let limit = min(size, data.count)
    while o + 4 <= limit {
        compatible.append(String(bytes: data[o..<o + 4], encoding: .ascii) ?? "?")
        o += 4
    }
    return ["boxSize": size, "majorBrand": major, "minorVersion": minor, "compatibleBrands": compatible]
}

func runTool(_ path: String, _ args: [String]) -> String {
    guard FileManager.default.isExecutableFile(atPath: path) else { return "MISSING: \(path)" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "ERROR: \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return "exit=\(p.terminationStatus)\n" + (String(data: data, encoding: .utf8) ?? "")
}

func jsonSafe(_ v: Any) -> Any {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n
    case let b as Bool: return b
    default: return String(describing: v)
    }
}

// MARK: - CGImageMetadata flattening

func flattenTag(_ tag: CGImageMetadataTag, path: String, into dict: inout [String: Any]) {
    let name = (CGImageMetadataTagCopyName(tag) as String?) ?? "?"
    let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
    let key = prefix.isEmpty ? name : "\(prefix):\(name)"
    let full = path.isEmpty ? key : "\(path).\(key)"
    guard let value = CGImageMetadataTagCopyValue(tag) else { return }
    let typeID = CFGetTypeID(value)

    if typeID == CFArrayGetTypeID() {
        let arr = value as! CFArray
        let n = CFArrayGetCount(arr)
        for i in 0..<n {
            let itemPtr = CFArrayGetValueAtIndex(arr, i)!
            let item = unsafeBitCast(itemPtr, to: CFTypeRef.self)
            if CFGetTypeID(item) == CGImageMetadataTagGetTypeID() {
                flattenTag(unsafeBitCast(item, to: CGImageMetadataTag.self), path: "\(full)[\(i)]", into: &dict)
            } else {
                dict["\(full)[\(i)]"] = jsonSafe(item)
            }
        }
        return
    }
    if typeID == CFDictionaryGetTypeID() {
        let d = unsafeBitCast(value, to: CFDictionary.self)
        let count = CFDictionaryGetCount(d)
        var keys = [UnsafeRawPointer?](repeating: nil, count: count)
        var vals = [UnsafeRawPointer?](repeating: nil, count: count)
        CFDictionaryGetKeysAndValues(d, &keys, &vals)
        for i in 0..<count {
            let k = unsafeBitCast(keys[i]!, to: CFTypeRef.self)
            let v = unsafeBitCast(vals[i]!, to: CFTypeRef.self)
            let keyStr = jsonSafe(k)
            let childPath = "\(full).\(keyStr)"
            if CFGetTypeID(v) == CGImageMetadataTagGetTypeID() {
                flattenTag(unsafeBitCast(v, to: CGImageMetadataTag.self), path: full, into: &dict)
            } else {
                dict[childPath] = jsonSafe(v)
            }
        }
        return
    }
    dict[full] = jsonSafe(value)
}

func metadataFacts(_ mdRaw: Any) -> [String: Any] {
    let cf = mdRaw as CFTypeRef
    guard CFGetTypeID(cf) == CGImageMetadataGetTypeID() else {
        return ["parsed": false, "raw": String(describing: mdRaw)]
    }
    let meta = unsafeBitCast(cf, to: CGImageMetadata.self)
    var flat: [String: Any] = [:]
    let tags = (CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag]) ?? []
    for t in tags { flattenTag(t, path: "", into: &flat) }
    return ["parsed": true, "tags": flat, "tagCount": tags.count]
}

func firstDouble(_ flat: [String: Any], suffix: String) -> Double? {
    for (k, v) in flat where k.hasSuffix(suffix) {
        if let d = Double("\(v)") { return d }
    }
    return nil
}

func firstString(_ flat: [String: Any], suffix: String) -> String? {
    for (k, v) in flat where k.hasSuffix(suffix) {
        return "\(v)"
    }
    return nil
}

// MARK: - Image rendering helpers

func renderRGBA8(_ img: CGImage, width: Int, height: Int, cs: CGColorSpace) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { ptr in
        guard let cg = CGContext(data: ptr.baseAddress, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        cg.interpolationQuality = .none
        cg.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return data
}

func renderRGBAf(_ ci: CIImage, width: Int, height: Int) -> [Float] {
    var buf = [Float](repeating: .nan, count: width * height * 4)
    ctxLin.render(ci, toBitmap: &buf, rowBytes: width * MemoryLayout<Float>.size * 4,
                  bounds: CGRect(x: 0, y: 0, width: width, height: height),
                  format: .RGBAf, colorSpace: linP3)
    return buf
}

func channelStats(_ buf: [UInt8], width: Int, height: Int) -> [[String: Any]] {
    let n = width * height
    return (0..<3).map { c in
        var sum = 0.0, sum2 = 0.0
        var mn = Double.infinity, mx = -Double.infinity
        for i in 0..<n {
            let v = Double(buf[i * 4 + c])
            sum += v; sum2 += v * v
            if v < mn { mn = v }
            if v > mx { mx = v }
        }
        let mean = sum / Double(n)
        let variance = sum2 / Double(n) - mean * mean
        return ["mean": mean, "min": mn, "max": mx, "variance": variance]
    }
}

func diffStats(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> [[String: Any]] {
    let n = width * height
    return (0..<3).map { c in
        var sum = 0.0
        var mx = 0.0
        var count = 0
        for i in 0..<n {
            let d = abs(Double(a[i * 4 + c]) - Double(b[i * 4 + c]))
            sum += d
            if d > mx { mx = d }
            if d > 0.5 { count += 1 }
        }
        return ["meanAbsDiff": sum / Double(n), "maxAbsDiff": mx,
                "pixelsDiffering": count, "fractionDiffering": Double(count) / Double(n)]
    }
}

// MARK: - Pair facts (inputs)

let baseURL = root.appendingPathComponent("base.tif")
let hdrURL = root.appendingPathComponent("hdr.tif")
let baseData = (try? Data(contentsOf: baseURL)) ?? Data()
let hdrData = (try? Data(contentsOf: hdrURL)) ?? Data()

func tiffFacts(_ url: URL, data: Data) -> [String: Any] {
    var out: [String: Any] = ["path": url.lastPathComponent, "bytes": data.count, "sha256": sha256(data)]
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        out["pixelWidth"] = props[kCGImagePropertyPixelWidth] ?? 0
        out["pixelHeight"] = props[kCGImagePropertyPixelHeight] ?? 0
        out["depth"] = props[kCGImagePropertyDepth] ?? 0
        out["profileName"] = props[kCGImagePropertyProfileName] ?? "nil"
        out["colorModel"] = props[kCGImagePropertyColorModel] ?? "nil"
        if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            out["cgBps"] = img.bitsPerComponent
            out["cgBpp"] = img.bitsPerPixel
            out["cgColorSpace"] = img.colorSpace?.name as String? ?? "nil"
        }
    }
    return out
}

let baseFacts = tiffFacts(baseURL, data: baseData)
let hdrFacts = tiffFacts(hdrURL, data: hdrData)

// Base.tif decoded to linear P3 (uniformity) and to 8-bit P3 (reference for preservation diff).
var baseTIFFDecodedLinear: [[String: Any]] = []
var baseTIFFDecoded8: [UInt8] = []
if let src = CGImageSourceCreateWithURL(baseURL as CFURL, nil),
   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
    let lin = renderRGBAf(CIImage(cgImage: img), width: W, height: H)
    baseTIFFDecodedLinear = (0..<3).map { c in
        var sum = 0.0, sum2 = 0.0, mn = Double.infinity, mx = -Double.infinity
        let n = W * H
        for i in 0..<n {
            let v = Double(lin[i * 4 + c])
            sum += v; sum2 += v * v
            if v < mn { mn = v }
            if v > mx { mx = v }
        }
        let mean = sum / Double(n)
        return ["mean": mean, "min": mn, "max": mx, "variance": sum2 / Double(n) - mean * mean]
    }
    baseTIFFDecoded8 = renderRGBA8(img, width: W, height: H, cs: p3)
}
let baseTIFFDecoded8Stats = channelStats(baseTIFFDecoded8, width: W, height: H)

// Authoring intent constants (verified by make_pair.swift read-back).
let authoredPeakRequested: Double = 4.0

// HDR.tif authored values in linear P3, rendered fully.
var hdrAuthoredLinear: [Float] = []
var hdrAuthoredPeak: Double = Double.nan
if let ci = CIImage(contentsOf: hdrURL, options: [.expandToHDR: true]) {
    hdrAuthoredLinear = renderRGBAf(ci, width: W, height: H)
    var mx: Float = -1
    for i in 0..<(W * H) { mx = max(mx, hdrAuthoredLinear[i * 4]) }
    hdrAuthoredPeak = Double(mx)
}

// MARK: - Run table

struct RunSpec {
    let name: String
    let headroomArg: String        // -R argument used ("—" = none)
    let base: Bool                 // -b <base.tif>
    let halfMap: Bool              // -H
    let command: String
}

let runs: [RunSpec] = [
    RunSpec(name: "out-b-r25", headroomArg: "2.5", base: true, halfMap: false,
            command: "toGainMapHDR hdr.tif out-b-r25 -b base.tif -R 2.5 -d 8 -q 0.85 -c p3"),
    RunSpec(name: "out-b-r15", headroomArg: "1.5", base: true, halfMap: false,
            command: "toGainMapHDR hdr.tif out-b-r15 -b base.tif -R 1.5 -d 8 -q 0.85 -c p3"),
    RunSpec(name: "out-b-r6", headroomArg: "6", base: true, halfMap: false,
            command: "toGainMapHDR hdr.tif out-b-r6 -b base.tif -R 6 -d 8 -q 0.85 -c p3"),
    RunSpec(name: "out-nob-r25", headroomArg: "2.5", base: false, halfMap: false,
            command: "toGainMapHDR hdr.tif out-nob-r25 -R 2.5 -d 8 -q 0.85 -c p3"),
    RunSpec(name: "out-b-r25-H", headroomArg: "2.5", base: true, halfMap: true,
            command: "toGainMapHDR hdr.tif out-b-r25-H -b base.tif -R 2.5 -d 8 -q 0.85 -c p3 -H"),
]

var runResults: [[String: Any]] = []

for spec in runs {
    let dir = root.appendingPathComponent(spec.name, isDirectory: true)
    let heicURL = dir.appendingPathComponent("hdr.heic")
    print("\n=== \(spec.name)  (\(spec.command)) ===")
    guard let data = try? Data(contentsOf: heicURL), let src = CGImageSourceCreateWithURL(heicURL as CFURL, nil) else {
        print("  MISSING \(heicURL.path)")
        runResults.append(["name": spec.name, "error": "missing output"])
        continue
    }

    var r: [String: Any] = [:]
    r["name"] = spec.name
    r["relativePath"] = "\(spec.name)/hdr.heic"
    r["command"] = spec.command
    r["headroomArg"] = spec.headroomArg
    r["usesBase"] = spec.base
    r["halfSizeMap"] = spec.halfMap
    r["file"] = ["bytes": data.count, "sha256": sha256(data), "ftyp": parseFTYP(data)]

    // ---- plain SDR decode
    var sdrFacts: [String: Any] = [:]
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        sdrFacts["profileName"] = props[kCGImagePropertyProfileName] ?? "nil"
        sdrFacts["depthProperty"] = props[kCGImagePropertyDepth] ?? 0
        if let aux = props[kCGImagePropertyAuxiliaryData] as? [[CFString: Any]] {
            sdrFacts["auxiliaryDataProperties"] = aux.map { a -> [String: Any] in
                ["type": "\(a[kCGImagePropertyAuxiliaryDataType] ?? "?")",
                 "keys": a.keys.map { $0 as String }.sorted()]
            }
        } else {
            sdrFacts["auxiliaryDataProperties"] = "none"
        }
    }
    var sdrImg: CGImage?
    if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        sdrImg = img
        sdrFacts["width"] = img.width
        sdrFacts["height"] = img.height
        sdrFacts["bitsPerComponent"] = img.bitsPerComponent
        sdrFacts["bitsPerPixel"] = img.bitsPerPixel
        sdrFacts["alphaInfoRaw"] = img.alphaInfo.rawValue
        sdrFacts["hasAlpha"] = !(img.alphaInfo == .none || img.alphaInfo == .noneSkipFirst || img.alphaInfo == .noneSkipLast)
        sdrFacts["colorSpaceName"] = img.colorSpace?.name as String? ?? "nil"
        sdrFacts["contentHeadroom"] = Double(img.contentHeadroom)
        sdrFacts["calculatedContentHeadroom"] = Double(img.calculatedContentHeadroom)
    }
    r["plainDecode"] = sdrFacts

    // ---- ISO gain map aux
    var isoAux: [String: Any] = ["present": false]
    if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any] {
        isoAux["present"] = true
        isoAux["keys"] = info.keys.map { $0 as String }.sorted()
        if let desc = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] {
            var d: [String: Any] = [:]
            for (k, v) in desc { d[k as String] = jsonSafe(v) }
            if let pf = desc["PixelFormat" as CFString] as? Int {
                d["PixelFormatFourCC"] = fourCC(pf)
            }
            isoAux["dataDescription"] = d
        }
        if let cs = info[kCGImageAuxiliaryDataInfoColorSpace] {
            isoAux["colorSpace"] = String(describing: cs)
        }
        if let d = info[kCGImageAuxiliaryDataInfoData] as? Data {
            isoAux["dataBytes"] = d.count
        }
        if let md = info[kCGImageAuxiliaryDataInfoMetadata] {
            isoAux["metadata"] = metadataFacts(md)
            if let m = isoAux["metadata"] as? [String: Any], let tags = m["tags"] as? [String: Any] {
                var curated: [String: Any] = [:]
                curated["version"] = firstDouble(tags, suffix: "Version")
                curated["baseHeadroom"] = firstDouble(tags, suffix: "BaseHeadroom")
                curated["alternateHeadroom"] = firstDouble(tags, suffix: "AlternateHeadroom")
                curated["baseColorIsWorkingColor"] = firstString(tags, suffix: "BaseColorIsWorkingColor")
                var channels: [[String: Any]] = []
                let maxKeys = tags.keys.filter { $0.hasSuffix("GainMapMax") }.sorted()
                for k in maxKeys {
                    let prefix = k.replacingOccurrences(of: "GainMapMax", with: "")
                    var ch: [String: Any] = ["index": prefix]
                    ch["gainMapMax"] = Double("\(tags[k] ?? "")")
                    for field in ["GainMapMin", "Gamma", "BaseOffset", "AlternateOffset"] {
                        if let v = tags["\(prefix)\(field)"] { ch[field] = Double("\(v)") }
                    }
                    channels.append(ch)
                }
                curated["channels"] = channels
                isoAux["hdrToneMap"] = curated
            }
        }
    }
    r["isoGainMapAux"] = isoAux

    // ---- Apple aux (must be absent for the ISO dialect)
    var appleAux: [String: Any] = ["present": false]
    if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [CFString: Any] {
        appleAux["present"] = true
        appleAux["keys"] = info.keys.map { $0 as String }.sorted()
        if let desc = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] {
            appleAux["dataDescription"] = desc.reduce(into: [String: Any]()) { $0[$1.key as String] = jsonSafe($1.value) }
        }
    }
    r["appleGainMapAux"] = appleAux

    // ---- DecodeToHDR
    var hdrFacts: [String: Any] = [:]
    let decodeOpts: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
    if let hdr = CGImageSourceCreateImageAtIndex(src, 0, decodeOpts as CFDictionary) {
        hdrFacts["success"] = true
        hdrFacts["width"] = hdr.width
        hdrFacts["height"] = hdr.height
        hdrFacts["bitsPerComponent"] = hdr.bitsPerComponent
        hdrFacts["bitsPerPixel"] = hdr.bitsPerPixel
        hdrFacts["alphaInfoRaw"] = hdr.alphaInfo.rawValue
        hdrFacts["hasAlpha"] = !(hdr.alphaInfo == .none || hdr.alphaInfo == .noneSkipFirst || hdr.alphaInfo == .noneSkipLast)
        hdrFacts["colorSpaceName"] = hdr.colorSpace?.name as String? ?? "nil"
        hdrFacts["contentHeadroom"] = Double(hdr.contentHeadroom)
        hdrFacts["calculatedContentHeadroom"] = Double(hdr.calculatedContentHeadroom)

        // sampled/profiled linear P3 values
        let lin = renderRGBAf(CIImage(cgImage: hdr), width: W, height: H)
        var peak: Float = -1
        for i in 0..<(W * H) { peak = max(peak, lin[i * 4]) }
        hdrFacts["decodedPeakLinearP3"] = Double(peak)
        var samples: [[String: Any]] = []
        for x in [0, 256, 512, 768, 1023] {
            let i = ((H / 2) * W + x) * 4
            let authored = Double(hdrAuthoredLinear[i])
            samples.append(["x": x,
                            "decodedLinearP3": Double(lin[i]),
                            "authoredLinearP3": authored,
                            "absDiff": abs(Double(lin[i]) - authored)])
        }
        hdrFacts["profileRow"] = samples
        // whole-image fidelity vs authored HDR rendition
        var sum = 0.0, mx = 0.0
        for i in 0..<(W * H) {
            let d = abs(Double(lin[i * 4]) - Double(hdrAuthoredLinear[i * 4]))
            sum += d
            if d > mx { mx = d }
        }
        hdrFacts["vsAuthoredHDR"] = ["meanAbsDiff": sum / Double(W * H), "maxAbsDiff": mx]
    } else {
        hdrFacts["success"] = false
    }
    r["decodeToHDR"] = hdrFacts

    // ---- Base preservation vs supplied base.tif (only meaningful for -b runs)
    if let sdr = sdrImg {
        let sdr8 = renderRGBA8(sdr, width: W, height: H, cs: p3)
        let sdrStats = channelStats(sdr8, width: W, height: H)
        r["decodedSDRBaseStats8bitP3"] = sdrStats
        if spec.base {
            let diffs = diffStats(sdr8, baseTIFFDecoded8, width: W, height: H)
            r["basePreservationVsBaseTIFF"] = ["applicable": true, "diff8bitP3": diffs]
        } else {
            r["basePreservationVsBaseTIFF"] = ["applicable": false,
                                              "reason": "no -b: tool generated and tone-mapped its own SDR base"]
        }
    }

    // ---- raw container/tool text
    r["heifInfo"] = runTool("/opt/homebrew/bin/heif-info", [heicURL.path])
    r["heifInfoDumpBoxes"] = runTool("/opt/homebrew/bin/heif-info", ["-d", heicURL.path])
    r["exiftool"] = runTool("/opt/homebrew/bin/exiftool", ["-a", "-G1", heicURL.path])
    r["xxdHead"] = runTool("/usr/bin/xxd", ["-l", "64", heicURL.path])

    runResults.append(r)

    // console summary
    let alt = (isoAux["hdrToneMap"] as? [String: Any])?["alternateHeadroom"] ?? "?"
    let ch = Double(hdrFacts["contentHeadroom"] as? Double ?? .nan)
    let peak = Double(hdrFacts["decodedPeakLinearP3"] as? Double ?? .nan)
    print(String(format: "  size=%d B  auxISO=%@  altHeadroom=%@  HDRcontentHeadroom=%.4f  decodedPeak=%.4f  sdrAlpha=%@",
                 data.count, isoAux["present"] as? Bool == true ? "yes" : "NO", "\(alt)", ch, peak,
                 "\(sdrFacts["hasAlpha"] ?? "?")"))
}

// MARK: - Emit JSON

let probe: [String: Any] = [
    "generatedBy": "work/m0/synthetic/probe.swift",
    "host": ProcessInfo.processInfo.operatingSystemVersionString,
    "inputs": [
        "baseTIFF": baseFacts,
        "hdrTIFF": hdrFacts,
        "authoredPeakRequested": authoredPeakRequested,
        "authoredPeakMeasured": hdrAuthoredPeak,
        "baseTIFFDecodedLinearP3Stats": baseTIFFDecodedLinear,
        "baseTIFFDecoded8bitP3Stats": baseTIFFDecoded8Stats,
    ],
    "runs": runResults,
]

let jsonURL = logsDir.appendingPathComponent("probe.json")
let jsonData = try JSONSerialization.data(withJSONObject: probe, options: [.prettyPrinted, .sortedKeys])
try jsonData.write(to: jsonURL)
print("\nwrote \(jsonURL.path) (\(jsonData.count) bytes)")
