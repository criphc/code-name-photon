---
type: reference
owner: docs/ui
updated: 2026-11-10
---

# `#Preview` 与 headless 验收

## 交付方式

- 每个有状态的视图至少一个 `#Preview`；需要 `@State` 的预览用 `@Previewable`。
- 回复里指出**文件 + 行号 + 该看哪个预览**，用户自己在 Xcode canvas 里看；这是本项目的验收方式（见 [AGENTS.md](../AGENTS.md)）。
- 需要用户比较多个方案时，把方案做成多个 `#Preview`（或一个预览里的多列），不要只给一段说明。
- 预览要能离线跑：占位数据直接写在预览里，不要依赖服务器或网络。

## 多宽度与状态矩阵

- 用 `#Preview(traits: .fixedLayout(width:height:))` 固定尺寸，比换设备快，而且能写进代码。`NavigationSplitView` 的列行为跟着容器宽度走，所以固定尺寸能真的复现紧凑布局。
- 外壳预览要用**真实的三栏结构**（`ProductRootView`），不要只预览调整面板；否则看不到容器适配问题。
- 需要「已连接 / 有素材」这类状态时，用 `#if DEBUG` 的假 transport（`apps/ios/Sources/App/PreviewSupport.swift`）：实现 `health` + `listItems` 就够（connect 先探 health），其余端点抛错。**不要**为了预览连真实 Mac，也不要另写一套模型逻辑。
- 画布是 Metal/EDR，预览里本来就看不到，所以假 transport 不伪造 base —— 画布停在 `No image` 是对的。
- 状态用 `.task { await session.connect() }` 灌进去；静态快照会等它跑完。

## headless 渲染（Xcode MCP 的 `RenderPreview`）

- 可以指定设备（iPad Pro / iPad mini 等）和方向变体；能渲染出 PNG 给 agent 自查。
- 静态快照只代表**一帧**。涉及过渡、弹层、表单位置时用 `displayMode: "interactive"` + `snapshotDelay` 让它落定。
- 渲染前 `BuildProject` 或单文件诊断先过一遍，省得对着过期产物判断。

## 快照不可信的几种情况

1. **缓存旧图**：同一文件连续渲染可能返回同一张图（sha 相同）而不是新代码的结果。改动后第一次渲染若和预期完全不符，先重渲染一次再看。
2. **动画中间帧**：刚触发的 `.animation(value:)` 会让画布停在「缺失、过大、错位」的中间状态，看起来像布局炸了。用 interactive + 延迟，或临时把初始值改成稳定态再看。
3. **Metal 图层不出现在快照里**：`MTKView` 的内容常常是空白；不能用快照判断画布对不对，只能确认布局和编译。
4. **popover / alert / sheet 只出现一部分或不出现**：这是快照机制的限制，不是实现问题。
5. **同一 `#Preview` 的 `sourceLineNumber` 变了但图没变**：多半是缓存，不信图、信代码。

结论：headless 渲染用来抓**布局回归**和**编译错误**；视觉结论以用户实机为准。

## 预览与真实设备的差异

- preview 不跑真实的 display headroom，EDR 的观感必须在 iPad 上看。
- `safeAreaBar`、inspector 的紧凑行为、工具栏溢出菜单在不同宽度下表现不同；验收时至少看横屏与一个较窄宽度。
- 紧凑宽度下 `.inspector` 会变成 sheet，而 `showsInspector` 默认是 `true` —— 一进 app 就先弹调整栏，盖住整屏。多宽度预览第一次跑就抓到了这个。
- 编辑器里的预览窗口尺寸可以拖，用它验三种宽度比换设备快。
