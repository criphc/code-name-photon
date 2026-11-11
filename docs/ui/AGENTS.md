---
type: agent
owner: docs/ui
updated: 2026-11-08
---

# docs/ui

v1 的 UI 决策、约束、验收条件，以及 agent 在这个阶段的协作方式。**不写数值**：颜色、间距、字号一律在 `design/Sources/Tokens`。

## 与用户的协作方式

用户的当场要求高于本文；这里记录的是他在 v1 提出的规则。

### UI 设计阶段（草稿还在改的时候）

- **不许自主工作**。不要列计划，如果工作复杂到需要列计划，说明用户给的工作太多了。要把工作分拆回报给用户，由用户再做决定。
- **less is more**。用户会逐行读代码；能少写就少写，先给可运行的小样，不要一次铺开。写的越少，用户读的越快，迭代的就越快。
- **一次只改一个组件**；同一屏的多个方案放在 `#Preview` 里摆出来，由用户比较后收敛，不替用户拍板视觉。
- **UI 问题必须问**：布局、层级、交互方式、控件选型都属于「必须问」，不要自行决定。
- **验收方式**：改完留 `#Preview`，用户自己看 Xcode canvas。agent 不启动模拟器、不截图；可以用 headless preview 自检。在用户明确表示“工作阶段性完成”之前不要做headless preview之外的验收。
- 用户会阶段性在 iPad 上实机验收；没有用户确认的改动不算完成。

## 写文档的规则

- 在用户明确表示“工作阶段性完成”之前不要修改文档。避免上一轮写的下一轮马上又要改。
- `docs/ui/`目录只写决策、约束、状态、验收条件；数值在代码里。
- 一个事实只写一次：跨阶段的决定进 `docs/decisions/`，进度进 `docs/ui/plan/v1-plan.md`，这里只留 UI 特有的经验与规则。
- 新经验先归到 `reference/` 的对应主题，不要另起「杂项」。
- 工作阶段性完成后，把你觉得对以后的agent有用的UI工作经验（容易犯的错误，debug经验等）分类总结到`docs/ui/reference`里。


## 去哪看

- 每块屏的规格（区域 / 状态 / 控件 / 验收） → [spec/00-index.md](spec/00-index.md)
- 无障碍与 identifier → [reference/accessibility.md](reference/accessibility.md)
- Token 与 Specimen → [reference/tokens.md](reference/tokens.md)
- SwiftUI 布局 / 工具栏 / 动画 → [reference/swiftui-layout.md](reference/swiftui-layout.md)
- 按钮的按下 / 长按 / 双击判定 → [reference/gestures.md](reference/gestures.md)
- `#Preview` 与 headless 验收 → [reference/previews.md](reference/previews.md)
- 接 `SessionModel` / `JudgeModel` → [reference/models.md](reference/models.md)
- Metal 画布与直方图性能 → [reference/canvas.md](reference/canvas.md)
- 当前进度与待决策 → [plan/v1-plan.md](plan/v1-plan.md)
- app 侧入口事实 → [../../apps/ios/AGENTS.md](../../apps/ios/AGENTS.md)
