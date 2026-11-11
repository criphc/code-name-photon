---
type: reference
owner: docs/ui
updated: 2026-11-08
---

# SwiftUI 布局、工具栏与动画

## 三栏

- 结构固定为 `NavigationSplitView(sidebar:detail:)` + 在 detail 上挂 `.inspector`。`.inspector` 就是系统提供的带过渡的尾随列，**不要**自己用 `ArrangementView` 或第三个 `NavigationSplitView` 列来拼。
- **不要试图动画 `navigationSplitViewColumnWidth`**。给 `columnVisibility` 传自定义 `Binding`、在 setter 里 `withAnimation`，都不会让 detail 的列宽平滑变化——这是框架行为，不是写法问题。
- inspector 的宽度用 `inspectorColumnWidth(min:ideal:max:)`。

## 紧凑宽度（竖屏 / 分屏）

- 紧凑宽度下 `.inspector` 会变成**全屏 sheet**，把画布整个盖住。所以 `showsInspector` 和 `showsCompactInspector` 是两个状态：前者只喂 `.inspector`（`Binding` 里 `&& !isCompact` 强制收起），后者驱动底部面板。窄屏默认收起，否则一进判图页就顶掉半屏。
- 紧凑宽度下显示哪一列由 `preferredCompactColumn` 决定，**不是** `columnVisibility = .detailOnly`（402pt 下不生效，还是显示侧栏）。连上（含自动重连）就切到 `.detail`，返回按钮系统自带。
- 调整栏在紧凑宽度下贴在底部、和画布同屏，顶边 16pt 可拖动改高度；胶片条同时让位（`hidesFilmstrip`），把高度留给画布。
- 面板里的直方图压到 64pt（`AdjustmentsView(histogramHeight:)`），否则四个控件塞不下。

### 这块的动画做不出来，别再试

v1 决定**不加动画**，面板瞬时出现。试过并且都不行的三条路：

1. `withAnimation` 包按钮 + `.transition(.move(edge: .bottom))`；
2. `.animation(_:value:)` 挂在容器上（value 驱动）；
3. 挪到 `.safeAreaInset(edge: .bottom)`。

现象：画布和状态条会动，**面板本身不动**。原因是面板按固定尺寸被插入，自身没有可动画的几何——被挤压的兄弟视图（画布是弹性的）在动，面板只是"出现"。

另外两条实测的坑：

- 把 `List` 压到 `frame(height: 0)` 会**卡死整屏**（预览里 app 启动超时，可复现）。收起时那个位置必须放占位视图，不能放面板本身。
- 用 `onGeometryChange` 量 sheet 高度再让画布让位会形成反馈环：sheet 的 detent 按容器高度算，容器高度又被让位改掉，同一份代码两次渲出不同高度。

## 画布尺寸的缩放动画

detail 的列宽变化是瞬时布局变化；要让画面平滑缩放，必须让画布尺寸成为**显式可动画值**：

```swift
GeometryReader { proxy in
    let size = fittedSize(in: proxy.size)          // 按图像比例内接
    content
        .frame(width: size.width, height: size.height)
        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        .animation(.smooth(duration: 0.3), value: size)
}
.clipped()
```

- 只加 `.animation(.smooth, value: 某个状态)` 而不把尺寸显式写出来，画面仍然瞬移。
- 尺寸来自 `aspectRatio(.fit)` 的**结果**时无法插值；必须由自己算出宽高再 `.frame`。
- 外层 `.clipped()` 是必须的：动画中间帧可能比当前容器大，不裁会画到相邻栏上、把兄弟视图顶走。

## 弹性视图与高度

- **横向 `ScrollView` 在竖直方向是弹性的**。放进 `VStack` 会和其它弹性视图平分空间，看起来像「上下大量留白」。要么 `.frame(height:)` 固定，要么 `.fixedSize(horizontal: false, vertical: true)` 让它等于内容高度。
- 用 `LazyHStack` 也不要指望它有内在高度；同样处理。

## 拖动改高度

- 拖动某个视图来改它自己的尺寸时，手势要用 `DragGesture(coordinateSpace: .global)`，并在第一次 `onChanged` 时抓住起始值：

```swift
.onChanged { value in
    let start = dragStart ?? height
    dragStart = start
    height = min(max(start - value.translation.height, minHeight), maxHeight).rounded()
}
.onEnded { _ in dragStart = nil }
```

- 用默认的 `.local` 坐标会抖：视图随着手势移动，下一帧的 `translation` 基准也变了，形成振荡。
- 高度取整，避免亚像素反复触发重排。

## 工具栏

- 用 `ToolbarSpacer(.fixed)` 把主操作和左边的工具组分开；同一组内用 `ToolbarItemGroup`。
- 主操作用 `.buttonStyle(.glassProminent)`；普通项保持系统默认样式，不要自制带底色的按钮。
- 编辑类界面用 `.toolbarTitleAlignment(.leading)` + `.toolbarTitleDisplayMode(.inlineLarge)`。
- 底部状态条用 `.safeAreaBar(edge: .bottom)`，不要再手写一条固定高度的 bar。它只负责布局（内缩安全区、跟随滚动边缘效果），**自己不画底**：要材质就自己 `.background(.bar)`。
- 相邻两块共用同一种材质时会连成一片、看不出边界。状态条和胶片条都是 `.bar`，所以中间留一条 `Divider()` —— 胶片条顶部的拖动区就是靠它定位的。
- 工具栏里 `Menu` 收不常用的开关；能并进已有控件的档位就别新增控件（例：假色并进 Compare 的三段）。不要把所有开关都摊平。
- 工具栏按钮上的手势按下会迟到：按住 / 长按 / 双击的判定方式见 [gestures.md](gestures.md)。

## 其它

- 连接状态、空态优先用系统组件（`ContentUnavailableView`、`Label`），不要手写图标+文字的组合。
- 选中态用描边（`strokeBorder` + `AnyShapeStyle` 做条件）而不是改填充色，缩略图内容不会被遮住。
- 列表里的参数行用 `List`/`Form` + 原生 `Slider`；自制的胶囊滑条在触摸和 Dynamic Type 上都要重新解决一遍。
