---
type: reference
owner: docs/ui
updated: 2026-11-08
---

# 画布（Metal/EDR）与直方图

## MSL 只有一份

- 着色器是 `client/Sources/ClientKit/Shaders/HighlightShape.msl`，通过 `ShaderResource` 在运行时编译（ADR-0008）。app 侧只负责绑定和调用，**数学不复制**。
- `HighlightUniforms` 的结构布局是 MSL 与 Swift 的契约；改它必须同时改 MSL 和 parity 测试。
- 绑定：compute 用 `highlightShapeKernel`（base 纹理 0、中间纹理 1、uniforms buffer 0）；present 用 `presentVertex` / `presentFragment`（uniforms buffer 0、源纹理 0、sampler 0）。

## EDR 配置（iOS）

- `MTKView.colorPixelFormat = .rgba16Float`。
- `(view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true`，并把 `colorspace` 设为 extended linear Display P3。
- `MTKView.colorspace` 在 iOS 上不可用（macOS 专用），要设在 layer 上。
- 1.0 = SDR 白，大于 1.0 的部分由 EDR 呈现；present 阶段的字体/黑边是纯黑。

## 显示器 headroom

- 两个属性不是一回事，别混用：`currentEDRHeadroom` 是**现在**能给的（随亮度变，亮度越低 headroom 越高；也随屏幕是否在显示 EDR 内容变），`potentialEDRHeadroom` 是面板常数，只有配置变化（如参考模式）才动，**不随亮度变**。要「当前判图条件」就用 current，要「这台屏幕的上限」才用 potential。
- 没有 EDR 图层时 `currentEDRHeadroom` 读 1.0。所以画布不挂 Metal 视图时它没有意义——状态条那时显示占位，而不是 `@ 0.0 Stops`。
- 有图但画面里没有超过 SDR 白的高光时，current 也可能读到 1.0。那是真实读数，不是 bug。
- 没有变更通知，只能轮询（接线见 [models.md](models.md)）。

## 画布视图本身

- **没有图像时不要挂 Metal 视图**：`MTKView` 的清屏色和 MSL 的 letterbox 都是纯黑，没有纹理时 present 什么都不画，于是露出一块黑色 3:2 方块。黑底时看不见，换浅色背景就是一整块黑。
- `MTKView` 是 UIView，默认吃触摸。画布上要挂 SwiftUI 手势（背景档位长按）时显式 `isUserInteractionEnabled = false`，别让「图像区响不响应」由 UIKit 命中测试决定。
- MSL 的 letterbox 返回 `float4(0,0,0,1)`，而 fit 出来的 frame 是分数点、drawable 是整数像素，对不齐时会在一条边上留 ≤1 设备像素的黑线。浅色背景下可能看得出来；要治得改 MSL（engine 冻结），不是在外面垫一层背景色。

## 上传与重绘

- base 是 `Float32` 线性 P3，尺寸大（几千万像素 → 几十 MB）。**只在 `BaseIdentity` 变化时重传**，用 `BaseUploadGate` 判断；参数变化只重跑 compute。
- 不要每帧重算：`isPaused = true` + `enableSetNeedsDisplay = true`，数据或参数变化后 `setNeedsDisplay()`。
- base 纹理用 `rgba32Float`（shared），中间纹理用 `rgba16Float`（private）。上传在主线程，切片/选中时会有一次明显停顿；优化方向是异步上传，不是缩小精度。
- 画布的 fit 在 present 阶段完成（shader 里做 aspect fit + letterbox）。要做 zoom/pan 就得改 present 的 uniform 契约，不是加一个 SwiftUI 手势。

## 直方图

- 数据从 `LinearImage` 算：对每个采样点套 `HighlightShape.gain(luma:)`，再按显示坐标分桶。**不要**为直方图再写一套增益数学。
- 横轴上限跟着 cap 走：左半 SDR 线性 0…1，右半 0…log2(cap) stops，每个整数 stop 一条虚线，SDR 白处一条实线。上限来自 recipe，所以仍然一次扫描就能出图，不需要先求最大亮度；cap 变了由 `.task(id:)` 连同其他参数一起重算。
- 计算放后台（`Task.detached`），参数变化用 `.task(id:)` + 短防抖 + `Task.isCancelled`：拖动滑条时只在停手后扫一遍像素。
- 采样可以隔行隔列（统计量，不需要逐像素）；四条曲线共用同一个归一化因子，相对高度才有意义。
