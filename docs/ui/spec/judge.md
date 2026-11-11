---
type: reference
owner: docs/ui
updated: 2026-11-10
---

# 判图页

detail 列。看图、对比、切换素材、提交 recipe。画布是 Metal/EDR，渲染数学在 ClientKit
的那份 MSL 里，app 只是调用方。

## 区域

自上而下：

1. **工具栏**：左边 Undo（Redo 只在撤销过之后出现）；右边 Compare、调整栏开关、溢出菜单；
   最右 Submit（prominent）。标题是构建号，用来确认屏幕上是不是最新代码。
2. **画布**：按图像比例内接，四周留白；背景三档（长按画布循环）。没有图像时显示空态。
3. **状态条**：画布与胶片条之间，与胶片条同材质。左边预览尺寸/色域/位深，右边显示器
   headroom。空态与加载态见下。
4. **胶片条**：缩略图 + 选中描边 + 右下角提交状态点；顶部一条可拖动改高度的区域。
5. **调整栏**：常规宽度是 inspector 列，紧凑宽度是底部面板（[adjustments.md](adjustments.md)）。

## 状态

- **没有图像**：状态条左边 `No image`、右边占位 `@ — Stops`（那时没有 EDR 内容，
  屏幕报的 headroom 读不出意义）。胶片条空批次时显示一条中性文案。
- **加载中**：状态条左边 `Loading…`，右边仍是占位。
- **有图像**：状态条给出尺寸/色域/位深和 headroom 的 stops。
- **提交中**：Submit 转圈；胶片条当前格显示进度；调整栏禁用。
- **错误 / 提交结果**：一律 `.alert`，不进状态条。提交成功的正文先是 `item 名 · renderKey 前 8 位`，
  再接模型给的那句话。

## 控件

- **Compare**：三段（原样 / SDR 基座 / 假色）。轻点 A↔B；从 A 双击进 C；C 里任何操作回 A 并冷却；
  按住预览松手会落到的另一段，长按松手不提交，拖出取消。判定方式见
  [gestures.md](../reference/gestures.md)。
- **调整栏开关**：常规宽度切 inspector 列，紧凑宽度切底部面板。
- **溢出菜单**：复制/粘贴调整（只带四个 hdr 参数），以及一个 DEBUG-only 的临时清缓存项（验收后删）。
- **Undo / Redo**：一条全局时间线，编辑和切换图片都算一步。
- **胶片条**：轻点切换；顶部拖动改高度。
- **画布**：长按 1 秒切背景档，档位跨启动记住。

## 验收

- `#Preview`：`Shell · 已连接 · 有素材 · {窄,中,宽}`、`Shell · 空批次 · 宽`、
  `Shell · 长文件名 + 大字号 · 中`（`App/PreviewSupport.swift`）。
- identifier：`judge.{canvas,compare,adjustments,undo,redo,more,submit}`、`filmstrip*`、`status.*`。
