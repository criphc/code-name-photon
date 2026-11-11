// render.swift — M0-C: SDR pass-through base + authored HDR rendition + gain-map HEIC encode.
//
// Deterministic command-line renderer for one Capture One Display-P3 TIFF.
//
// Base contract: c1_match_v1 == identity. The SDR base is written by re-containering the
// decoded source image (same 16-bit samples, same ICC profile) with zero colour conversion.
//
// HDR contract: mask = smoothstep(start .. start+transition) on Rec.709 luma of the linear
// Display-P3 working buffer; gain = 2^(lift_stops * mask); hdr = base_linear * gain; then an
// absolute clamp at headroom_cap (linear). Values between 1.0 and the cap are kept exactly.
//
// Build/run (from the repo root):
//   swiftc -O -o work/m0/real/.tmp/render work/m0/real/render.swift
//   work/m0/real/.tmp/render                       # defaults: samples/sources/R0003777-P3.tif -> work/m0/real
// or in interpreter mode (slower):
//   export TMPDIR="$PWD/work/m0/real/.tmp"; swift -module-cache-path work/m0/real/.mc work/m0/real/render.swift
//
// Modes:
//   render.swift [options]                 full render + encode + verify + stats.json + notes.md
//   render.swift verify <heic> [--outdir D] print gain-map metadata of an existing deliverable
//
// All paths default relative to the current working directory (the repo root).

import Foundation
import CoreImage
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Logging

var logLines: [String] = []
func log(_ s: String) {
    print(s)
    logLines.append(s)
}
func die(_ s: String) -> Never {
    log("FATAL: \(s)")
    writeLogFile()
    exit(1)
}
func writeLogFile() {
    let dir = URL(fileURLWithPath: outdir).appendingPathComponent("logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data(logLines.joined(separator: "\n").appending("\n").utf8).write(to: dir.appendingPathComponent("render.log"))
}

// MARK: - Defaults / options

var inputPath = "samples/sources/R0003777-P3.tif"
var outdir = "work/m0/real"
var startLuma: Float = 0.62
var liftStops: Float = 1.4
var transition: Float = 0.28
var headroomCap: Float = 2.5
var toolPath = "tools/toGainMapHDR/bin/toGainMapHDR"
var quality: Float = 0.85
var depth = 8
var colorSpaceFlag = "p3"
var previewLongEdge = 2560
var basename = "R0003777-M0"
var doRepeatEncode = true
var mode = "render"
var verifyTarget = ""

func failUsage(_ msg: String) -> Never {
    print("error: \(msg)")
    exit(2)
}

let argv = CommandLine.arguments
var ai = 1
if argv.count > 1 && !argv[1].hasPrefix("--") && argv[1] != "-" {
    mode = argv[1]
    ai = 2
    if mode == "verify" && argv.count > 2 && !argv[2].hasPrefix("--") {
        verifyTarget = argv[2]
        ai = 3
    }
}
while ai < argv.count {
    let a = argv[ai]
    func value() -> String {
        guard ai + 1 < argv.count else { failUsage("missing value for \(a)") }
        ai += 1
        return argv[ai]
    }
    switch a {
    case "--input": inputPath = value()
    case "--outdir": outdir = value()
    case "--start": startLuma = Float(value()) ?? { failUsage("bad --start") }()
    case "--lift-stops": liftStops = Float(value()) ?? { failUsage("bad --lift-stops") }()
    case "--transition": transition = Float(value()) ?? { failUsage("bad --transition") }()
    case "--cap": headroomCap = Float(value()) ?? { failUsage("bad --cap") }()
    case "--tool": toolPath = value()
    case "--quality": quality = Float(value()) ?? { failUsage("bad --quality") }()
    case "--depth": depth = Int(value()) ?? { failUsage("bad --depth") }()
    case "--color-space": colorSpaceFlag = value()
    case "--preview-long-edge": previewLongEdge = Int(value()) ?? { failUsage("bad --preview-long-edge") }()
    case "--basename": basename = value()
    case "--no-repeat-encode": doRepeatEncode = false
    case "-h", "--help":
        print("usage: render.swift [--input TIF] [--outdir DIR] [--start F] [--lift-stops F]")
        print("                   [--transition F] [--cap F] [--tool PATH] [--quality F] [--depth N]")
        print("                   [--color-space p3] [--preview-long-edge N] [--basename NAME]")
        print("                   [--no-repeat-encode]")
        print("       render.swift verify <heic> [--outdir DIR]")
        exit(0)
    default: failUsage("unknown option \(a)")
    }
    ai += 1
}

// MARK: - Small helpers

let fm = FileManager.default
let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
log("=== llm-photon M0-C render ===")
log("mode=\(mode) input=\(inputPath) outdir=\(outdir)")
log("recipe start=\(startLuma) lift_stops=\(liftStops) transition=\(transition) cap=\(headroomCap)")
log("encoder flags: -b -R \(headroomCap) -d \(depth) -q \(quality) -c \(colorSpaceFlag)")

func ensureDir(_ path: String) {
    try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
}
func fileSize(_ path: String) -> Int {
    (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? -1
}
func sha256File(_ path: String) -> String {
    guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
    var hasher = SHA256()
    while autoreleasepool(invoking: { () -> Bool in
        let chunk = fh.readData(ofLength: 8 * 1024 * 1024)
        if chunk.isEmpty { return false }
        hasher.update(data: chunk)
        return true
    }) {}
    fh.closeFile()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
func sha256Data(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
@discardableResult
func writeData(_ data: Data, to path: String) -> Int {
    do { try data.write(to: URL(fileURLWithPath: path)); return data.count }
    catch { die("cannot write \(path): \(error)") }
}
func writeJSON(_ obj: Any, to path: String) {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    } catch { die("json serialization failed: \(error)") }
    writeData(data + Data("\n".utf8), to: path)
}
struct ProcResult { var status: Int32; var output: String }
func runProcess(_ exe: String, _ args: [String]) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ProcResult(status: -1, output: "launch failed: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ProcResult(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
}
func shellQuote(_ s: String) -> String {
    if s.rangeOfCharacter(from: .whitespaces) == nil && !s.isEmpty { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
// Clean JSON number for a Float recipe value (avoids 0.6200000047683716 noise).
func d6(_ v: Float) -> Double { (Double(v) * 1_000_000).rounded() / 1_000_000 }

// 3-channel 16-bit CGImage (no alpha) from a packed RGB UInt16 buffer.
func rgb16CGImage(_ buf: [UInt16], _ w: Int, _ h: Int, _ cs: CGColorSpace) -> CGImage? {
    let data = Data(bytes: buf, count: buf.count * MemoryLayout<UInt16>.size)
    guard let dp = CGDataProvider(data: data as CFData) else { return nil }
    let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
    return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
                   space: cs, bitmapInfo: bi, provider: dp, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}
// 3-channel 8-bit CGImage (no alpha) from a packed RGB UInt8 buffer.
func rgb8CGImage(_ buf: [UInt8], _ w: Int, _ h: Int, _ cs: CGColorSpace) -> CGImage? {
    let data = Data(bytes: buf, count: buf.count)
    guard let dp = CGDataProvider(data: data as CFData) else { return nil }
    let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                   space: cs, bitmapInfo: bi, provider: dp, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

// MARK: - HEIC inspection (ImageIO)

struct AuxReport {
    var alternateHeadroomStops: Double? = nil
    var baseHeadroomStops: Double? = nil
    var gainMapMaxStops: [Double] = []
    var gainMapMinStops: [Double] = []
    var xmp: String = ""
    var auxKeys: [String] = []
}

func inspectHEIC(_ path: String, label: String, recordFiles: Bool) -> [String: Any] {
    var out: [String: Any] = [:]
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        log("\(label): cannot open \(path)")
        return out
    }
    out["type"] = (CGImageSourceGetType(src) as String?) ?? "?"
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        out["depth"] = props[kCGImagePropertyDepth] as? Int ?? -1
        out["profile"] = (props[kCGImagePropertyProfileName] as? String) ?? "?"
        var auxTypes: [String] = []
        if let aux = props[kCGImagePropertyAuxiliaryData] as? [[CFString: Any]] {
            for a in aux { auxTypes.append((a[kCGImagePropertyAuxiliaryDataType] as? String) ?? "?") }
        }
        out["aux_property_types"] = auxTypes
    }
    if let sdr = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        out["sdr"] = [
            "width": sdr.width, "height": sdr.height,
            "bits_per_component": sdr.bitsPerComponent, "bits_per_pixel": sdr.bitsPerPixel,
            "alpha_info_raw": sdr.alphaInfo.rawValue,
            "has_alpha_data": sdr.alphaInfo == .premultipliedLast || sdr.alphaInfo == .premultipliedFirst
                || sdr.alphaInfo == .last || sdr.alphaInfo == .first || sdr.alphaInfo == .alphaOnly,
            "colorspace": (sdr.colorSpace?.name as String?) ?? "nil",
            "content_headroom_linear": Double(sdr.contentHeadroom),
            "calculated_content_headroom": Double(sdr.calculatedContentHeadroom),
        ] as [String: Any]
    }
    let hdrOpts: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
    if let hdr = CGImageSourceCreateImageAtIndex(src, 0, hdrOpts as CFDictionary) {
        out["hdr"] = [
            "width": hdr.width, "height": hdr.height,
            "bits_per_component": hdr.bitsPerComponent, "bits_per_pixel": hdr.bitsPerPixel,
            "alpha_info_raw": hdr.alphaInfo.rawValue,
            "colorspace": (hdr.colorSpace?.name as String?) ?? "nil",
            "content_headroom_linear": Double(hdr.contentHeadroom),
            "calculated_content_headroom": Double(hdr.calculatedContentHeadroom),
        ] as [String: Any]
    } else {
        out["hdr"] = ["error": "DecodeToHDR failed"]
    }
    var auxRep = AuxReport()
    if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any] {
        auxRep.auxKeys = info.keys.map { $0 as String }
        if let md = info[kCGImageAuxiliaryDataInfoMetadata] {
            let cft = md as CFTypeRef
            if CFGetTypeID(cft) == CGImageMetadataGetTypeID() {
                let meta = (md as! CGImageMetadata)
                let xmpData = CGImageMetadataCreateXMPData(meta, nil)
                auxRep.xmp = xmpData.map { String(data: $0 as Data, encoding: .utf8) ?? "" } ?? ""
                func tag(_ p: String) -> Double? {
                    guard let t = CGImageMetadataCopyTagWithPath(meta, nil, p as CFString),
                          let v = CGImageMetadataTagCopyValue(t) else { return nil }
                    if let n = v as? NSNumber { return n.doubleValue }
                    return Double((v as? String) ?? "")
                }
                auxRep.alternateHeadroomStops = tag("HDRToneMap:AlternateHeadroom")
                auxRep.baseHeadroomStops = tag("HDRToneMap:BaseHeadroom")
                if !auxRep.xmp.isEmpty {
                    func allNumbers(after key: String) -> [Double] {
                        let pattern = "HDRToneMap:\(key)>([-0-9.eE+]+)<"
                        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
                        let ns = auxRep.xmp as NSString
                        return re.matches(in: auxRep.xmp, range: NSRange(location: 0, length: ns.length)).compactMap {
                            Double(ns.substring(with: $0.range(at: 1)))
                        }
                    }
                    auxRep.gainMapMaxStops = allNumbers(after: "GainMapMax")
                    auxRep.gainMapMinStops = allNumbers(after: "GainMapMin")
                }
            } else if let d = md as? [CFString: Any] {
                auxRep.xmp = String(describing: d)
            }
        }
        out["aux_present"] = true
    } else {
        out["aux_present"] = false
    }
    func r(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
    out["iso_aux"] = [
        "present": out["aux_present"] as? Bool ?? false,
        "keys": auxRep.auxKeys,
        "HDRToneMap_AlternateHeadroom_stops": r(auxRep.alternateHeadroomStops),
        "HDRToneMap_AlternateHeadroom_linear": r(auxRep.alternateHeadroomStops.map { pow(2.0, $0) }),
        "HDRToneMap_BaseHeadroom_stops": r(auxRep.baseHeadroomStops),
        "HDRToneMap_GainMapMax_stops_channels": auxRep.gainMapMaxStops,
        "HDRToneMap_GainMapMin_stops_channels": auxRep.gainMapMinStops,
    ] as [String: Any]
    if recordFiles {
        let logsDir = outdir + "/logs"
        ensureDir(logsDir)
        if !auxRep.xmp.isEmpty { writeData(Data(auxRep.xmp.utf8), to: logsDir + "/aux-metadata-\(label).xmp") }
        let hi = runProcess("/usr/bin/env", ["heif-info", path])
        writeData(Data(hi.output.utf8), to: logsDir + "/heif-info-\(label).txt")
        out["heif_info"] = hi.output
        if let brandLine = hi.output.split(separator: "\n").first(where: { $0.contains("compatible brands:") }) {
            let after = brandLine.split(separator: ":").dropFirst().joined(separator: ":")
            let brands = after.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            out["compatible_brands"] = brands
            out["tmap_present"] = brands.contains("tmap")
        }
        if let mainLine = hi.output.split(separator: "\n").first(where: { $0.contains("main brand:") }) {
            out["main_brand"] = mainLine.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        }
        let ex = runProcess("/usr/bin/env", ["exiftool", "-a", "-G1", path])
        writeData(Data(ex.output.utf8), to: logsDir + "/exiftool-\(label).txt")
        // ftyp brands straight from the file header
        if let fh = FileHandle(forReadingAtPath: path) {
            let head = fh.readData(ofLength: 64)
            fh.closeFile()
            if head.count >= 12 {
                let hex = head.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                out["ftyp_head_hex"] = hex
            }
        }
    }
    log("[\(label)] sdr=\(out["sdr"] as Any)")
    log("[\(label)] hdr=\(out["hdr"] as Any)")
    log("[\(label)] iso_aux=\(out["iso_aux"] as Any)")
    return out
}

// MARK: - verify mode

if mode == "verify" {
    ensureDir(outdir + "/logs")
    let path = verifyTarget.isEmpty ? (outdir + "/out/\(basename).heic") : verifyTarget
    log("verify \(path) size=\(fileSize(path)) sha256=\(sha256File(path))")
    let r = inspectHEIC(path, label: "verify", recordFiles: true)
    writeJSON(["file": path, "size": fileSize(path), "sha256": sha256File(path), "inspect": r],
              to: outdir + "/verify.json")
    log("wrote \(outdir)/verify.json")
    exit(0)
}

// MARK: - 1. Load source

let tAll0 = Date()
let srcURL = URL(fileURLWithPath: inputPath)
guard let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil) else { die("cannot open source \(inputPath)") }
let srcProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
let srcDepth = srcProps[kCGImagePropertyDepth] as? Int ?? -1
let srcProfile = (srcProps[kCGImagePropertyProfileName] as? String) ?? "?"
guard let srcCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot decode source") }
let W = srcCG.width, H = srcCG.height
let srcBits = srcCG.bitsPerComponent
let srcSamples = srcCG.bitsPerPixel / srcBits
let srcHasAlpha = !(srcCG.alphaInfo == .none || srcCG.alphaInfo == .noneSkipLast || srcCG.alphaInfo == .noneSkipFirst)
log("source: \(W)x\(H) bpc=\(srcBits) bpp=\(srcCG.bitsPerPixel) samples=\(srcSamples) depth=\(srcDepth) profile='\(srcProfile)' cs=\(srcCG.colorSpace?.name as Any) alphaInfo=\(srcCG.alphaInfo.rawValue) hasAlpha=\(srcHasAlpha)")
log("source sha256: \(sha256File(inputPath))  size=\(fileSize(inputPath))")
if srcBits != 16 || srcSamples != 3 || srcHasAlpha { die("unexpected source layout (expected 16-bit RGB, no alpha)") }
if srcDepth != 16 { die("unexpected source depth \(srcDepth)") }

// Output dirs
let outRoot = outdir
let outOut = outRoot + "/out"
let outLogs = outRoot + "/logs"
let tmpRoot = outRoot + "/.tmp"
let tmpWork = tmpRoot + "/work"
ensureDir(outRoot); ensureDir(outOut); ensureDir(outLogs); ensureDir(tmpRoot); ensureDir(tmpWork)
ensureDir(tmpRoot + "/det")

let sdrPath = outRoot + "/sdr.tif"
let hdrPath = outRoot + "/hdr.tif"

// MARK: - 2. SDR base: exact pass-through re-container (identity tone map)

var timings: [String: Double] = [:]
var t = Date()
func done(_ key: String, _ t0: Date) { timings[key] = Date().timeIntervalSince(t0) }

try? fm.removeItem(atPath: sdrPath)
guard let sdrDest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: sdrPath) as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
    die("cannot create TIFF destination")
}
CGImageDestinationAddImage(sdrDest, srcCG, nil)
guard CGImageDestinationFinalize(sdrDest) else { die("TIFF destination finalize failed") }
done("write_sdr_tif", t)
log("wrote \(sdrPath) size=\(fileSize(sdrPath)) sha256=\(sha256File(sdrPath))")

// Determinism: write the same base a second time, compare bytes.
let sdrCheck = tmpRoot + "/det/sdr-check.tif"
try? fm.removeItem(atPath: sdrCheck)
if let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: sdrCheck) as CFURL, UTType.tiff.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(d, srcCG, nil)
    _ = CGImageDestinationFinalize(d)
}
let sdrDetOk = sha256File(sdrPath) == sha256File(sdrCheck) && fileSize(sdrPath) == fileSize(sdrCheck)
log("sdr.tif determinism (2 writes identical bytes): \(sdrDetOk)")

// Readback layout of the written base
var sdrLayout: [String: Any] = [:]
if let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: sdrPath) as CFURL, nil),
   let g = CGImageSourceCreateImageAtIndex(s, 0, nil) {
    sdrLayout = [
        "width": g.width, "height": g.height,
        "bits_per_component": g.bitsPerComponent, "bits_per_pixel": g.bitsPerPixel,
        "samples_per_pixel": g.bitsPerPixel / g.bitsPerComponent,
        "alpha_info_raw": g.alphaInfo.rawValue,
        "colorspace": (g.colorSpace?.name as String?) ?? "nil",
        "profile": (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any])?[kCGImagePropertyProfileName] as? String ?? "?",
    ]
    log("sdr.tif readback: \(sdrLayout)")
}

// MARK: - 3. Exact 16-bit sample delta sdr.tif vs source

func rawRGB16(_ cg: CGImage) -> [UInt16]? {
    guard let dp = cg.dataProvider, let data = dp.data as Data? else { return nil }
    let w = cg.width, h = cg.height
    let bpr = cg.bytesPerRow
    var out = [UInt16](repeating: 0, count: w * h * 3)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        let u = UnsafeRawPointer(base).assumingMemoryBound(to: UInt16.self)
        let rowSamples = bpr / 2
        for y in 0..<h {
            let srcRow = y * rowSamples
            let dstRow = y * w * 3
            for x in 0..<(w * 3) { out[dstRow + x] = u[srcRow + x] }
        }
    }
    return out
}
t = Date()
var baseDelta16: [String: Any] = [:]
if let a16 = rawRGB16(srcCG),
   let s2 = CGImageSourceCreateWithURL(URL(fileURLWithPath: sdrPath) as CFURL, nil),
   let g2 = CGImageSourceCreateImageAtIndex(s2, 0, nil),
   let b16 = rawRGB16(g2), a16.count == b16.count {
    var nDiff = 0, maxDiff = 0
    var sumDiff: Double = 0
    for i in 0..<a16.count {
        let d = abs(Int(a16[i]) - Int(b16[i]))
        if d != 0 { nDiff += 1; sumDiff += Double(d) }
        if d > maxDiff { maxDiff = d }
    }
    baseDelta16 = [
        "samples": a16.count, "samples_differing": nDiff,
        "max_abs_lsb": maxDiff,
        "mean_abs_lsb": nDiff == 0 ? 0.0 : sumDiff / Double(nDiff),
        "identical": nDiff == 0,
    ]
    log("base 16-bit delta vs source: \(baseDelta16)")
} else {
    baseDelta16 = ["error": "raw sample readback failed"]
    log("base 16-bit delta: readback failed")
}
done("base_delta_16bit", t)

// MARK: - 4. Decode source to linear extended Display P3 float working buffer

let ciCtx = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
let srcCI = CIImage(cgImage: srcCG)
log("source CIImage extent=\(srcCI.extent) cs=\(srcCI.colorSpace?.name as Any)")

let tRender = Date()
var lin = [Float](repeating: 0, count: W * H * 4)
ciCtx.render(srcCI, toBitmap: &lin, rowBytes: W * 16, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBAf, colorSpace: linP3)
done("decode_to_linear_float", tRender)
log("decoded \(W)x\(H) to linear extended Display P3 float32 in \(String(format: "%.2f", timings["decode_to_linear_float"]!))s")

// MARK: - 5. Mask stats on the SDR luminance + in-place HDR authoring

let thresholds: [Float] = [0.62, 0.70, 0.80, 0.90, 1.0]
var coverCounts = [Int](repeating: 0, count: thresholds.count)
var histBins = [Int](repeating: 0, count: 10001)  // luma 0..1, 1e-4 per bin
var lumaSum: Double = 0
var lumaMin: Float = .greatestFiniteMagnitude, lumaMax: Float = -1
var baseMin: Float = .greatestFiniteMagnitude, baseMax: Float = -1
var maskZeroCount = 0, maskOneCount = 0
var pixelsAbove1 = 0, channelsAbove1 = 0
var pixelsAtCap = 0, channelsAtCap = 0
var hdrMin: Float = .greatestFiniteMagnitude, hdrMax: Float = -1
var nanCount = 0

let tStats = Date()
var o = 0
for _ in 0..<(W * H) {
    let r = lin[o], g = lin[o + 1], b = lin[o + 2]
    if !(r.isFinite && g.isFinite && b.isFinite) { nanCount += 1 }
    baseMin = min(baseMin, r, g, b)
    baseMax = max(baseMax, r, g, b)
    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b   // Rec.709 luma of linear Display P3
    lumaSum += Double(luma)
    lumaMin = min(lumaMin, luma)
    lumaMax = max(lumaMax, luma)
    let bin = Int(min(max(luma, 0), 1) * 10000.0)
    histBins[bin] += 1
    for (ti, th) in thresholds.enumerated() where luma >= th { coverCounts[ti] += 1 }
    // mask: smoothstep from start to start+transition
    var mt = (luma - startLuma) / transition
    if mt < 0 { mt = 0 } else if mt > 1 { mt = 1 }
    if mt == 0 { maskZeroCount += 1 } else if mt == 1 { maskOneCount += 1 }
    let m = mt * mt * (3 - 2 * mt)
    let gain = exp2(liftStops * m)
    var hr = r * gain, hg = g * gain, hb = b * gain
    if hb > headroomCap { hb = headroomCap }
    if hg > headroomCap { hg = headroomCap }
    if hr > headroomCap { hr = headroomCap }
    lin[o] = hr; lin[o + 1] = hg; lin[o + 2] = hb
    hdrMin = min(hdrMin, hr, hg, hb)
    hdrMax = max(hdrMax, hr, hg, hb)
    var pixelAbove = false, pixelCap = false
    if hr > 1.0 { channelsAbove1 += 1; pixelAbove = true }
    if hg > 1.0 { channelsAbove1 += 1; pixelAbove = true }
    if hb > 1.0 { channelsAbove1 += 1; pixelAbove = true }
    if hr >= headroomCap - 1e-6 { channelsAtCap += 1; pixelCap = true }
    if hg >= headroomCap - 1e-6 { channelsAtCap += 1; pixelCap = true }
    if hb >= headroomCap - 1e-6 { channelsAtCap += 1; pixelCap = true }
    if pixelAbove { pixelsAbove1 += 1 }
    if pixelCap { pixelsAtCap += 1 }
    o += 4
}
done("mask_and_hdr", tStats)
let nPixels = W * H
func frac(_ n: Int) -> Double { Double(n) / Double(nPixels) }
func quantile(_ q: Double) -> Double {
    let target = Int(q * Double(nPixels))
    var acc = 0
    for (i, c) in histBins.enumerated() {
        acc += c
        if acc >= target { return (Double(i) + 0.5) / 10000.0 }
    }
    return 1.0
}
let coverage: [String: Double] = Dictionary(uniqueKeysWithValues: thresholds.map { (String(format: "%.2f", $0), frac(coverCounts[thresholds.firstIndex(of: $0)!])) })
log("luma: min=\(lumaMin) max=\(lumaMax) mean=\(lumaSum / Double(nPixels)) p50=\(quantile(0.5)) p90=\(quantile(0.9)) p99=\(quantile(0.99)) p999=\(quantile(0.999))")
log("mask coverage: \(coverage)")
log("mask: untouched(\(maskZeroCount))=\(frac(maskZeroCount)) full(\(maskOneCount))=\(frac(maskOneCount))")
log("hdr buffer: min=\(hdrMin) max(peak)=\(hdrMax) nan=\(nanCount)")
log("pixels>1.0: \(pixelsAbove1) (\(frac(pixelsAbove1)*100)%)  channels>1.0: \(channelsAbove1)")
log("pixels at cap \(headroomCap): \(pixelsAtCap) (\(frac(pixelsAtCap)*100)%)  channels at cap: \(channelsAtCap)")
if nanCount > 0 { die("NaN in HDR buffer") }
if !(hdrMax <= headroomCap && hdrMax > 1.0) { die("authored peak \(hdrMax) outside (1.0, cap]") }

// MARK: - 6. Write hdr.tif (32-bit float, extended linear Display P3, RGBAf = 4 samples)

let tHdrWrite = Date()
let hdrData = Data(bytes: lin, count: lin.count * MemoryLayout<Float>.size)
let hdrCI = CIImage(bitmapData: hdrData, bytesPerRow: W * 16, size: CGSize(width: W, height: H), format: .RGBAf, colorSpace: linP3)
try? fm.removeItem(atPath: hdrPath)
do {
    try ciCtx.writeTIFFRepresentation(of: hdrCI, to: URL(fileURLWithPath: hdrPath), format: .RGBAf, colorSpace: linP3, options: [:])
} catch { die("write hdr.tif failed: \(error)") }
done("write_hdr_tif", tHdrWrite)
log("wrote \(hdrPath) size=\(fileSize(hdrPath)) sha256=\(sha256File(hdrPath))")
var hdrLayout: [String: Any] = [:]
if let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: hdrPath) as CFURL, nil),
   let g = CGImageSourceCreateImageAtIndex(s, 0, nil) {
    hdrLayout = [
        "width": g.width, "height": g.height,
        "bits_per_component": g.bitsPerComponent, "bits_per_pixel": g.bitsPerPixel,
        "samples_per_pixel": g.bitsPerPixel / g.bitsPerComponent,
        "alpha_info_raw": g.alphaInfo.rawValue,
        "bitmap_info_raw": g.bitmapInfo.rawValue,
        "colorspace": (g.colorSpace?.name as String?) ?? "nil",
    ]
    log("hdr.tif readback layout: \(hdrLayout)")
}
// Determinism: second write of the same CIImage
let hdrCheck = tmpRoot + "/det/hdr-check.tif"
try? fm.removeItem(atPath: hdrCheck)
do { try ciCtx.writeTIFFRepresentation(of: hdrCI, to: URL(fileURLWithPath: hdrCheck), format: .RGBAf, colorSpace: linP3, options: [:]) } catch { log("hdr determinism write failed: \(error)") }
let hdrDetOk = sha256File(hdrPath) == sha256File(hdrCheck) && fileSize(hdrPath) == fileSize(hdrCheck)
log("hdr.tif determinism (2 writes identical bytes): \(hdrDetOk)")

// MARK: - 7. Read-back verification of hdr.tif

let tReadback = Date()
var rbPeak: Float = -1, rbMin: Float = .greatestFiniteMagnitude
var rbNan = 0
var rbPixelsAbove1 = 0, rbPixelsAtCap = 0, rbChannelsAbove1 = 0
if let rbCI = CIImage(contentsOf: URL(fileURLWithPath: hdrPath), options: [.expandToHDR: true]) {
    log("hdr.tif CIImage readback extent=\(rbCI.extent) cs=\(rbCI.colorSpace?.name as Any)")
    let strip = 512
    var stripBuf = [Float](repeating: 0, count: W * strip * 4)
    var y = 0
    while y < H {
        let rows = min(strip, H - y)
        ciCtx.render(rbCI, toBitmap: &stripBuf, rowBytes: W * 16,
                     bounds: CGRect(x: 0, y: y, width: W, height: rows), format: .RGBAf, colorSpace: linP3)
        var so = 0
        for _ in 0..<(W * rows) {
            let r = stripBuf[so], g = stripBuf[so + 1], b = stripBuf[so + 2]
            if !(r.isFinite && g.isFinite && b.isFinite) { rbNan += 1 }
            rbMin = min(rbMin, r, g, b)
            rbPeak = max(rbPeak, r, g, b)
            var above = false, cap = false
            if r > 1.0 { rbChannelsAbove1 += 1; above = true }
            if g > 1.0 { rbChannelsAbove1 += 1; above = true }
            if b > 1.0 { rbChannelsAbove1 += 1; above = true }
            if r >= headroomCap - 1e-6 { cap = true }
            if g >= headroomCap - 1e-6 { cap = true }
            if b >= headroomCap - 1e-6 { cap = true }
            if above { rbPixelsAbove1 += 1 }
            if cap { rbPixelsAtCap += 1 }
            so += 4
        }
        y += rows
    }
} else {
    die("hdr.tif cannot be read back through CIImage — the tool would silently tone-map it")
}
done("readback_verify_hdr", tReadback)
log("hdr.tif readback: peak=\(rbPeak) min=\(rbMin) nan=\(rbNan) pixels>1.0=\(rbPixelsAbove1) (\(frac(rbPixelsAbove1)*100)%) pixels_at_cap=\(rbPixelsAtCap) channels>1.0=\(rbChannelsAbove1)")
if rbNan > 0 { die("NaN in hdr.tif readback") }
if !(rbPeak > 1.0 && rbPeak <= headroomCap + 1e-6) { die("hdr.tif readback peak \(rbPeak) outside (1.0, cap]") }
if rbPeak < 2.0 { log("WARNING: hdr.tif peak \(rbPeak) is below 2.0") }
let readbackMatchesBuffer = (rbPixelsAbove1 == pixelsAbove1) && (rbPixelsAtCap == pixelsAtCap) && abs(rbPeak - hdrMax) < 1e-6

// Release the big buffers before encode/verify phases.
lin = []
var hdrDataRef: Data? = hdrData
_ = hdrDataRef
hdrDataRef = nil

// MARK: - 8. Encode full resolution

func firstHEIC(in dir: String) -> String? {
    (try? fm.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".heic") }.sorted().first.map { dir + "/" + $0 }
}
// The tool names its output "<hdr-input basename>.heic"; prefer exactly that file.
func expectedHEIC(forHDR hdr: String, in dest: String) -> String? {
    let base = ((hdr as NSString).lastPathComponent as NSString).deletingPathExtension
    let p = dest + "/" + base + ".heic"
    if fm.fileExists(atPath: p) { return p }
    return firstHEIC(in: dest)
}
func encodePair(hdr: String, sdr: String, dest: String) -> (status: Int32, log: String, heic: String?) {
    // destination folder must exist (the tool does try! on it)
    ensureDir(dest)
    // remove any stale output with the expected name so we never pick up an old file
    let expectedBase = ((hdr as NSString).lastPathComponent as NSString).deletingPathExtension
    try? fm.removeItem(atPath: dest + "/" + expectedBase + ".heic")
    let args = [hdr, dest, "-b", sdr, "-R", "\(headroomCap)", "-d", "\(depth)", "-q", "\(quality)", "-c", colorSpaceFlag]
    let cmd = (["tools/toGainMapHDR/bin/toGainMapHDR"] + args).map(shellQuote).joined(separator: " ")
    let r = runProcess(toolPath, args)
    let text = "$ \(cmd)\nexit=\(r.status)\n--- output ---\n\(r.output)\n"
    return (r.status, text, expectedHEIC(forHDR: hdr, in: dest))
}

let tEncode = Date()
let fullStaging = tmpRoot + "/encode-full"
try? fm.removeItem(atPath: fullStaging)
// clear stale deliverables from any earlier run before encoding into out/
for stale in [outOut + "/\(basename).heic", outOut + "/\(basename)-2560.heic", outOut + "/\(basename)-sdr.heic", outOut + "/hdr.heic"] {
    try? fm.removeItem(atPath: stale)
}
let enc = encodePair(hdr: hdrPath, sdr: sdrPath, dest: outOut)
writeData(Data(enc.log.utf8), to: outLogs + "/encode-full.log")
log(enc.log)
guard enc.status == 0, let produced = enc.heic else { die("encoder failed (exit \(enc.status))") }
let deliveredFull = outOut + "/\(basename).heic"
try? fm.removeItem(atPath: deliveredFull)
do { try fm.moveItem(atPath: produced, toPath: deliveredFull) } catch { die("cannot move encoder output: \(error)") }
done("encode_full", tEncode)
log("delivered full: \(deliveredFull) size=\(fileSize(deliveredFull)) sha256=\(sha256File(deliveredFull))")

// Determinism of the encoder path (same inputs -> same bytes)
var repeatEncodeOk: Any = NSNull()
if doRepeatEncode {
    let tRep = Date()
    let rep = encodePair(hdr: hdrPath, sdr: sdrPath, dest: fullStaging)
    writeData(Data(rep.log.utf8), to: outLogs + "/encode-full-repeat.log")
    if rep.status == 0, let repHeic = rep.heic {
        let ok = sha256File(repHeic) == sha256File(deliveredFull) && fileSize(repHeic) == fileSize(deliveredFull)
        repeatEncodeOk = ok
        log("encoder determinism (same pair encoded twice): \(ok)")
    } else {
        repeatEncodeOk = "repeat encode failed"
        log("repeat encode failed exit=\(rep.status)")
    }
    done("encode_full_repeat", tRep)
}

// MARK: - 9. Preview (long edge 2560, Lanczos, same encoder)

func lanczos(_ image: CIImage, targetW: Int, targetH: Int) -> CIImage {
    let ext = image.extent
    let sx = CGFloat(targetW) / ext.width
    let sy = CGFloat(targetH) / ext.height
    let f = image.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: sx,
        kCIInputAspectRatioKey: sy / sx,
    ])
    return f.cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))
}

let tPreview = Date()
let targetW = previewLongEdge
let targetH = Int((Double(previewLongEdge) * Double(H) / Double(W)).rounded())
let prevBasePath = tmpWork + "/preview-base.tif"
let prevHdrPath = tmpWork + "/preview-hdr.tif"
guard let prevSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: sdrPath) as CFURL, nil),
      let prevSrcCG = CGImageSourceCreateImageAtIndex(prevSrc, 0, nil) else { die("cannot read sdr.tif for preview") }
let prevBaseCI = lanczos(CIImage(cgImage: prevSrcCG), targetW: targetW, targetH: targetH)
let prevBaseExt = prevBaseCI.extent
log("preview base extent=\(prevBaseExt) target=\(targetW)x\(targetH)")
var prevRGBA16 = [UInt16](repeating: 0, count: targetW * targetH * 4)
ciCtx.render(prevBaseCI, toBitmap: &prevRGBA16, rowBytes: targetW * 8,
             bounds: CGRect(x: 0, y: 0, width: targetW, height: targetH), format: .RGBA16, colorSpace: p3)
var prevRGB16 = [UInt16](repeating: 0, count: targetW * targetH * 3)
for i in 0..<(targetW * targetH) {
    prevRGB16[i * 3] = prevRGBA16[i * 4]
    prevRGB16[i * 3 + 1] = prevRGBA16[i * 4 + 1]
    prevRGB16[i * 3 + 2] = prevRGBA16[i * 4 + 2]
}
guard let prevBaseG = rgb16CGImage(prevRGB16, targetW, targetH, p3) else { die("preview base CGImage failed") }
try? fm.removeItem(atPath: prevBasePath)
if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: prevBasePath) as CFURL, UTType.tiff.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, prevBaseG, nil)
    if !CGImageDestinationFinalize(dest) { die("preview base TIFF write failed") }
}
var prevBaseLayout: [String: Any] = [:]
if let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: prevBasePath) as CFURL, nil), let g = CGImageSourceCreateImageAtIndex(s, 0, nil) {
    prevBaseLayout = ["width": g.width, "height": g.height, "bits_per_component": g.bitsPerComponent,
                      "bits_per_pixel": g.bitsPerPixel, "alpha_info_raw": g.alphaInfo.rawValue,
                      "colorspace": (g.colorSpace?.name as String?) ?? "nil"]
}
log("preview base tif: \(prevBaseLayout) size=\(fileSize(prevBasePath))")

guard let fullHdrCI = CIImage(contentsOf: URL(fileURLWithPath: hdrPath), options: [.expandToHDR: true]) else { die("cannot read hdr.tif for preview") }
let prevHdrCI = lanczos(fullHdrCI, targetW: targetW, targetH: targetH)
log("preview hdr extent=\(prevHdrCI.extent)")
// Lanczos can overshoot the authored cap at highlight edges; clamp the downscaled float image
// to the same headroom cap so the preview respects the recipe too.
var prevHdrLin = [Float](repeating: 0, count: targetW * targetH * 4)
ciCtx.render(prevHdrCI, toBitmap: &prevHdrLin, rowBytes: targetW * 16,
             bounds: CGRect(x: 0, y: 0, width: targetW, height: targetH), format: .RGBAf, colorSpace: linP3)
var prevPeakBefore: Float = -1
var prevChannelsClamped = 0
for i in stride(from: 0, to: prevHdrLin.count, by: 4) {
    for c in 0..<3 {
        prevPeakBefore = max(prevPeakBefore, prevHdrLin[i + c])
        if prevHdrLin[i + c] > headroomCap { prevHdrLin[i + c] = headroomCap; prevChannelsClamped += 1 }
    }
}
log("preview hdr: peak before cap clamp=\(prevPeakBefore), channels clamped=\(prevChannelsClamped)")
let prevHdrData = Data(bytes: prevHdrLin, count: prevHdrLin.count * MemoryLayout<Float>.size)
let prevHdrCIclamped = CIImage(bitmapData: prevHdrData, bytesPerRow: targetW * 16,
                               size: CGSize(width: targetW, height: targetH), format: .RGBAf, colorSpace: linP3)
try? fm.removeItem(atPath: prevHdrPath)
do {
    try ciCtx.writeTIFFRepresentation(of: prevHdrCIclamped, to: URL(fileURLWithPath: prevHdrPath), format: .RGBAf, colorSpace: linP3, options: [:])
} catch { die("preview hdr TIFF write failed: \(error)") }
var prevHdrPeak: Float = -1
if let pv = CIImage(contentsOf: URL(fileURLWithPath: prevHdrPath), options: [.expandToHDR: true]) {
    ciCtx.render(pv, toBitmap: &prevHdrLin, rowBytes: targetW * 16,
                 bounds: CGRect(x: 0, y: 0, width: targetW, height: targetH), format: .RGBAf, colorSpace: linP3)
    for i in stride(from: 0, to: prevHdrLin.count, by: 4) {
        prevHdrPeak = max(prevHdrPeak, prevHdrLin[i], prevHdrLin[i + 1], prevHdrLin[i + 2])
    }
}
log("preview hdr tif size=\(fileSize(prevHdrPath)) readback peak=\(prevHdrPeak)")
done("build_preview_tiffs", tPreview)

let prevStaging = tmpRoot + "/encode-preview"
try? fm.removeItem(atPath: prevStaging)
let tPrevEnc = Date()
let prevEnc = encodePair(hdr: prevHdrPath, sdr: prevBasePath, dest: prevStaging)
writeData(Data(prevEnc.log.utf8), to: outLogs + "/encode-preview.log")
log(prevEnc.log)
guard prevEnc.status == 0, let prevProduced = prevEnc.heic else { die("preview encoder failed (exit \(prevEnc.status))") }
let deliveredPreview = outOut + "/\(basename)-2560.heic"
try? fm.removeItem(atPath: deliveredPreview)
do { try fm.moveItem(atPath: prevProduced, toPath: deliveredPreview) } catch { die("cannot move preview output: \(error)") }
done("encode_preview", tPrevEnc)
log("delivered preview: \(deliveredPreview) size=\(fileSize(deliveredPreview)) sha256=\(sha256File(deliveredPreview))")

// MARK: - 10. Map-stripped SDR reference HEIC (ImageIO/Core Image directly, no gain map)

let tSdrHeic = Date()
var rgba8 = [UInt8](repeating: 0, count: W * H * 4)
ciCtx.render(srcCI, toBitmap: &rgba8, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8, colorSpace: p3)
var rgb8 = [UInt8](repeating: 0, count: W * H * 3)
for i in 0..<(W * H) {
    rgb8[i * 3] = rgba8[i * 4]
    rgb8[i * 3 + 1] = rgba8[i * 4 + 1]
    rgb8[i * 3 + 2] = rgba8[i * 4 + 2]
}
guard let sdrCG8 = rgb8CGImage(rgb8, W, H, p3) else { die("SDR reference CGImage failed") }
let sdrHeic = outOut + "/\(basename)-sdr.heic"
try? fm.removeItem(atPath: sdrHeic)
guard let sdrHeicDest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: sdrHeic) as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
    die("cannot create SDR HEIC destination")
}
CGImageDestinationAddImage(sdrHeicDest, sdrCG8, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
guard CGImageDestinationFinalize(sdrHeicDest) else { die("SDR HEIC finalize failed") }
done("write_sdr_heic", tSdrHeic)
log("wrote \(sdrHeic) size=\(fileSize(sdrHeic)) sha256=\(sha256File(sdrHeic))")

// MARK: - 11. Verify deliverables + base preservation / alpha / metadata

let tVerify = Date()
func decodeRGBA8(_ cg: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    ciCtx.render(CIImage(cgImage: cg), toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: p3)
    return buf
}
func deltaRGBA8(_ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int) -> [String: Any] {
    var maxD = 0
    var sumD: Double = 0
    var nDiff = 0
    var nPixDiff2 = 0
    var signedSum: Double = 0
    var hist = [Int](repeating: 0, count: 256)
    let nChannels = w * h * 3
    var i = 0
    for _ in 0..<(w * h) {
        var pixelMax = 0
        for c in 0..<3 {
            let delta = Int(b[i + c]) - Int(a[i + c])   // signed: delivered - source
            let d = abs(delta)
            hist[min(d, 255)] += 1
            signedSum += Double(delta)
            if d != 0 { nDiff += 1; sumD += Double(d) }
            if d > maxD { maxD = d }
            if d > pixelMax { pixelMax = d }
        }
        if pixelMax > 2 { nPixDiff2 += 1 }
        i += 4
    }
    func pct(_ q: Double) -> Int {
        let target = Int(q * Double(nChannels))
        var acc = 0
        for (d, c) in hist.enumerated() { acc += c; if acc >= target { return d } }
        return 255
    }
    return [
        "channels_differing": nDiff,
        "channels_total": nChannels,
        "max_abs_lsb8": maxD,
        "mean_abs_lsb8": nDiff == 0 ? 0.0 : sumD / Double(nDiff),
        "mean_signed_lsb8": signedSum / Double(nChannels),
        "p50_abs_lsb8": pct(0.5), "p90_abs_lsb8": pct(0.9), "p99_abs_lsb8": pct(0.99),
        "p999_abs_lsb8": pct(0.999), "p9999_abs_lsb8": pct(0.9999),
        "channels_gt_4lsb8": hist[5...255].reduce(0, +),
        "pixels_any_channel_gt_2lsb8": nPixDiff2,
    ]
}

// Compares the decoded HDR rendition of the delivered HEIC against the authored hdr.tif.
func hdrFidelity(delivered: String, authored: String, _ w: Int, _ h: Int, cap: Float) -> [String: Any] {
    guard let a = CIImage(contentsOf: URL(fileURLWithPath: authored), options: [.expandToHDR: true]),
          let b = CIImage(contentsOf: URL(fileURLWithPath: delivered), options: [.expandToHDR: true]) else {
        return ["error": "decode failed"]
    }
    let strip = 512
    var bufA = [Float](repeating: 0, count: w * strip * 4)
    var bufB = [Float](repeating: 0, count: w * strip * 4)
    var peakA: Float = -1, peakB: Float = -1
    var sumA = 0.0, sumB = 0.0
    var maxAbsDiff: Float = 0
    var sumAbsDiff: Double = 0
    var n = 0
    var absAbove = 0, absAboveBig = 0
    var hist = [Int](repeating: 0, count: 5000)   // |Δ| in linear units, 1e-3 bins, 0..5
    var bOverCap = 0
    var y = 0
    while y < h {
        let rows = min(strip, h - y)
        ciCtx.render(a, toBitmap: &bufA, rowBytes: w * 16, bounds: CGRect(x: 0, y: y, width: w, height: rows), format: .RGBAf, colorSpace: linP3)
        ciCtx.render(b, toBitmap: &bufB, rowBytes: w * 16, bounds: CGRect(x: 0, y: y, width: w, height: rows), format: .RGBAf, colorSpace: linP3)
        var o = 0
        for _ in 0..<(w * rows) {
            var mxA: Float = -1, mxB: Float = -1
            for c in 0..<3 {
                mxA = max(mxA, bufA[o + c]); mxB = max(mxB, bufB[o + c])
                let d = abs(bufA[o + c] - bufB[o + c])
                if d > maxAbsDiff { maxAbsDiff = d }
                sumAbsDiff += Double(d); n += 1
                hist[min(Int(d * 1000), 4999)] += 1
                if d > 0.1 { absAbove += 1 }
                if d > 0.5 { absAboveBig += 1 }
            }
            peakA = max(peakA, mxA); peakB = max(peakB, mxB)
            sumA += Double(mxA); sumB += Double(mxB)
            if mxB > cap + 1e-6 { bOverCap += 1 }
            o += 4
        }
        y += rows
    }
    func pct(_ q: Double) -> Double {
        let target = Int(q * Double(n)); var acc = 0
        for (i, c) in hist.enumerated() { acc += c; if acc >= target { return Double(i) / 1000.0 } }
        return 5.0
    }
    let nPix = w * h
    return [
        "authored_peak_linear": Double(peakA),
        "delivered_peak_linear": Double(peakB),
        "authored_mean_of_per_pixel_max": sumA / Double(nPix),
        "delivered_mean_of_per_pixel_max": sumB / Double(nPix),
        "mean_abs_diff_linear": sumAbsDiff / Double(n),
        "p90_abs_diff_linear": pct(0.9), "p99_abs_diff_linear": pct(0.99), "p999_abs_diff_linear": pct(0.999),
        "max_abs_diff_linear": Double(maxAbsDiff),
        "channels_abs_diff_gt_0.1": absAbove, "channels_abs_diff_gt_0.5": absAboveBig,
        "channels_total": n,
        "pixels_delivered_over_cap": bOverCap,
        "fraction_pixels_delivered_over_cap": Double(bOverCap) / Double(nPix),
        "decode_path": "CIImage(contentsOf: [.expandToHDR: true]) -> extended linear Display P3, strip renders",
    ]
}

// Peak / above-white statistics of a decoded SDR CGImage rendered to linear P3 (strip renders).
func decodeExtremes(_ cg: CGImage, _ w: Int, _ h: Int, cap: Float) -> [String: Any] {
    let strip = 512
    var buf = [Float](repeating: 0, count: w * strip * 4)
    var peak: Float = -1
    var sum = 0.0
    var over1 = 0, overCap = 0
    var y = 0
    while y < h {
        let rows = min(strip, h - y)
        ciCtx.render(CIImage(cgImage: cg), toBitmap: &buf, rowBytes: w * 16,
                     bounds: CGRect(x: 0, y: y, width: w, height: rows), format: .RGBAf, colorSpace: linP3)
        var o = 0
        for _ in 0..<(w * rows) {
            var mx: Float = -1
            for c in 0..<3 { mx = max(mx, buf[o + c]) }
            peak = max(peak, mx)
            sum += Double(mx)
            if mx > 1.0 { over1 += 1 }
            if mx > cap + 1e-6 { overCap += 1 }
            o += 4
        }
        y += rows
    }
    let n = w * h
    return [
        "peak_linear": Double(peak),
        "mean_of_per_pixel_max_linear": sum / Double(n),
        "pixels_gt_1_0": over1,
        "fraction_pixels_gt_1_0": Double(over1) / Double(n),
        "pixels_gt_cap": overCap,
        "fraction_pixels_gt_cap": Double(overCap) / Double(n),
        "cap": d6(cap),
        "decode_path": "ImageIO CGImage -> CIImage -> extended linear Display P3, strip renders",
    ]
}

// Source quantised to 8-bit Display P3 (the reference the delivered SDR base should match)
let src8 = decodeRGBA8(srcCG, W, H)
guard let delSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: deliveredFull) as CFURL, nil),
      let delSDR = CGImageSourceCreateImageAtIndex(delSrc, 0, nil) else { die("cannot decode delivered HEIC") }
let del8 = decodeRGBA8(delSDR, W, H)
let baseDeltaDelivered = deltaRGBA8(src8, del8, W, H)
let sdrDecodeExtremes = decodeExtremes(delSDR, W, H, cap: headroomCap)
log("delivered SDR fallback decode extremes: \(sdrDecodeExtremes)")
log("delivered SDR base delta vs source (8-bit P3 LSB): \(baseDeltaDelivered)")

guard let sdrRefSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: sdrHeic) as CFURL, nil),
      let sdrRefCG = CGImageSourceCreateImageAtIndex(sdrRefSrc, 0, nil) else { die("cannot decode sdr.heic") }
let sdrRef8 = decodeRGBA8(sdrRefCG, W, H)
let baseDeltaSdrRefVsSource = deltaRGBA8(src8, sdrRef8, W, H)
let baseDeltaSdrRefVsDelivered = deltaRGBA8(del8, sdrRef8, W, H)
log("sdr.heic delta vs source (8-bit P3 LSB): \(baseDeltaSdrRefVsSource)")
log("sdr.heic delta vs delivered SDR fallback (8-bit P3 LSB): \(baseDeltaSdrRefVsDelivered)")

// Does the decoded HDR rendition of the delivered file match the authored hdr.tif?
let tFid = Date()
let fidelity = hdrFidelity(delivered: deliveredFull, authored: hdrPath, W, H, cap: headroomCap)
done("hdr_fidelity_decode_compare", tFid)
log("delivered HDR fidelity vs authored hdr.tif: \(fidelity)")

let fullInspect = inspectHEIC(deliveredFull, label: "full", recordFiles: true)
let previewInspect = inspectHEIC(deliveredPreview, label: "preview", recordFiles: true)
let sdrInspect = inspectHEIC(sdrHeic, label: "sdr", recordFiles: true)
done("verify_deliverables", tVerify)

// alpha summary
func alphaSummary(_ inspect: [String: Any], label: String) -> [String: Any] {
    var out: [String: Any] = ["file": label]
    if let sdr = inspect["sdr"] as? [String: Any] {
        out["sdr_alpha_info_raw"] = sdr["alpha_info_raw"]
        out["sdr_has_alpha_data"] = sdr["has_alpha_data"]
        out["sdr_bits_per_pixel"] = sdr["bits_per_pixel"]
    }
    if let info = inspect["heif_info"] as? String {
        out["heif_info_alpha_line"] = info.split(separator: "\n").first { $0.contains("alpha channel") }.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
    out["aux_present"] = inspect["aux_present"]
    return out
}
let alpha = [
    "source": ["samples_per_pixel": srcSamples, "has_alpha": srcHasAlpha],
    "sdr_tif": sdrLayout,
    "hdr_tif": hdrLayout,
    "delivered_full": alphaSummary(fullInspect, label: "full"),
    "delivered_preview": alphaSummary(previewInspect, label: "preview"),
    "delivered_sdr_reference": alphaSummary(sdrInspect, label: "sdr"),
] as [String: Any]
log("alpha summary: \(alpha)")

// MARK: - 12. stats.json

let recipe: [String: Any] = [
    "start": d6(startLuma), "lift_stops": d6(liftStops), "transition": d6(transition),
    "headroom_cap_linear": d6(headroomCap),
    "headroom_cap_stops": d6(log2(headroomCap) * 1),
    "base_tone_map": "c1_match_v1",
    "mask_luma": "Rec.709 luma of linear extended Display P3",
    "mask_curve": "smoothstep(t), t=clamp((luma-start)/transition,0,1)",
    "gain": "2^(lift_stops*m), then absolute clamp to headroom_cap",
    "encoder": ["tool": toolPath, "quality": d6(quality), "depth": depth, "subsample": false,
                "map": "iso-rgb", "color_space": colorSpaceFlag, "R": headroomCap],
]
let sourceInfo: [String: Any] = [
    "path": inputPath, "sha256": sha256File(inputPath), "size_bytes": fileSize(inputPath),
    "width": W, "height": H, "bits_per_component": srcBits, "samples_per_pixel": srcSamples,
    "depth_tag": srcDepth, "profile": srcProfile,
    "colorspace": (srcCG.colorSpace?.name as String?) ?? "nil",
    "alpha_info_raw": srcCG.alphaInfo.rawValue, "has_alpha": srcHasAlpha,
]
let baseInfo: [String: Any] = [
    "file": sdrPath, "sha256": sha256File(sdrPath), "size_bytes": fileSize(sdrPath),
    "layout": sdrLayout, "tone_map": "c1_match_v1 (identity pass-through)",
    "delta_vs_source_16bit": baseDelta16,
    "stream_determinism_2writes_identical": sdrDetOk,
]
let hdrInfo: [String: Any] = [
    "file": hdrPath, "sha256": sha256File(hdrPath), "size_bytes": fileSize(hdrPath),
    "layout": hdrLayout,
    "readback_peak_linear": Double(rbPeak),
    "readback_peak_stops": log2(Double(rbPeak)),
    "readback_min_linear": Double(rbMin),
    "readback_nan_count": rbNan,
    "readback_pixels_gt_1": rbPixelsAbove1,
    "readback_fraction_pixels_gt_1": frac(rbPixelsAbove1),
    "readback_channels_gt_1": rbChannelsAbove1,
    "readback_pixels_at_cap": rbPixelsAtCap,
    "readback_fraction_pixels_at_cap": frac(rbPixelsAtCap),
    "buffer_peak_linear": Double(hdrMax),
    "buffer_pixels_gt_1": pixelsAbove1,
    "buffer_channels_gt_1": channelsAbove1,
    "buffer_pixels_at_cap": pixelsAtCap,
    "readback_matches_buffer": readbackMatchesBuffer,
    "stream_determinism_2writes_identical": hdrDetOk,
]
let maskInfo: [String: Any] = [
    "start": d6(startLuma), "transition": d6(transition), "end": d6(startLuma + transition),
    "coverage_luma_ge_threshold": coverage,
    "mask_zero_fraction": frac(maskZeroCount),
    "mask_one_fraction": frac(maskOneCount),
    "luma_stats": [
        "min": Double(lumaMin), "max": Double(lumaMax), "mean": lumaSum / Double(nPixels),
        "p50": quantile(0.5), "p90": quantile(0.9), "p99": quantile(0.99), "p999": quantile(0.999),
    ],
    "base_linear_min": Double(baseMin), "base_linear_max": Double(baseMax),
    "fraction_pixels_gt_1_expected": frac(pixelsAbove1),
    "fraction_pixels_at_cap_expected": frac(pixelsAtCap),
]
let authoredPeak: [String: Any] = [
    "linear": Double(hdrMax),
    "stops": log2(Double(hdrMax)),
    "cap_linear": headroomCap,
    "clamped_to_cap": hdrMax >= headroomCap - 1e-6,
]
let encodeInfo: [String: Any] = [
    "command": "tools/toGainMapHDR/bin/toGainMapHDR \(hdrPath) \(outOut) -b \(sdrPath) -R \(headroomCap) -d \(depth) -q \(quality) -c \(colorSpaceFlag)",
    "exit_code": 0,
    "elapsed_s": timings["encode_full"] ?? -1,
    "log": outLogs + "/encode-full.log",
    "repeat_deterministic": repeatEncodeOk,
    "size_overhead_vs_sdr_only": [
        "sdr_only_encode_bytes": fileSize(sdrHeic),
        "delivered_full_bytes": fileSize(deliveredFull),
        "extra_bytes_for_gain_map": fileSize(deliveredFull) - fileSize(sdrHeic),
        "ratio": Double(fileSize(deliveredFull)) / Double(fileSize(sdrHeic)),
        "note": "full-resolution RGB gain map (no -H subsampling), 6000x4000 base",
    ] as [String: Any],
]
let deliveredInfo: [String: Any] = [
    "full": ["file": deliveredFull, "size_bytes": fileSize(deliveredFull), "sha256": sha256File(deliveredFull),
             "inspect": fullInspect] as [String: Any],
    "preview": ["file": deliveredPreview, "size_bytes": fileSize(deliveredPreview), "sha256": sha256File(deliveredPreview),
                "inspect": previewInspect,
                "long_edge": previewLongEdge,
                "peak_before_cap_clamp_linear": Double(prevPeakBefore),
                "channels_clamped_to_cap": prevChannelsClamped,
                "preview_hdr_tif_readback_peak_linear": Double(prevHdrPeak)] as [String: Any],
    "sdr_reference": ["file": sdrHeic, "size_bytes": fileSize(sdrHeic), "sha256": sha256File(sdrHeic),
                      "inspect": sdrInspect,
                      "delta_vs_source_8bit": baseDeltaSdrRefVsSource,
                      "delta_vs_delivered_sdr_8bit": baseDeltaSdrRefVsDelivered] as [String: Any],
    "hdr_fidelity_vs_authored": fidelity,
    "delivered_sdr_decode_extremes": sdrDecodeExtremes,
    "base_preservation": [
        "delivered_sdr_vs_source_8bit": baseDeltaDelivered,
        "note": "Compare after decoding the delivered SDR fallback and quantising the source to 8-bit Display P3; HEVC at q=\(quality) is the only loss.",
    ] as [String: Any],
]
timings["total_render_and_encode"] = Date().timeIntervalSince(tAll0)
let stats: [String: Any] = [
    "schema": 1,
    "task": "M0-C real pair",
    "source": sourceInfo,
    "recipe": recipe,
    "authored_peak": authoredPeak,
    "base": baseInfo,
    "hdr": hdrInfo,
    "mask": maskInfo,
    "alpha": alpha,
    "encode": encodeInfo,
    "deliverables": deliveredInfo,
    "timings_s": timings,
]
let statsPath = outRoot + "/stats.json"
writeJSON(stats, to: statsPath)
log("wrote \(statsPath)")

// make sure the required deliverables are all present
for p in [sdrPath, hdrPath, deliveredFull, deliveredPreview, sdrHeic, statsPath] {
    if !fm.fileExists(atPath: p) { die("missing deliverable \(p)") }
}

// MARK: - 13. notes.md

var notes = """
# M0-C — real pair: `R0003777-P3.tif` → SDR base + authored HDR + gain-map HEIC

Generated by `render.swift` (deterministic). Re-run:

```bash
# from the repo root
swiftc -O -o work/m0/real/.tmp/render work/m0/real/render.swift
work/m0/real/.tmp/render            # defaults: samples/sources/R0003777-P3.tif -> work/m0/real
```

Interpreter mode also works (slower):

```bash
export TMPDIR="$PWD/work/m0/real/.tmp"
swift -module-cache-path work/m0/real/.mc work/m0/real/render.swift
```

## Input

- `\(inputPath)` — \(W)×\(H), \(srcBits)-bit, \(srcSamples) samples/pixel, depth tag \(srcDepth), profile `\(srcProfile)`, no alpha.
- sha256 `\(sha256File(inputPath))`

## Recipe (doc 04 v0)

`start=\(startLuma)`, `lift_stops=\(liftStops)`, `transition=\(transition)`, `headroom_cap=\(headroomCap)` linear (= \(String(format: "%.4f", log2(headroomCap))) stops);
base tone map `c1_match_v1` (identity/pass-through); encoder `-d \(depth) -q \(quality) -c \(colorSpaceFlag)`.

Mask: `t = clamp((luma - start)/transition, 0, 1)`, `m = t²(3-2t)` (smoothstep), `gain = 2^(lift_stops·m)`,
`hdr_linear = base_linear · gain`, then an **absolute** clamp to `\(headroomCap)` (values 1.0…\(headroomCap) kept exactly).
Luma is Rec.709 luma of the linear extended-Display-P3 working buffer.

## Commands actually run

1. SDR base (exact pass-through): decode source via ImageIO, re-container the decoded image into a 16-bit
   Display-P3 TIFF with `CGImageDestination` (no colour conversion, no tone curve).
   Readback vs source: \(baseDelta16["samples_differing"] as? Int ?? -1) / \(baseDelta16["samples"] as? Int ?? -1) 16-bit samples differ,
   max |Δ| = \(baseDelta16["max_abs_lsb"] as? Int ?? -1) LSB → identity contract holds.
2. HDR: source decoded to linear extended-Display-P3 float32 (Core Image), mask/gain applied on the CPU, clamped to
   \(headroomCap), written as a 32-bit-float TIFF (see surprise below).
   Readback peak = \(rbPeak) linear (\(String(format: "%.4f", log2(Double(rbPeak)))) stops), NaN-free,
   \(rbPixelsAbove1) pixels > 1.0, \(rbPixelsAtCap) pixels at the cap.
3. Encode (exact command):

```bash
tools/toGainMapHDR/bin/toGainMapHDR \(hdrPath) \(outOut) -b \(sdrPath) -R \(headroomCap) -d \(depth) -q \(quality) -c \(colorSpaceFlag)
```
   exit 0, \(String(format: "%.2f", timings["encode_full"] ?? -1)) s → `\(deliveredFull)` (\(fileSize(deliveredFull)) bytes).
4. Preview: base+HDR Lanczos-downscaled to \(targetW)×\(targetH) (long edge \(previewLongEdge)), same encoder flags
   → `\(deliveredPreview)` (\(fileSize(deliveredPreview)) bytes, limit 3.5 MB: \(fileSize(deliveredPreview) <= 3_500_000 ? "OK" : "OVER LIMIT")).
   Lanczos can undershoot/overshoot the authored cap; the downscaled float HDR is clamped to \(headroomCap) before encoding
   (peak before clamp \(prevPeakBefore) linear, \(prevChannelsClamped) channels clamped; readback peak \(prevHdrPeak)).
5. Map-stripped SDR reference written directly with ImageIO/Core Image (8-bit Display P3, no gain map, no alpha)
   → `\(deliveredHeicName(for: sdrHeic))` (\(fileSize(sdrHeic)) bytes). **Not** `sips`, **not** the tool's `-s`.

## Measured metadata of the delivered full-resolution file

- ISO aux metadata present: \(fullInspect["aux_present"] as? Bool ?? false) (ISO 21496-1 `tmap`, RGB map).
- `HDRToneMap:AlternateHeadroom` = \(String(describing: (fullInspect["iso_aux"] as? [String: Any])?["HDRToneMap_AlternateHeadroom_stops"] ?? "?")) stops
  (linear ≈ \(String(describing: (fullInspect["iso_aux"] as? [String: Any])?["HDRToneMap_AlternateHeadroom_linear"] ?? "?"))).
- `HDRToneMap:GainMapMax` per channel (stops): \(String(describing: (fullInspect["iso_aux"] as? [String: Any])?["HDRToneMap_GainMapMax_stops_channels"] ?? "?")).
- ImageIO `DecodeToHDR` headroom ≈ \(String(describing: ((fullInspect["hdr"] as? [String: Any])?["content_headroom_linear"]) ?? "?")) linear.
- Alpha: \(String(describing: (fullInspect["sdr"] as? [String: Any])?["has_alpha_data"] ?? "?")); heif-info: "\(((fullInspect["heif_info"] as? String)?.split(separator: "\n").first { $0.contains("alpha channel") }?.trimmingCharacters(in: .whitespaces)) ?? "?")".
- Base preservation vs source (8-bit P3 code-value domain): mean |Δ| = \(String(format: "%.3f", (baseDeltaDelivered["mean_abs_lsb8"] as? Double) ?? -1)) LSB,
  signed mean = \(String(format: "%+.3f", (baseDeltaDelivered["mean_signed_lsb8"] as? Double) ?? 0)) LSB,
  |Δ| percentiles p50/p90/p99/p99.99 = \(baseDeltaDelivered["p50_abs_lsb8"] as? Int ?? -1)/\(baseDeltaDelivered["p90_abs_lsb8"] as? Int ?? -1)/\(baseDeltaDelivered["p99_abs_lsb8"] as? Int ?? -1)/\(baseDeltaDelivered["p9999_abs_lsb8"] as? Int ?? -1) LSB,
  max |Δ| = \(baseDeltaDelivered["max_abs_lsb8"] as? Int ?? -1) LSB.
  The residual is HEVC q=\(quality) loss (YCbCr 4:2:0 chroma), **not** tone mapping: the signed bias is ~0 and an
  independent ImageIO encode of the same base (\(deliveredHeicName(for: sdrHeic))) deviates from the source by
  mean |Δ| = \(String(format: "%.3f", (baseDeltaSdrRefVsSource["mean_abs_lsb8"] as? Double) ?? -1)) / max \(baseDeltaSdrRefVsSource["max_abs_lsb8"] as? Int ?? -1) LSB — same magnitude.
  Delivered SDR vs that independent SDR reference: mean |Δ| = \(String(format: "%.3f", (baseDeltaSdrRefVsDelivered["mean_abs_lsb8"] as? Double) ?? -1)) / max \(baseDeltaSdrRefVsDelivered["max_abs_lsb8"] as? Int ?? -1) LSB.
- Container: major brand `\(String(describing: fullInspect["main_brand"] ?? "?"))`, compatible brands
  \(String(describing: fullInspect["compatible_brands"] ?? "?")); `tmap` present = \(String(describing: fullInspect["tmap_present"] ?? "?"));
  base 8-bit YCbCr 4:2:0, tiled 6×7. Colour is signalled by both the ICC `Display P3` profile and `nclx`
  (base nclx primaries/transfer Unspecified, matrix BT.601, full range); the gain-map aux nclx is
  SMPTE EG 432-1 (P3) / PQ, 10-bit. `HDRToneMap:BaseColorIsWorkingColor = True` → the map was derived in the base's space.
- Delivered HDR decode vs authored `hdr.tif` (both rendered to linear extended Display P3): mean |Δ| = \(String(format: "%.4f", (fidelity["mean_abs_diff_linear"] as? Double) ?? -1)),
  p99 = \(String(format: "%.4f", (fidelity["p99_abs_diff_linear"] as? Double) ?? -1)), p99.9 = \(String(format: "%.4f", (fidelity["p999_abs_diff_linear"] as? Double) ?? -1)), max = \(String(format: "%.4f", (fidelity["max_abs_diff_linear"] as? Double) ?? -1));
  authored peak 2.5 linear, delivered decode peak \(String(format: "%.4f", (fidelity["delivered_peak_linear"] as? Double) ?? -1)) linear,
  pixels decoded above the 2.5 authored cap = \(fidelity["pixels_delivered_over_cap"] as? Int ?? -1) (fraction \(String(format: "%.6f", (fidelity["fraction_pixels_delivered_over_cap"] as? Double) ?? -1))).
  Mean of per-pixel max: authored \(String(format: "%.4f", (fidelity["authored_mean_of_per_pixel_max"] as? Double) ?? -1)) vs delivered \(String(format: "%.4f", (fidelity["delivered_mean_of_per_pixel_max"] as? Double) ?? -1)).
  The tiny isolated-pixel overshoot comes from the lossy/10-bit gain-map decode, not from the container metadata
  (advertised `AlternateHeadroom` is exactly 2.5 linear). Reason: the decoded SDR fallback itself has an
  isolated-pixel peak of \(String(format: "%.4f", (sdrDecodeExtremes["peak_linear"] as? Double) ?? -1)) linear
  (\(sdrDecodeExtremes["pixels_gt_1_0"] as? Int ?? -1) pixels > 1.0 = \(String(format: "%.4f", (sdrDecodeExtremes["fraction_pixels_gt_1_0"] as? Double) ?? -1))) — 8-bit YCbCr 4:2:0
  chroma overshoot at clipped speculars — and the max gain (2^1.4 ≈ 2.64x) multiplies that overshoot.
  It is a decode-side artifact of the lossy base, not authored headroom.

## Surprises / decisions

- **32-bit float TIFF must have 4 samples (RGBAf).** ImageIO/Core Image cannot decode a 3-channel
  32-bit-float TIFF: it returns a 96-bpp CGImage whose data are silently misinterpreted (`CIImage` then reads
  wrong values, e.g. 1.26 instead of 1.88 linear), and the encoder would then compute a wrong gain map while
  still exiting 0. `CIContext.writeTIFFRepresentation(.RGBAf, extendedLinearDisplayP3)` writes 4-channel float
  with an embedded **"Display P3 Linear"** ICC profile, and that file reads back exactly (Δ = 0) — this is the
  only float-TIFF route that survives. The alpha sample in `hdr.tif` is 1.0 everywhere and is *not* propagated to
  the deliverable (alpha in the output follows the SDR base, which has 3 samples).
- **`-b` + no `-H` skips the tool's headroom analysis entirely** (`main.swift` line 407), so `-R` does **not**
  clamp anything: the gain map and the advertised headroom are derived by Core Image from HDR↔SDR ratio.
  The authored absolute clamp to \(headroomCap) is therefore the only thing that controls the delivered headroom —
  keep `-R` in the command line because it is the documented flag and it does control the tool's own
  tone-map path when it has to generate the base.
- **If the HDR input peak is < 1.05 the tool silently writes an SDR HEIC** (warning branch at line 413) —
  this cannot happen here because the HDR clamp guarantees a 2.0+ peak, but a run whose HDR TIFF got clipped to
  SDR would still exit 0. The renderer asserts the readback peak before encoding.
- **Encoder is deterministic** for the same pair: encoding the same `hdr.tif`+`sdr.tif` twice gave identical bytes
  (\(String(describing: repeatEncodeOk))). `sdr.tif` and `hdr.tif` are also byte-identical across repeated writes,
  so the whole path is reproducible (same input + recipe → same bytes). No timestamps are embedded in any image.
- `headroom_cap = \(headroomCap)` linear is **not** exactly 1.4 stops: the lift is 1.4 stops of *gain* above SDR white,
  the absolute peak is capped at \(headroomCap) (= \(String(format: "%.4f", log2(headroomCap))) stops). Both numbers are in `stats.json`.
- **Size**: the delivered full-res file is \(fileSize(deliveredFull)) B vs \(fileSize(sdrHeic)) B for the map-stripped SDR-only
  encode → +\(fileSize(deliveredFull) - fileSize(sdrHeic)) B (ratio \(String(format: "%.2f", Double(fileSize(deliveredFull)) / Double(fileSize(sdrHeic))))) for a **full-resolution** RGB gain map
  (no `-H`). Still far under the ~20 MB reject threshold; `-H` (half-size map) is the stage-2 lever if that overhead matters.
- **Preview headroom**: the delivered preview advertises \(String(describing: (previewInspect["iso_aux"] as? [String: Any])?["HDRToneMap_AlternateHeadroom_stops"] ?? "?")) stops
  (\(String(describing: (previewInspect["iso_aux"] as? [String: Any])?["HDRToneMap_AlternateHeadroom_linear"] ?? "?")) linear); its alpha state matches the full file (none).
"""
let notesPath = outRoot + "/notes.md"
writeData(Data(notes.utf8), to: notesPath)
func deliveredHeicName(for p: String) -> String { (p as NSString).lastPathComponent }
log("wrote \(notesPath)")
writeLogFile()
log("DONE total=\(String(format: "%.1f", timings["total_render_and_encode"]!))s")
