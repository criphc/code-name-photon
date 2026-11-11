---
type: reference
owner: docs/ui
updated: 2026-11-08
---

# 无障碍与 identifier

每个交互元素都要能被 VoiceOver 读出来，并且有一个稳定的 identifier 给将来的 UI 测试。
两件事一起做，因为都要给元素命名。

## identifier 命名

`surface.element`，点数值打开滚轮的那种再加 `.value`：

| 面 | identifier |
|---|---|
| 连接页 | `connection.{host,port,token,tokenVisibility,connect}` |
| 判图页 | `judge.{canvas,compare,adjustments,undo,redo,more,submit}` |
| 调整栏 | `adjustments.{start,lift,transition,cap,histogram}`，滑条用基础名，点开滚轮的数值用 `.value` |
| 胶片条 | `filmstrip`、`filmstrip.empty`、`filmstrip.cell.<itemID>` |
| 状态条 | `status.{facts,headroom}` |

- **只给关键元素**：能操作的和测试要断言的读数。纯装饰不加。
- 胶片条格子的 id 用 wire 上的 item id，测试可以从 fixture 直接拼出来。
- identifier 是给测试的，**不替代** label；两者都要有。

## label / value / hint

- **label** 说这是什么（`Start`、`Compare`、`Display headroom`），不重复控件里的数字。
- **value** 说现在是什么。会变的才给：滑条数值、Compare 当前段、画布背景档、headroom。
- **hint** 只在操作方式不显然时给（`Opens the wheel picker`）。
- 图标按钮（工具栏、胶片条状态点）**必须**显式给 label —— 否则读的是 SF Symbol 的名字。
- 状态类读数读**人话**，不读符号：状态条右边读 `Display headroom, 2.0 stops`，
  不是 `@ 2.0 Stops`。
- Compare 的 value 读**已提交**的那一段，不读按住期间的预览 —— 预览是手势的中间态。

## 手势做不到的，补命名动作

三个操作在 VoiceOver 下没有等价手势，各给一个 `accessibilityAction(named:)`：

| 操作 | 手势 | 命名动作 |
|---|---|---|
| 切画布背景 | 长按画布 1 秒 | `Next background` |
| 进/出假色 | 从 A 双击 | `False colour` |
| 打开滚轮 | 轻点数值 | 默认动作（`.accessibilityAction { }`） |

新加手势时要问一句：VoiceOver 怎么做到？做不到就补一个命名动作。

## 还没做的

- 没有 UI 测试，identifier 目前只被 `#Preview` 和人工检查用。
- 没有 Dynamic Type 的逐屏验收，只有 `Shell · 长文件名 + 大字号 · 中` 一张预览。
