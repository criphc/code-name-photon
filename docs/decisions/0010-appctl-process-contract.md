---
type: decision
owner: docs
updated: 2026-11-06
---

# ADR-0010：`appctl` 的进程契约与 `ServerControl` 状态机

- 状态：已接受（2026-11-05，P0，spike C 通过；2026-11-06 修订 token 口径与 GUI 措辞）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) R1、R3、R4、R5；
  [ADR-0002](0002-macos-gui-wraps-appctl.md)、[ADR-0004](0004-wire-contract-single-source.md)
- 影响阶段：P1（IPC 类型）、P2（`appctl serve` + `ServerControl`）、GUI 接入（macOS GUI，推迟）

## 背景

GUI 只做 `appctl` 的套壳（ADR-0002），所以「进程怎么起、怎么知道它 ready、怎么停」必须是一份
明确、可 headless 测试的契约。stage 1 的 `photon serve` 只有人类可读的启动日志，没有机器事件；
GUI 不能靠解析自由文本，也不能把 server 逻辑编进 app。

## 决策

### 1. 启动：argv + env

`appctl serve` 的 GUI 启动形态：

```text
appctl serve --port <1..65535> --batch <inbox-dir> --work <work-dir> [--log-level info]
```

- token 的实际口径：**GUI 启动 `appctl serve` 时 token 只走环境变量**（`PHOTON_APPCTL_TOKEN`；
  `appctl` 同时兼容 `$PHOTON_TOKEN`），**绝不进 argv**（`ps` 对同机用户可见）。CLI 仍接受
  `--token <value>` 供人工本地使用；该形态下 token 在 argv 中可见是已知取舍。
- **P2 只支持固定端口**（1…65535，默认 8787）；ready 事件里的 `port` 是实际绑定值，仍为权威。
  `--port 0`（OS 分配）留给 macOS GUI（推迟）再评估，当前 CLI 显式拒绝 0。
- 其余环境：`NO_COLOR=1`（日志无 ANSI），GUI 清理自身不需要的变量；子进程不继承 GUI 的
  `HOME` 之外的敏感变量（实现时白名单）。
- `appctl` 仍是唯一 server 入口；GUI 不 import `ServerKit` / `EngineKit`。

### 2. 就绪：stdout 上一行 JSON

`appctl serve` 在开始服务后，向 **stdout** 写**恰好一行**行分隔 JSON：

```json
{"schema":0,"event":"ready","port":8787,"pid":123}
```

规则：

- `schema` 必须为 `0`；`port` 必须 1…65535；`pid` 可选（信息性；supervisor 以
  `Process.processIdentifier` 为准）。
- **stderr 永远不解析**，只作为人类日志捕获。
- ready 之前的 `{"schema":0,"event":"error","message":"…"}` → `failed(.protocolViolation(message))`，
  并停止子进程；其他 ready 之前的行按日志保留（启动诊断可见）。
- ready 之后的行（stdout 或 stderr）一律作为日志行，不再改变状态。
- `appctl` 写 ready 后必须 flush stdout，并忽略 `SIGPIPE`（GUI 消失时不要因写管道而猝死）。

### 3. 状态机与退出

`ServerControl` 的非 GUI 核心（`ContractKit/IPC` + 进程监督）：

```text
idle → starting → ready(ReadyInfo) → running(ReadyInfo) → stopping → stopped(ExitInfo)
             ↘ failed(SupervisorFailure)        （任意状态）
```

- `ExitInfo` 至少含：`terminationReason`（`.exited(code)` / `.uncaughtSignal(sig)` / `.unknown`）、
  `requestedStop`、`escalatedToSIGKILL`、`ranFor`、stdout/stderr 捕获字节数。
- `stop()`：`SIGTERM` → 等待 `terminationGracePeriod`（默认 3 s）→ 仍存活则 `SIGKILL` →
  等待退出/管道 EOF。`Process.terminate()` 就是 `SIGTERM`，不是关闭 RPC。
- `requestStop()`：只发 `SIGTERM` 并立即返回，供 app 退出钩子使用。
- 必须同时排空 stdout 与 stderr（单侧 1 MB 也不能死锁）；终止后等管道 EOF 再定格退出信息；
  不要用 `waitUntilExit` 阻塞主线程。
- 超时与退出竞争不能用「TaskGroup 里谁先完成」实现（输的一方会拖住 group，SIGTERM-ignoring
  子进程会死锁）；用 resume-once 的 box/continuation。
- 测试注入点（R1 要求 headless）：`LaunchConfiguration`（可执行文件/argv/env）、
  `SupervisionPolicy.sleeper`（ready timeout / grace / post-kill wait 全部可注入）、
  `AsyncStream` 事件 + `snapshot`，`start()` 在 stopped/failed 后可重启。

### 4. app 退出路径

- AppKit 的 `applicationShouldTerminate` 里**只同步发 SIGTERM 并立刻返回 `.terminateNow`**；
  不要 `.terminateLater` 等异步停止——AppKit 的嵌套事件循环不会正常排空主队列（spike 里实测
  死锁），也不要在主线程 semaphore 等子进程。
- 子进程若在 GUI 被 SIGKILL 时仍存活，需要 parent-death watchdog（见「macOS GUI（推迟）开放风险」）。

### 5. `ContractKit/IPC` 的范围

- P1 只落可序列化事件：`ReadyEvent`（ready 行）与 `ErrorEvent`（预就绪 error 行）。
- `SupervisorState` / `ExitInfo` / 日志行是 `ServerControl` 的**内部模型**，不是 IPC 事件，
  不进 `ContractKit`。
- 如果 macOS GUI（推迟）需要 CLI→GUI 的持续状态事件，再加 `StatusEvent`（`event:"status"`）并按 schema
  版本演进；不要在 ready 行里塞未来字段。

## 证据（spike C）

- 测试命令：`cd .spikes/gui-subprocess && mkdir -p .tmp .mc && TMPDIR=$PWD/.tmp
  CLANG_MODULE_CACHE_PATH=$PWD/.mc swift test --disable-sandbox --scratch-path .build-spike`
  → **9/9 通过**（1.855 s）：ready 解析与状态迁移、SIGTERM 优雅停止、SIGKILL 升级、
  ready timeout、非零退出、1 MB+1 MB 不丢行不死锁、stop-before-ready、spawn 失败、ready 后
  的 status 行按日志捕获。
- GUI 端到端：SwiftUI app 构建 `BUILD SUCCEEDED`；直接启动 bundle（spike-only
  `--quit-after-ms` 钩子，与 Cmd+Q 走同一条 `NSApplication.terminate` 路径）→ GUI 发 SIGTERM →
  toy 日志写 `received SIGTERM` / `exiting 0 after SIGTERM`，无残留进程。
- 未能在此环境验证：通过 `open` 启动后用 AppleScript 退出（TCC `-10004`，Automation 权限无法
  在本 session 授予）。macOS GUI（推迟）阶段需手点 Cmd+Q 或接 UI 测试。

## 后果

- GUI 只用 `Process` + 两行 JSON 就能起停/监控 server；`ServerControl` 可在 `swift test` 里
  全量覆盖，不需要真实 server 或 GUI。
- `appctl serve` 的 ready 行是 P2 的硬验收项（有测试）。
- 孤儿进程、进程组（encoder 子进程）、sandbox/签名是 macOS GUI（推迟）的开放风险，见下。

## macOS GUI（推迟）开放风险（不在 P1/P2 阻塞）

- GUI 被 SIGKILL 时孤儿 `appctl`：需要 parent-death watchdog（或让 `appctl` 轮询父进程）。
- `appctl` 的 encoder 子进程：停止时可能需要进程组 kill。
- app sandbox / entitlements：GUI 能否 spawn bundle 内 helper、是否需要 `com.apple.security.inherit`，
  到产品化时定 ADR。
- 动态端口（`--port 0`）与真实 `appctl` 的 SIGTERM drain 需要在 P2 与 macOS GUI（推迟）阶段实测。

## 备选与取舍

- **解析人类日志判断 ready**：脆弱、会随文案漂移；拒绝。
- **GUI 内置 server / launchd**：见 ADR-0002 的拒绝理由。
- **用 HTTP `/api/health` 轮询代替 ready 行**：GUI 还得知道端口与认证，且把「进程活着」和
  「服务 ready」混在一起；拒绝（ready 行是进程契约的一部分）。
- **GUI 把 token 放 argv**：`ps` 可见；拒绝（CLI 的 `--token` 仅供人工本地使用）。
