import Foundation
import Metal
let source = try! String(contentsOfFile: "/Users/criphc/Sites/llm-photon/ipad/Photon/Shaders/HighlightShape.metal", encoding: .utf8)
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no device") }
do {
    let lib = try device.makeLibrary(source: source, options: nil)
    print("library ok, functions:", lib.functionNames)
    let f = lib.makeFunction(name: "highlightShapeKernel")!
    let p = try device.makeComputePipelineState(function: f)
    print("pipeline ok, maxThreads", p.maxTotalThreadsPerThreadgroup)
} catch {
    print("ERROR", error)
    exit(1)
}
