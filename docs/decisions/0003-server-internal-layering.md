---
type: decision
owner: docs
updated: 2026-11-05
---

# ADR-0003：server 包的分层（EngineKit / ServerKit / ServerControl / appctl）

- 状态：已接受（2026-11-05，P0）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) R1、R3、R5
- 影响阶段：P2

## 背景

stage 1 的 `app/` 里，`PhotonCore`（渲染/编码/验证/交付）和 `PhotonServer`（HTTP/wire/队列）
只靠 target 边界分开；CLI 在一个 target 里同时做 prep / serve / deliver。现在多了 macOS 壳，
如果 GUI 直接依赖 `PhotonServer`，那么 GUI 迟早会把 server 逻辑拉进进程内（见
[ADR-0002](0002-macos-gui-wraps-appctl.md)）。

## 决策

`server/` 包拆成五个 target，三条边界不合并：

| target | 职责 | 不做什么 |
|---|---|---|
| `EngineKit` | 渲染 / 编码 / 验证 / 交付（原 `PhotonCore`） | HTTP、进程管理、CLI 参数 |
| `ServerKit` | HTTP / wire / 队列 / `serve`（原 `PhotonServer`） | 颜色管线、交付编码 |
| `ServerControl` | GUI↔CLI 进程契约：启动配置、readiness、日志、退出/终止状态机 | 链接 `EngineKit` / `ServerKit`、起真实进程（由注入的执行器做） |
| `appctl` | 薄 CLI，唯一 server 入口（`serve`、`deliver` 等子命令） | 业务逻辑 |
| `ServerTestSupport` | 只给测试用的假进程/夹具 | 进产品依赖图 |

关键约束：

- `ServerControl` 只依赖 `ContractKit`（IPC 事件）与 Foundation；进程状态机必须能用假进程/假
  readiness 在 headless 测试里跑完（[ADR-0010](0010-appctl-process-contract.md)）。
- `appctl` 是 `serve` 的唯一入口；GUI 通过子进程调用它，不 import `ServerKit`。
- `ServerKit` 依赖 `EngineKit`（serve 要 prepare/deliver）与 `ContractKit`（wire 类型）。
- `ServerTestSupport` 不参与 app 链接。

## 后果

- engine 的行为（8 项交付检查、report、`AtomicFile`、编码参数）在搬家时保持原样；只是换个
  target 名。
- GUI 的测试面很小：`ServerControl` 的状态机 + IPC 事件，不启动真实 server。
- 原有 `PhotonCoreTests` / `PhotonServerTests` 拆成 `ServerKitTests` / `ServerControlTests` /
  `IntegrationTests`；engine 测试跟着 `EngineKit` 走。

## 备选与取舍

- **只拆 `EngineKit` + `ServerKit`**：GUI 会依赖 `ServerKit`，边界在 GUI 侧破掉；拒绝。
- **`ServerControl` 放进 macOS app**：状态机无法 headless 测试，且与 P4 的 app 生命周期耦合；
  拒绝（R5：可测状态机必须进 package）。
- **CLI 与 server 同 target**：`appctl` 无法保持薄；拒绝。

## 验证

P2 的 `make test` + `make integration` + 交付 gate；`ServerControlTests` 用假进程覆盖
starting/ready/running/failed/stopped、退出码、SIGTERM 超时升级。
