---
type: record
owner: docs
updated: 2026-11-05
---

# P2 报告：server 拆包 + appctl readiness + 根 Makefile 骨架

- 日期：2026-11-05
- 分支：`migration/p2`（从 `main` 的 P1 合并点切出），tag `p2`
- 对照计划：[p2-plan.md](p2-plan.md)
- 结论：**P2 完成，全部门禁绿**；engine 行为、wire schema 0、8 项交付检查、report 推导、
  `AtomicFile` 全部未改。

## 1. 门禁结果（最终树）

| 门禁 | 结果 |
|---|---|
| `make test` | contract **47 XCTest + 14 Swift Testing**；EngineKit **87**；ServerKit **103**；ServerControl **13**（含参数化 4 组 → 16 cases）；全部 0 failures |
| `make integration` | **2 tests / 0 failures**：真实 `appctl serve` readiness + `/api/health` + SIGTERM（0.14 s）；`appctl deliver` CLI smoke（2.9 s，四件交付 + report PASS） |
| `make parity` | 委托 `ipad/`：**5 tests / 0 failures / 0 skips**（trial base 含在内） |
| `make cli` | 构建 `.build/server/debug/appctl`，`--help` 正常 |
| `make check` | **exit 0**（`test` + `integration` + `parity`） |
| `make ios-build` | 委托 `ipad/`：`BUILD SUCCEEDED` |
| `cd ipad && make test-macos` | **65 tests / 1 expected skip / 0 failures**（回归） |
| `ServerControlTests` 压测 | 13 tests 连跑 30×，0 flakes |

`make test` 用 `--skip IntegrationTests`；`make integration` 单独构建并跑真实子进程，避免
`make test` 依赖 `APPCTL_BIN`。`IntegrationTests` 在 `APPCTL_BIN` 缺失时 **fail 不 skip**。

**稳定性记录（诚实）**：P2 的第一次全量 `make check` 里 EngineKitTests 出现过 **1 次**单条
瞬时失败（grep 截断了 case 名，未捕获）。之后连续 5 次 `--filter EngineKitTests` 和 2 次完整
`make check` 全部绿，未能复现。没有改任何引擎测试逻辑；怀疑是环境瞬时/资源竞争。若 P3 再出现，
优先定位这一条并在 `docs/09` 记录。

## 2. 交付内容

### 2.1 server 包

```
server/
├── Package.swift
├── Sources/
│   ├── EngineKit/            # 原 app/Sources/PhotonCore，行为未改
│   ├── ServerKit/            # 原 app/Sources/PhotonServer
│   ├── ServerControl/        # 新：GUI↔CLI 进程契约
│   ├── appctl/              # 原 photon CLI，readiness/信号/名称
│   └── ServerTestSupport/    # 测试专用假进程/readiness
├── Tests/
│   ├── EngineKitTests/       # 87
│   ├── ServerKitTests/       # 103
│   ├── ServerControlTests/   # 13
│   └── IntegrationTests/     # 2
└── README.md                 # 原 app/README，已更新 layout/命令/readiness
```

- `PhotonCore` → `EngineKit`、`PhotonServer` → `ServerKit`、`photon` → `appctl`；`app/` 删除
  （只剩 gitignored 的旧 build scratch，已清理）。
- `ServerControl` 只依赖 `ContractKit` + Foundation；不 import `ServerKit`/`EngineKit`。
- `ServerTestSupport` 不导出 product，只被测试 target 依赖。

### 2.2 appctl serve（ADR-0010）

- stdout：启动后**恰好一行** `{"schema":0,"event":"ready","port":…,"pid":…}`，用
  `FileHandle.standardOutput` 直接写（无缓冲），之后不再写 stdout。
- stderr：batch/work/listen/token/auth/停止提示；生成的 token 只出现在 stderr。
- token 优先级：`--token` > `PHOTON_APPCTL_TOKEN` > `PHOTON_TOKEN` > 生成。
- 固定端口 1…65535（`--port 0` 按你的决定留给 P4）；ready 的 port 是实际绑定值。
- SIGTERM/SIGINT → `server.stop()` → exit 0；忽略 SIGPIPE。`prep`/`deliver` 的参数与 stdout
  人类输出保持原样。

### 2.3 ServerControl（P4 直接复用）

- `LaunchConfiguration`、`SupervisionPolicy`（可注入 `Sleeper`/`SupervisionClock`）、
  `ChildProcessSupervisor`（`start/stop/requestStop/events/snapshot`）。
- 状态：`idle → starting → ready → running → stopping → stopped | failed`；
  `ExitInfo`（termination reason / requestedStop / escalatedToSIGKILL / ranFor / 字节数）。
- stdout 按 `ContractKit.ProcessEvent` 解码；stderr 永不作为协议；ready timeout、非零退出、
  pre-ready error、SIGTERM→grace→SIGKILL、双管道并发排空、EOF 后定格、1 MiB+1 MiB 不死锁。
- 测试全部用 `ServerTestSupport` 的 fake launcher/sleeper；不依赖真实长进程。

### 2.4 根 Makefile

`test`、`integration`、`cli`、`appctl`、`parity`、`ios-build`、`check`、`clean`；
`macos-build`/`ui-check`/`docs-check`/`fixtures` 按阶段输出明确错误占位。SwiftPM 全部带
`--disable-sandbox`，`TMPDIR`/`CLANG_MODULE_CACHE_PATH` 在 workspace 内；支持
`SCRATCH`/`TMP`/`MC`/`DD_*` 并行覆盖。`parity`/`ios-build` 暂委托 `ipad/`（P3 换）。

### 2.5 文档

`server/README.md`（layout、build/test、appctl readiness、delivery、M2 命令）、根
`AGENT.md`/`README.md`、`docs/01/02/08/09`、`contract/README.md`、`ipad/README.md`、
`docs/decisions/0010`（固定端口）同步。代码注释里的旧 `app/README.md`/`photon` 已清；
`DeliveryReport.Provenance.tool` **保留** `"photon deliver"`（report schema 0 内容，改动属于
独立 schema 决策）。

## 3. 提交与并行拆分

- 提交：
  - `b43d987` `refactor(server): move app/ into the server package skeleton`
  - 之后一条：worker 结果 + Makefile + docs + report
- Wave 0（Lead）：manifest、目录移动、module 改名、占位 target、scaffold 绿。
- Wave 1（4 个并行 worker）：
  - `p2-engine`：EngineKitTests 审计，87/87；仅注释路径修正。
  - `p2-serverkit`：ServerKitTests 审计，103/103；仅 1 处注释。
  - `p2-servercontrol`：ServerControl + ServerTestSupport + 13 tests。
  - `p2-appctl`：readiness/信号/名称 + IntegrationTests（2 tests）。
- Wave 2（Lead）：Makefile、docs、整合、全量门禁、tag/report。
- 所有 worker 写作用域不重叠；未 commit；Lead 统一 review/commit。

## 4. 与计划的差异 / 说明

- 实际 worker 数为 4（与计划一致）；`p2-engine`/`p2-serverkit` 的结果是审计+少量注释，符合
  「搬家不改行为」。
- `make test` 通过 `--skip IntegrationTests` 把真实子进程测试隔离；`make integration` 是唯一
  需要 `APPCTL_BIN`/encoder 的入口。
- `ServerControlTests` 用 Swift Testing；其余迁移来的引擎/服务器测试仍是 XCTest（R12：旧
  XCTest 不强制重写）。
- `appctl deliver` 的人类标题改成 `appctl deliver · …`；report 的 `tool` 值保持
  `"photon deliver"`。
- `ipad/` 只改了注释里的文档指针；其 UI 文案仍写 `photon serve`，P3 退役/重建 iOS 工程时一起
  处理。
- `EngineKit` 的一条 report detail 字符串从 `app/README.md` 改成 `server/README.md`（路径指针，
  不是检查逻辑）。

## 5. 留给后续阶段

- **P3**：`client` 包 + 新 iOS 工程（`PhotonClient` / `com.criphc.Photon.Client`）；MSL 单家；
  `ipad/` 退役；根 `make ios-build` 换新工程；P3 之后 `make parity` 不再委托 `ipad/`。
- **P4**：macOS GUI（`PhotonServerWrapper`）用 `ServerControl` 监管真实 `appctl serve`；
  动态端口 `--port 0` 在 P4 评估；TCC/Cmd+Q、孤儿 watchdog、app sandbox/entitlements 见
  ADR-0010。
- **P5**：workspace、design/、AGENT 拆分、docs-check（旧路径扫描，排除 archive 与
  `contract/Tests/**/Fixtures/`）、根 Makefile 的 app build/docs/ui 目标收口。
- **未做**：Swift 6 language mode（迁移后独立阶段/ADR）、stage-2 队列状态、UI 重做。

## 6. 复现

```bash
make test
make integration
make parity
make cli
make check
make ios-build
cd ipad && make test-macos DD_TESTS=.dd-p2-regression
```
