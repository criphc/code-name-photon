---
type: record
owner: docs
updated: 2026-11-05
---

# P0 报告：决策与去风险

- 日期：2026-11-05
- 分支：`migration/p0`（从 `main` 的 stage-1 导入提交切出）
- 结论：**P0 完成，待你审核**；有 1 项环境决策需要你拍板（见 §5）后才能进 P1。
- 审核通过后的动作：`migration/p0` 合回 `main`，开 `migration/p1`，按
  [p1-plan.md](p1-plan.md) 执行。

## 1. 仓库与提交

- **全新历史**：旧仓库 `/Users/criphc/Sites/llm-photon` 保持只读，不再写入；新仓库从 stage-1
  快照开始。
- 已提交：
  - `ca11294` `chore: import stage-1 snapshot from llm-photon`（tag `stage-1-import`）——
    只导入 tracked 文件（3.5 MB），旧布局原样。
  - `fcc3e2f` `chore: stack the new layout on the imported snapshot`——迁移计划移到
    `docs/plans/`，stage-1 调研笔记冻结到 `docs/archive/stage-1/notes/`，`templates/agent.md`
    带过来（P5 用），`.gitignore` 指向新路径。
  - `7abc18c` `docs(decisions): record the P0 architecture decisions`——ADR-0001…0008 + P1 计划。
  - 之后一条：ADR-0009/0010 + 本报告。
- **本地大件已 clone 到新仓库**（gitignored，`cp -c` 不占双份空间）：
  - `fixtures/media/{sources,reference}`（原 `samples/`，1.2 GB）
  - `tools/toGainMapHDR/`（27 MB，外部 MIT clone）
  - `work/m21-final/`（42 MB，parity 的 trial 夹具）
  - `docs/archive/stage-1/delivery/`（7.4 MB，本地归档交付产物）
- `new-structure-description.md` → `docs/plans/new-structure-description.md`；
  `notes/` 已清空并归档。

## 2. 环境

- Xcode 27.2 / Swift 6.4.2 / macOS 27.2 / M1 Max；签名 team `67GJNQAKU5`。
- **iOS 27.2 simulator runtime 已装好**（你启动的下载已完成）：
  `iOS 27.2 (27.2 - 24B8117)`；`simctl` 已能看到 iPhone/iPad 27.2 设备。此项不再阻塞。
- Xcode 27 的工程格式已确认是 JSON `project.xcproj`（不是 pbxproj），见 ADR-0009。

## 3. 迁移前基线（导入快照，未改代码）

| 命令 | 结果 |
|---|---|
| `cd app && make test` | **134 tests, 0 failures**（encoder 存在，无 skip） |
| `cd ipad && make test-macos` | **63 tests, 1 expected skip**（opt-in trial-base parity），0 failures |
| `cd ipad && make parity` | **5 tests, 0 failures, 0 skips**（trial base 含在内） |
| `cd ipad && make build-ios` | `** BUILD SUCCEEDED **` |

这就是 P1 要守住的门禁基线。

## 4. 三个 spike（结论已写入 ADR）

### A. `swift test` 里跑 Metal parity —— PASS（ADR-0008）

- `.spikes/metal-parity/`：MSL 作为 `.copy("Shaders")` package resource，运行时
  `device.makeLibrary(source:)` 编译，GPU dispatch 64×64 夹具，与 CPU 契约比较。
- **3/3 测试通过，无 skip**；最大绝对误差 **7.1525574e-07**（门限 1e-4）；
  夹具覆盖 mask 0 / transition / mask 1 / cap engaged；冷构建 9.81 s，测试 0.29 s。
- 关键事实：`.copy` 保留 `Shaders/` 子目录；`.ml`/`.metal` 不要用（会触发 Metal toolchain）；
  path 依赖 identity 是目录名 `contract`；`--disable-sandbox` 在 DSH 下必需。
- 结论：P3 的 `client` 包用一个 `ClientKit` target + `ShaderResource` loader，parity 进
  `swift test`，app 不再用 `Bundle.main`。

### B. Xcode 27 工程链接本地包 —— PASS（工程格式），DSH 构建方式待决（ADR-0009）

- `.spikes/xcodeproj/`：两个 app（`PhotonClient` iOS、`PhotonServerWrapper` macOS）用
  Xcode 27 JSON 工程，链接本地 `SpikeSupport` 包；app 实际调用包函数。
- 接线只需两段 JSON：
  - 工程根 `"packages": [{ "kind": "local", "name": "...", "path": "../../client" }]`
  - target `"package-product-members": [{ "package": "...", "product-name": "...",
    "build-phase": { "build-phase": "frameworks" } }]`
- Xcode 构建两个 app 均 `BUILD SUCCEEDED`；日志有
  `Explicit dependency on target 'SpikeSupport-product'`；`nm`/`strings` 在
  `*.debug.dylib` 找到包符号。
- **硬要求**：每个 `Package.swift` 必须声明 `platforms:`（否则 Xcode 27.2 静默丢 product，
  构建报 `Missing package product`）。
- 已知限制：agent 的 DSH 沙箱内，含包的工程在 `xcodebuild` 解析阶段就失败
  （`sandbox-exec: sandbox_apply: Operation not permitted`）；不含包的工程正常。**放开外层
  沙箱后同一命令两个 app 都 `BUILD SUCCEEDED`**——这是环境限制，不是工程格式问题。

### C. GUI 监管 `appctl` 子进程 —— PASS（ADR-0010）

- `.spikes/gui-subprocess/`：`ChildProcessSupervisor` + toy `appctl` + Swift Testing + 最小
  SwiftUI app。
- **9/9 测试通过**（1.855 s）：ready 解析与状态迁移、SIGTERM 优雅停止、SIGKILL 升级、
  ready timeout、非零退出、1 MB+1 MB 不死锁、stop-before-ready、spawn 失败、日志捕获。
- GUI app `BUILD SUCCEEDED`；端到端：GUI 退出 → 子进程日志写
  `received SIGTERM` / `exiting 0 after SIGTERM`，无残留。
- 未能验证：`open` 启动后用 AppleScript 退出（TCC `-10004`，本 session 无法授予 Automation
  权限）；退出路径用同一条 `NSApplication.terminate` 路径验证，P4 需手点 Cmd+Q。
- 已定契约：ready 行 `{"schema":0,"event":"ready","port":8787,"pid":123}`（stdout，仅一行；
  stderr 不解析）；token 走 `PHOTON_APPCTL_TOKEN` 环境变量，绝不进 argv；`SIGTERM → 3 s →
  SIGKILL`；app 退出时同步发 SIGTERM 并 `.terminateNow`（`.terminateLater` 会死锁）。

## 5. 已拍板：DSH 里的 app 构建怎么跑

**问题**：`make ios-build` / `make macos-build` 必须是根 Makefile 的入口（R7），但 agent 的
workspace-write 沙箱不允许嵌套 `sandbox-exec`，导致任何链接 SwiftPM 包的 Xcode 工程在
`xcodebuild` 解析阶段失败。普通终端（你的 shell）和 CI 不受影响；放开沙箱后已验证可用。

| 选项 | 含义 | 代价 |
|---|---|---|
| **(a) 放宽 DSH 策略，允许嵌套 sandbox-exec** | `make check` 在 agent 内也能跑，最贴近 R7 | 需要你改 harness 沙箱配置；沙箱边界变宽 |
| **(b) agent 用 Xcode MCP `BuildProject`，Makefile 只在普通终端/CI 跑** | 不改沙箱；agent 内的构建走 MCP | `make check` 在 DSH 内不能完整跑，需在 AGENT.md 写明例外 |
| **(c) app 改为 folder-sync 包源码，不走 SwiftPM product** | xcodebuild 在 DSH 内可跑 | 破坏 R1 的 app→package 边界，package 测试门禁弱化；不推荐 |
| **(d) 每次 build 走一次性 full-access 审批** | 不改策略、不换机制 | 每次 `make` 要批准，不适合自动化 |

**已拍板（2026-11-05，选择 b）**：agent 内 app 构建走 **Xcode MCP `BuildProject`**；根 Makefile
的 `ios-build` / `macos-build` 留给普通终端 / CI。P3/P4 的「绿」= MCP 构建绿 + 普通终端
`make` 构建绿，两者都记录；根 `AGENT.md`（P5）写明「DSH 内不要用 make 的 app 构建目标」这个
环境例外。不采用 (a) 放宽沙箱、(c) folder-sync 包源码、(d) 每次 full-access 审批。
P1/P2 只跑 SwiftPM 测试，不受影响。

## 6. P1 计划（已写好，待批准）

[docs/plans/p1-plan.md](p1-plan.md) 的摘要：

1. `refactor(contract): rename PhotonContract to ContractKit`——目录/target/依赖方/ipad 文件夹
   引用；把 3 个契约测试搬进 `contract/Tests`。
2. `test(contract): add schema-0 golden fixtures`——金样例唯一家（package resource），
   server/client 测试读同一份。
3. `refactor(contract): move HTTP wire types into ContractKit/Wire`——删两端镜像 DTO；
   新增 `IPC/{ReadyEvent,ErrorEvent}`。
4. `docs: point live docs at ContractKit and the single wire home`。

门禁：contract `swift test`、`app make test`、`ipad make test-macos` + `make parity` +
`make build-ios` 全绿；`git grep` 无 `PhotonContract`、无镜像 wire 定义。

## 7. 开放风险 / 记录

- **P4**：Cmd+Q/AppleScript 退出需手点或 UI 测试（TCC）；GUI 被 SIGKILL 时的孤儿 `appctl`
  需要 parent-death watchdog；app sandbox/entitlements 与 helper 打包到产品化时单独定 ADR。
- **P1**：contract/app manifest 的部署目标会随 R12 升到 macOS 27（iOS 工程的 26 留到 P3）；
  从 app 搬走的 3 个测试是移动，不是删除。
- 金样例里的旧绝对路径保留原字节；P5 的 `docs-check` 排除 `Fixtures/`。
- `.spikes/` 是 gitignore 的 throwaway；结论只在 ADR 和本报告里。

## 8. 建议你审核时重点看

1. ADR-0001/0003 的包边界是否就是你要的形状；
2. ADR-0006 的 `PhotonClient` / `PhotonServerWrapper` 命名与 bundle id；
3. ADR-0009 里「Xcode 27 JSON 工程手写/脚本生成」是否接受；
4. ADR-0010 的 ready 行/token 环境变量/退出语义；
5. §5 的构建方式选择；
6. P1 计划的范围（是否只做 contract，不顺手做别的）。
