import SwiftUI
import UIKit
import MetalKit
import Tokens
import ClientKit
import ContractKit

/// 画布背景 3 档。前两档跟系统深浅色走（深色 = 黑/深灰，浅色 = 白/浅灰），
/// 第三档是固定的中性灰：18% 反射灰，用来在不受环境色影响的情况下看高光。
enum CanvasBackground: Int, CaseIterable {
    case extreme
    case subtle
    case neutral

    var color: Color {
        switch self {
        case .extreme: PhotonPalette.canvasExtreme
        case .subtle: PhotonPalette.canvasSubtle
        case .neutral: PhotonPalette.canvasNeutral
        }
    }

    /// VoiceOver 读的档位名。
    var name: String {
        switch self {
        case .extreme: "High contrast"
        case .subtle: "Soft grey"
        case .neutral: "Neutral grey"
        }
    }

    var next: CanvasBackground {
        CanvasBackground(rawValue: (rawValue + 1) % CanvasBackground.allCases.count) ?? .extreme
    }
}

/// 画布区域：按图像比例内接，Metal 视图跑 HDR 渲染。
/// 尺寸是显式常量，所以三栏开合时画面能跟着做缩放动画。
/// 长按画布 1 秒切下一档背景；档位是纯视觉状态，跨启动记住。
struct CanvasView: View {
    let image: LinearImage?
    let identity: BaseIdentity?
    let uniforms: HighlightUniforms

    @AppStorage("canvas.background") private var background: CanvasBackground = .extreme

    var body: some View {
        GeometryReader { proxy in
            let size = fittedSize(in: proxy.size)
            // 没有图像时不挂 Metal 视图：它的清屏色和 letterbox 是黑的，会盖住浅色背景。
            if image != nil {
                MetalCanvas(image: image, identity: identity, uniforms: uniforms)
                    .frame(width: size.width, height: size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .animation(.smooth(duration: 0.3), value: size)
            }
        }
        .background(background.color)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1) {
            background = background.next
        }
        .clipped()
        // 长按切背景在 VoiceOver 里做不到，给一个命名动作。
        .accessibilityElement()
        .accessibilityLabel("Canvas")
        .accessibilityValue(background.name)
        .accessibilityHint("Long press cycles the background")
        .accessibilityIdentifier("judge.canvas")
        .accessibilityAction(named: "Next background") { background = background.next }
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        let width = max(available.width - 48, 0)
        let height = max(available.height - 48, 0)
        let ratio: CGFloat
        if let image, image.size.height > 0 {
            ratio = CGFloat(image.size.width) / CGFloat(image.size.height)
        } else {
            ratio = 3 / 2
        }
        return width / height > ratio
            ? CGSize(width: height * ratio, height: height)
            : CGSize(width: width, height: width / ratio)
    }
}

private struct MetalCanvas: UIViewRepresentable {
    let image: LinearImage?
    let identity: BaseIdentity?
    let uniforms: HighlightUniforms

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .rgba16Float
        view.isOpaque = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        // 画布在 v1 没有手势；关掉交互，让长按稳定地落到外层画布容器上。
        view.isUserInteractionEnabled = false
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }
        if let device = view.device, let renderer = CanvasRenderer(device: device) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
            renderer.update(image: image, identity: identity, uniforms: uniforms)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.update(image: image, identity: identity, uniforms: uniforms)
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: CanvasRenderer?
    }
}

/// 三档并排，深浅色各一张，用来比较。
private struct CanvasBackgroundSpecimen: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(CanvasBackground.allCases, id: \.self) { $0.color }
            }
            HStack(spacing: 0) {
                Text("黑/白").frame(maxWidth: .infinity)
                Text("深灰/浅灰").frame(maxWidth: .infinity)
                Text("中灰").frame(maxWidth: .infinity)
            }
            .font(.caption)
            .padding(.vertical, 8)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

#Preview("Canvas background · light") {
    CanvasBackgroundSpecimen()
}

#Preview("Canvas background · dark") {
    CanvasBackgroundSpecimen().preferredColorScheme(.dark)
}
