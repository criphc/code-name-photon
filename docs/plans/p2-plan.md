---
type: record
owner: docs
updated: 2026-11-05
---

# P2 执行计划：server 拆包 + appctl readiness + 根 Makefile 骨架

- 状态：已批准（2026-11-05；用户确认：加 `EngineKitTests`、固定端口、`make check` 只含
  `test` + `integration` + `parity`）
- 上游：[迁移目标结构](00-new-structure-description.md) R1/R3/R5/R7；
  [ADR-0002](../decisions/0002-macos-gui-wraps-appctl.md)、
  [ADR-0003](../decisions/0003-server-internal-layering.md)、
  [ADR-0010](../decisions/0010-appctl-process-contract.md)
- 范围：只搬 `app/` → `server/`、拆分 target、加 `ServerControl` 与 readiness、建根 Makefile
  骨架；**engine 行为、wire schema 0、8 项交付检查、report 推导、`AtomicFile` 全部不变**。

## 1. 目标结构

```
server/
├── Package.swift
├── Sources/
│   ├── EngineKit/            # 原 app/Sources/PhotonCore（渲染/编码/验证/交付）
│   ├── ServerKit/            # 原 app/Sources/PhotonServer（HTTP/wire/队列/serve）
│   ├── ServerControl/        # 新：GUI↔CLI 进程契约（可 headless 测试）
│   ├── appctl/               # 原 app/Sources/photon（薄 CLI，唯一 server 入口）
│   └── ServerTestSupport/    # 只给测试用的假进程/readiness/夹具
├── Tests/
│   ├── EngineKitTests/       # 原 PhotonCoreTests
│   ├── ServerKitTests/       # 原 PhotonServerTests
│   ├── ServerControlTests/   # 新
│   └── IntegrationTests/     # 新：真实 appctl 子进程 + HTTP + CLI smoke
└── README.md                 # 原 app/README.md（交付/report/appctl 启动契约）
```

依赖方向：`ServerKit → EngineKit → ContractKit`；`ServerControl → ContractKit`；
`appctl → ServerKit + EngineKit`；`ServerTestSupport` 只被测试 target 依赖；app 工程不参与 P2。

## 2. 已定决策

1. **`EngineKitTests` 存在**：新结构树的 `Tests/` 列表漏了它；engine 的 87 个测试必须有家，
   本计划显式加入。
2. **固定端口**：`appctl serve --port` 仍要求 1…65535，默认 8787；ready 行里的 `port` 是
   `HTTPServer.port`（实际绑定值）。`--port 0`（OS 分配）留给 P4，不在 P2 暴露。
   ADR-0010 同步改成「P2 固定端口，P4 再评估动态端口」。
3. **P2 的 `make check`** = `test` + `integration` + `parity`；
   `ios-build`/`macos-build`/`docs-check`/`ui-check` 到 P3/P4/P5 才进 `check`。
4. **`appctl serve` stdout 只放协议**：一行 ready JSON（ADR-0010）；人类日志（listen/token/
   batch/work/Ctrl-C 提示）全部改到 stderr。`prep`/`deliver` 的 stdout 人类输出不变。
5. **token 来源**：`--token` > `PHOTON_APPCTL_TOKEN` > `PHOTON_TOKEN` > 自动生成；自动生成的
   token 只打 stderr，stdout 不出现。
6. **`ipad/` 本阶段不动**：根 `make parity` / `ios-build` 暂委托 `ipad/Makefile`，P3 换新工程。

## 3. 文件级动作

### 3.1 搬迁与改名

| 动作 | 路径 |
|---|---|
| 移动 | `app/Sources/PhotonCore` → `server/Sources/EngineKit` |
| 移动 | `app/Sources/PhotonServer` → `server/Sources/ServerKit` |
| 移动 | `app/Sources/photon` → `server/Sources/appctl` |
| 移动 | `app/Tests/PhotonCoreTests` → `server/Tests/EngineKitTests` |
| 移动 | `app/Tests/PhotonServerTests` → `server/Tests/ServerKitTests` |
| 移动 | `app/README.md` → `server/README.md` |
| 改写 | `app/Package.swift` → `server/Package.swift`（target/product 改名） |
| 删除 | `app/Makefile`、`app/.gitignore`、`app/` 空目录 |
| 新增 | `server/Sources/ServerControl/`、`server/Sources/ServerTestSupport/` 及占位文件 |
| 新增 | `server/Tests/ServerControlTests/`、`server/Tests/IntegrationTests/` 及占位文件 |

模块名替换：`PhotonCore` → `EngineKit`，`PhotonServer` → `ServerKit`（import、`@testable
import`、注释、文档）；类型名（`Recipe`/`PhotonError`/`DeliveryPipeline` 等）不变。

### 3.2 server/Package.swift

- package 名 `PhotonServer`，platforms `macOS 27`，Swift 5 language mode，
  `.package(path: "../contract")`。
- products：`EngineKit`、`ServerKit`、`ServerControl`（library）+ `appctl`（executable）。
- targets：
  - `EngineKit` ← ContractKit
  - `ServerKit` ← EngineKit + ContractKit
  - `ServerControl` ← ContractKit
  - `ServerTestSupport` ← ContractKit + ServerControl
  - `appctl` ← EngineKit + ServerKit + ContractKit
  - `EngineKitTests` ← EngineKit + ContractKit
  - `ServerKitTests` ← ServerKit + EngineKit + ContractKit
  - `ServerControlTests` ← ServerControl + ServerTestSupport + ContractKit
  - `IntegrationTests` ← ContractKit
- `ServerTestSupport` 不导出 product。

### 3.3 appctl

- 可执行/目标/文件内名称：`photon` → `appctl`；usage/error 前缀同步。
- `appctl serve`：
  - 启动 `HTTPServer` 后向 stdout 写**一行** `ReadyEvent` JSON（`pid` 用 `getpid()`），
    flush；人类信息写 stderr。
  - SIGTERM/SIGINT：`server.stop()` 后退出 0；不打印任何 stdout 额外内容。
  - `--port` 仍要求 1…65535；ready 用 `server.port`。
  - token 优先级见 §2.5；生成的 token 写 stderr。
- `appctl prep` / `appctl deliver`：参数与行为不变；stdout 人类输出保留。
- 若 `HTTPServer.stop()` 不足以让 `dispatchMain()` 退出，用 `DispatchSourceSignal` + 显式
  `exit(0)`；不引入 launchd/daemon。

### 3.4 ServerControl（新）

- 只依赖 ContractKit/IPC + Foundation；不 import ServerKit/EngineKit。
- 可注入 `ProcessLaunching` / readiness 读取器；状态机
  `idle → starting → ready(ReadyInfo) → running(ReadyInfo) → stopping → stopped(ExitInfo) |
  failed(SupervisorFailure)`。
- `stop()`：SIGTERM → grace → SIGKILL → wait；`requestStop()`；exit code/termination reason；
  stdout/stderr 捕获；ready timeout；不阻塞主线程、不用 `waitUntilExit`、不把超时/退出竞争放进
  TaskGroup（ADR-0010 的 gotcha）。
- 测试覆盖：ready/timeout/非零退出/优雅停止/升级 SIGKILL/stop-before-ready/大输出不死锁。

### 3.5 IntegrationTests

- 通过 `APPCTL_BIN` 环境变量拿 `server/.build-…/debug/appctl`（Makefile 传入）；缺失时 **fail**
  不 skip。
- Case 1：`appctl serve --port <固定测试端口> --batch <tmp> --work <tmp>`，读 stdout 首行并
  `ReadyEvent.isValid`；GET `/api/health`；SIGTERM；断言退出 0、stdout 无额外行。
- Case 2：`appctl deliver --source <tmp P3 TIFF> --out <tmp> --work <tmp>` 的 CLI smoke；
  断言四个文件存在、report `pass == true`。TIFF 在测试运行时用 Core Image 生成（不依赖
  gitignored 素材）。
- 测试使用临时目录；不依赖 `samples/`/`work/`。

### 3.6 根 Makefile 骨架

目标：`test`、`integration`、`parity`、`cli`、`ios-build`、`check`、`clean`；
`macos-build`/`ui-check`/`docs-check` 暂以明确错误占位（P4/P5 补）。

- DSH 沙箱：`--disable-sandbox`、本地 `TMPDIR`/`CLANG_MODULE_CACHE_PATH`、
  `-derivedDataPath`（委托 `ipad` 时）、必要时 `xcrun xctest`。
- 并行覆盖：`SCRATCH`、`TMP`、`MC`、`DD_*`；每个 package 用独立 scratch 子目录。
- `test`：contract + server 的 `swift test`（engine 的 encoder 测试缺失 encoder 必须 fail）。
- `integration`：先 `swift build --product appctl`，再 `APPCTL_BIN=… swift test --filter
  IntegrationTests`（只跑 server 包的 IntegrationTests）。
- `parity` / `ios-build`：`$(MAKE) -C ipad parity|build-ios`（P3 换）。
- `cli`：构建 `appctl` 并跑 `--help`。
- `check`：`test` + `integration` + `parity`。
- `fixtures` 不属于 P2（P5）。

## 4. 并行拆分

Wave 0 由 Lead 串行完成（manifest + 目录移动 + 模块名 + 占位 target + 能 `swift build` 的
scaffold 提交）。之后四个子代理并行：

| 子代理 | 写作用域 | 交付 |
|---|---|---|
| `p2-engine` | `server/Tests/EngineKitTests/` | 测试 import/路径修复；87 个测试全绿；只报告 engine 源码问题，不擅自改行为 |
| `p2-serverkit` | `server/Tests/ServerKitTests/` | HTTP codec/router/store/token 测试搬家；行为不变 |
| `p2-servercontrol` | `server/Sources/ServerControl/`、`server/Sources/ServerTestSupport/`、`server/Tests/ServerControlTests/` | 状态机 + 假进程/readiness + 测试 |
| `p2-appctl` | `server/Sources/appctl/`、`server/Tests/IntegrationTests/` | readiness/stdout 协议/SIGTERM/env token + 集成测试 |

- 每个代理独立 `SCRATCH=.build-<name> TMP=.tmp-<name> MC=.mc-<name>`；只跑目标相关的
  `swift test --filter` / `swift build --product appctl`。
- 代理不得改 `server/Package.swift`、根 `Makefile`、`server/README.md`、根文档；不 commit。
- Lead 负责 manifest、Makefile、README/docs 与最终 review/commit。

Wave 2 由 Lead 串行完成：根 Makefile、`server/README.md`、根 AGENT/README、`docs/08` 的
`app/README` 链接；跑全量门禁；commit、tag `p2`、写 `p2-report.md`。

## 5. 验收

```bash
make test          # contract + server；engine 87、server tests、encoder 缺失 fail
make integration   # appctl serve readiness + health + SIGTERM + deliver smoke
make parity        # 委托 ipad：5 tests / 0 skips
make cli           # appctl --help
make check         # test + integration + parity
cd ipad && make test-macos && make build-ios   # 回归；本阶段不动 ipad
```

- `git grep -n "PhotonCore\|PhotonServer" -- server app` 0 条（历史 docs 除外）。
- `git grep -n "app/" -- server` 只允许历史注释，P5 docs-check 再清。
- 交付 report 的 8 项检查仍全 PASS；`appctl deliver` 仍原子安装四个文件。

## 6. 不在 P2

- 不建 `apps/*`、不换 iOS 工程、不做 macOS GUI（P3/P4）。
- 不做 workspace/design/AGENT 拆分/docs 重组（P5）。
- 不做 Swift 6 language mode、不改 wire schema、不加队列状态。
- 不实现动态端口 `--port 0`（P4）。
