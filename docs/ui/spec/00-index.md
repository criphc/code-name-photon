---
type: reference
owner: docs/ui
updated: 2026-11-10
---

# 屏清单与状态矩阵

v1 只有三块界面，都在 `apps/ios/Sources/Features/`。规格从已经收敛的实现反向写，
**数值不在这里**：视觉值在 `design/Sources/Tokens`，控件范围在 [recipe.md](../../reference/recipe.md)。

| 屏 | 源码 | 规格 |
|---|---|---|
| 连接页（左栏） | `Features/Connection/` | [connection.md](connection.md) |
| 判图页（detail） | `Features/Judge/`、`Features/Library/` | [judge.md](judge.md) |
| 调整栏（inspector / 底部面板） | `Features/Judge/AdjustmentsView.swift` | [adjustments.md](adjustments.md) |

## 状态矩阵

三块界面共享 `SessionModel.phase` / `JudgeModel.phase`，但各自只在其中几态下出现。

| 状态 | 连接页 | 判图页 | 调整栏 |
|---|---|---|---|
| 未连接 | 表单可编辑，状态条 `Not connected` | 不可达（紧凑宽度停在这一栏） | 不可达 |
| 连接中 | 表单禁用，按钮转圈 | 不可达 | 不可达 |
| 已连接 · 空批次 | 多出 `Server` / `Items` 摘要 | 画布 `No image`，胶片条 `No items` | 滑条禁用 |
| 已连接 · 有素材 | 同上 | 选中项加载中 → 画布清空（加载前 `review = nil`），状态条 `Loading…`；缓存命中则立即显示 | 加载中禁用，到位后可编辑 |
| 提交中 | — | Submit 转圈，胶片条该格显示进度 | 禁用 |
| 错误 | notice 块 + 状态条 `Connection failed` | alert（不占状态条） | 随判图页 |

## 宽度

- **常规宽度**（iPad 横屏、竖屏）：三栏并排，调整栏是 detail 的 inspector 列。
- **紧凑宽度**（iPhone、iPad 分屏）：一次只显示一栏，连上后自动落在判图页；调整栏变成
  底部内嵌面板，展开时胶片条让位。细节见 [swiftui-layout.md](../reference/swiftui-layout.md)。
