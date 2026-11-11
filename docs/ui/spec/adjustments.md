---
type: reference
owner: docs/ui
updated: 2026-11-10
---

# 调整栏

一个 HDR 操作：直方图 + 三个滑条 + cap picker。常规宽度是 detail 的 inspector 列，
紧凑宽度是判图页底部的内嵌面板。

## 区域

1. **直方图**：RGB 三色线 + luma 填充。横轴左半是 SDR 线性，右半是 0…cap 的 stops，
   每个整数 stop 一条虚线。紧凑宽度下压矮，好让四个控件塞进底部面板。
2. **HDR Adjustments**：`List` 的 insetGrouped 分组，四行：
   - **Start**：滑条 + 数值
   - **Lift**：滑条 + 数值
   - **Transition**：滑条 + 数值
   - **Cap**：只有数值，点它弹滚轮（没有滑条）

## 状态

- **没有图像 / 加载中**：四行全部禁用，直方图空着。
- **可编辑**：拖动滑条即时改画布；松手才记一步历史。
- **提交中**：全部禁用。

## 控件与范围

- **范围与默认值来自 `meta.recipeDefaults` 和 recipe schema**，UI 不写第二套；见
  [recipe.md](../../reference/recipe.md)。
- **三个滑条**：拖动是连续的；点数值弹滚轮做精细选择；双击**滚轮**复位到默认值
  （双击滑条收不到，滑块被原生控件吞掉 —— 见 [gestures.md](../reference/gestures.md)）。
- **Cap**：只在 stops 域里编辑，六个档；写回 wire 时转成线性倍数。默认模板值可能不在这六档里，
  打开滚轮时预选最近档，只有真的滚动了才写回。
- **一次连续编辑 = 一步历史**：拖动、滚轮会话、复位都靠 `onEditingChanged` 括起来；粘贴
  在溢出菜单入口处直接 `history.apply` + `recordEdit` 记一步（结果一致：一步历史，机制不同）。

## 验收

- `#Preview`：`AdjustmentsView`、`ParamRow`、`CapPicker`、`CapStopsWheel`、`HistogramView`。
- 外壳：`Shell · 已连接 · 调整栏展开 · 窄`。
- identifier：`adjustments.{start,lift,transition,cap,histogram}`，滑条与滚轮入口分别带
  `identifier` 和 `identifier.value`。
