import Foundation
import CryptoKit

// Reproduces the pipeline's preview staging step so preview-input determinism can be checked
// independently of the CLI/tool. Usage: previewdebug <source.tif> <outdir>
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func sha(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let decoded = try SourceDecoder.decode(url: source)
let toneMap = try ToneMapKind.named("c1_match_v1")
let base = try ToneMapper.sdrBase(from: decoded.linear, toneMap: toneMap)
let shape = try HighlightShape(recipe: Recipe.HDR())
let hdrResult = try HDRRendition.render(base: base, shape: shape)
let pair = try PreviewRenderer.downscale(base: base, hdr: hdrResult.image, longEdge: 2560, headroomCap: shape.headroomCap)

let baseURL = out.appendingPathComponent("preview-base.tif")
let hdrURL = out.appendingPathComponent("preview-hdr.tif")
try TIFFWriter.writeSDRBase(pair.base, to: baseURL)
try TIFFWriter.writeHDR(pair.hdr, to: hdrURL)

print("preview size:", pair.size)
print("hdr peak:", pair.hdr.maxChannel, "base peak:", pair.base.maxChannel)
print("base sha:", try sha(baseURL), "bytes:", (try FileManager.default.attributesOfItem(atPath: baseURL.path)[.size] as? Int) ?? -1)
print("hdr  sha:", try sha(hdrURL), "bytes:", (try FileManager.default.attributesOfItem(atPath: hdrURL.path)[.size] as? Int) ?? -1)

// encode the same pair twice, in this process, into sibling dirs (raw tool call: avoids the
// Foundation.Encoder / PhotonCore.Encoder name collision in a single-file build)
let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let tool = repoRoot.appendingPathComponent("tools/toGainMapHDR/bin/toGainMapHDR")
for name in ["enc-a", "enc-b"] {
    let dir = out.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = tool
    process.arguments = [hdrURL.path, dir.path, "-b", baseURL.path, "-R", "2.5", "-d", "8", "-q", "0.85", "-c", "p3"]
    try process.run()
    process.waitUntilExit()
    let heic = dir.appendingPathComponent(hdrURL.deletingPathExtension().lastPathComponent + ".heic")
    print("\(name): status=\(process.terminationStatus)", (try? sha(heic)) ?? "missing",
          (try? FileManager.default.attributesOfItem(atPath: heic.path)[.size] as? Int) ?? -1)
}
