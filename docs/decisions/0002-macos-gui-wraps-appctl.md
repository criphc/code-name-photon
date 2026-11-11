---
type: decision
owner: docs
updated: 2026-11-05
---

# ADR-0002：macOS GUI 是 `appctl` 的子进程套壳

- 状态：已接受（2026-11-05，P0）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) §1、R3、R6；进程契约见
  [ADR-0010](0010-appctl-process-contract.md)
- 影响阶段：P0（验证）、P4（实现）

## 背景

原型只有 CLI：`photon serve` 起 LAN 服务，iPad 连接判图，`photon deliver` 在命令行显式触发。
stage 2 要一个「不碰命令行就能起 server，并监控运行状态与日志」的 macOS app。此时有两条路：

1. 把 `ServerKit` 编进 GUI，在进程内起服务；
2. GUI 只管理一个 `appctl serve` 子进程。

## 决策

macOS GUI 的**唯一职责**是 `appctl` 的套壳：

- 启动 / 停止 / 重启 / 监控 `appctl serve` 子进程；
- 展示状态（starting / ready / running / failed / stopped）、退出码、stdout/stderr 日志；
- 展示配对信息（host / port / token）；
- 不内置 `ServerKit`、不走 loopback 客户端、不做判图 UI、不做常驻 daemon / launchd。

GUI ↔ CLI 的契约是**进程契约**：

- argv/env：port、token、inbox（`--batch`）、work 目录；
- readiness：`appctl serve` 在 stdout 打一行机器可读的 ready 事件（含 port/pid）；
- 日志流：stdout/stderr 由 GUI 捕获；
- 退出码 + SIGTERM 优雅停止（超时后强制终止）。

`appctl` 仍是唯一 server 入口；GUI 不复制任何 server 逻辑。打包时 GUI 使用 app bundle 内的
helper `appctl`（`make macos-build` 先构建再拷贝/签名），开发期可指向仓库构建产物。

## 后果

- GUI 崩溃或退出不会留下内嵌的引擎状态；server 的生命周期完全由子进程表达。
- GUI 无法在进程内调用 `ServerKit` 的管理 API —— 需要观察/控制的东西必须走可序列化事件
  （[ADR-0004](0004-wire-contract-single-source.md) 的 `ContractKit/IPC`）。
- 进程状态机必须可 headless 测试（注入假进程/假 readiness），不能只在 GUI 里手点。

## 备选与取舍

- **GUI 内嵌 `ServerKit`**：等于第二个 server 入口，崩溃域合并，打包/沙盒更复杂；拒绝。
- **launchd / 常驻 daemon**：生命周期和权限模型超出这一轮，且与「GUI 起停」语义冲突；拒绝。
- **GUI 用 loopback `ClientModel` 观察队列**：等于再写一个客户端，且会把未定的 wire 队列状态
  提前固化；本阶段不需要，拒绝。将来若 macOS 要展示 items，走 wire 读接口加模型。

## 验证

P0 spike C（[ADR-0010](0010-appctl-process-contract.md)）先证明：spawn、ready 行解析、日志捕获、
SIGTERM 优雅停止、超时升级 SIGKILL、退出码，全部可在无 GUI 的测试里断言。P4 的
`make macos-build` + 手点 smoke（从 GUI 起 server，iPad 能连）是最终门禁。
