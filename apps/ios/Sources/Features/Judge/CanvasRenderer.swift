import MetalKit
import ClientKit
import ContractKit

/// 画布渲染器：跑 ClientKit 里唯一的 MSL（compute → present），
/// 把解码后的线性 P3 base 以 HDR 值送到 EDR 图层。
final class CanvasRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var baseTexture: MTLTexture?
    private var intermediate: MTLTexture?
    private var gate = BaseUploadGate()
    private var needsCompute = true

    private var image: LinearImage?
    private var identity: BaseIdentity?
    private var uniforms = HighlightUniforms()

    init?(device: MTLDevice) {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: try ShaderResource.source(), options: nil)
        } catch {
            return nil
        }

        guard let queue = device.makeCommandQueue(),
              let computeFunction = library.makeFunction(name: "highlightShapeKernel"),
              let vertexFunction = library.makeFunction(name: "presentVertex"),
              let fragmentFunction = library.makeFunction(name: "presentFragment"),
              let computePipeline = try? device.makeComputePipelineState(function: computeFunction)
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        guard let presentPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }

        self.device = device
        self.queue = queue
        self.computePipeline = computePipeline
        self.presentPipeline = presentPipeline
        self.sampler = sampler
        super.init()
    }

    /// 每一帧的输入：base + 身份 + 参数。base 只在身份变化时重新上传。
    func update(image: LinearImage?, identity: BaseIdentity?, uniforms: HighlightUniforms) {
        self.image = image
        self.identity = identity
        if self.uniforms != uniforms {
            self.uniforms = uniforms
            needsCompute = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        if gate.needsUpload(for: identity) {
            uploadBase()
            gate.commitUpload(identity)
        }
        encodeCompute(into: commandBuffer)
        encodePresent(into: commandBuffer, view: view)
        commandBuffer.commit()
    }

    private func uploadBase() {
        guard let image else {
            baseTexture = nil
            intermediate = nil
            return
        }

        let width = image.size.width
        let height = image.size.height

        let baseDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        baseDescriptor.usage = [.shaderRead]
        baseDescriptor.storageMode = .shared
        guard let base = device.makeTexture(descriptor: baseDescriptor) else { return }

        image.pixels.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            base.replace(region: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0,
                         withBytes: address,
                         bytesPerRow: width * MemoryLayout<Float>.stride * 4)
        }

        let intermediateDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        intermediateDescriptor.usage = [.shaderRead, .shaderWrite]
        intermediateDescriptor.storageMode = .private
        guard let intermediate = device.makeTexture(descriptor: intermediateDescriptor) else { return }

        baseTexture = base
        self.intermediate = intermediate
        needsCompute = true
    }

    private func encodeCompute(into commandBuffer: MTLCommandBuffer) {
        guard needsCompute,
              let base = baseTexture,
              let intermediate,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }

        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(base, index: 0)
        encoder.setTexture(intermediate, index: 1)
        var uniforms = uniforms
        encoder.setBytes(&uniforms, length: HighlightUniforms.byteCount, index: 0)

        let width = computePipeline.threadExecutionWidth
        let height = max(computePipeline.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(MTLSize(width: base.width, height: base.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        needsCompute = false
    }

    private struct PresentUniforms {
        var drawableSize: SIMD2<Float>
        var imageSize: SIMD2<Float>
    }

    private func encodePresent(into commandBuffer: MTLCommandBuffer, view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        if let intermediate {
            var present = PresentUniforms(
                drawableSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                imageSize: SIMD2(Float(intermediate.width), Float(intermediate.height))
            )
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentBytes(&present, length: MemoryLayout<PresentUniforms>.stride, index: 0)
            encoder.setFragmentTexture(intermediate, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
    }
}
