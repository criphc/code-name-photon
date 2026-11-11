---
type: reference
owner: docs/ui
updated: 2026-11-10
---

# 连接页

左栏。唯一职责是把 `SessionModel` 的 host / port / token 填好并连上；不显示任何批次内容。
目录树、`⚙` 设置 sheet 都不在 v1。

## 区域

自上而下，每一块都是独立的 `Section`：

1. **已连接摘要**：`Server`（host:port）与 `Items`（数量）。只在 `.connected` 出现。
2. **Host / Port**：两个 `LabeledContent` 包着右对齐的 `TextField`。
3. **Token**：明文/密文可切换，footer 说明 token 从哪来。
4. **上一次的服务器**：`Use Last Server` + host 副标题。只在本次启动连成功过一次之后出现。
5. **通知块**：图标 + 文案，颜色随 severity。只在 `session.notice` 非空时出现。
6. **Connect**：主操作，整宽。下面是 `Debug Quick Connect`（DEBUG-only 调试入口，保留到不再需要连真实调试 server 为止）。
7. **底部状态条**：`.safeAreaBar` + 与判图页同一种材质，四态文案见状态矩阵。

## 状态

- **连接中**：Host / Port / Token 三段 `.disabled`，Connect 换成 `ProgressView` + `Connecting…`。
- **已连接**：摘要出现；表单仍可编辑，改完再点 Connect 会重连。
- **错误**：notice 块出现，状态条转红；`Retry` 不在这里，重连就是再点一次 Connect。

## 控件与范围

- 三个字段直接绑定 `SessionModel`，没有本地副本；`Use Last Server` 一次性写回三个字段。
- Connect 在 `!session.isConfigured` 或连接中禁用。
- Token 的显示切换是纯视觉状态（`@State`），不写回模型。

## 验收

- `#Preview`：`ConnectionSetupView`（`Features/Connection/ConnectionSetupView.swift`）。
- 外壳：`Shell · 未连接 · 窄`（`App/PreviewSupport.swift`）。
- identifier：`connection.{host,port,token,tokenVisibility,connect}`，见
  [accessibility.md](../reference/accessibility.md)。
