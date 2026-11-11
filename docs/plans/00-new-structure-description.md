---
type: record
owner: docs
updated: 2026-11-05
---

# 00 — 新结构说明（目标架构与要求）

*2026-11-05 · 迁移后仓库的目标结构与硬性要求。*

本文件只定「必须成立的东西」。文件级迁移清单、提交顺序、脚本、Xcode 工程创建方式、ADR 正文、UI 规格，由执行迁移的新 session 展开。

**迁移源**：`/Users/criphc/Sites/llm-photon`（stage 1 关闭状态）。执行前先读该仓库的 `agent.md` `readme.md`  `docs/01`、`docs/02`、`docs/08`、`docs/09`、`app/README.md`、`ipad/README.md`、`contract/README.md`。**新家**：本目录。

## 0. 背景

原型已完成：Mac 端负责色彩管理渲染、编码、8 项验证与原子交付；iPad 端负责 EDR 判图与回传 recipe。现在要同时做三件事，全部落在 app 层：

1. **重做 iPad UI**——现有 UI 没有设计前提（工程是 iPad-only、iOS 26 部署目标），必须按新规格重做；
2. **新增 macOS GUI**——`appctl`（CLI 套件）的套壳：不碰命令行就能起 server，并监控它的运行状态与日志；不内置 engine；
3. **朝可分享的产品演进**——配对、分发、签名是后续阶段，但结构不能挡路。

判图能力按**显示器**定义，不按平台：iPad XDR 是主验收面；Mac 接了外接 HDR 显示器同样可以判图（内置 Studio Display 是 SDR，不行）。

所以仓库重组为「4 个 SwiftPM package（contract/server/client/design）+ 2 个 app 工程 + 1 个 workspace + 根 Makefile」。**engine（渲染/编码/验证/交付）行为不变**；迁移只做搬家、改名、拆包。

迁移原则：

- 结构先动、UI 后动；
- engine 行为零变化（wire 形状、8 项交付检查、report 推导、`AtomicFile`、shader parity 全部不变）；
- 每阶段独立可回滚，验证门禁保持绿；
- 迁移期间冻结 stage-2 功能。

## 1. 已定决策

用户设想的新架构（原话）：

1. macOS app：cli系列工具及其GUI wrapper。服务端。
2. iOS app：判图客户端，iPad优先，同时兼容iPhone和Mac。


| 决策 | 结论 |
|---|---|
| macOS GUI 与 server | GUI 是 `appctl` 的套壳：启动/停止/重启/监控 CLI 子进程（端口、token、日志、退出码）；**不内置 `ServerKit`、不走 loopback、不做判图 UI** |
| server 包内分层 | `EngineKit` + `ServerKit` 两个主体 target，外加小的 `ServerControl`（GUI↔CLI 进程契约）与薄 `appctl`/`ServerTestSupport` |
| 判图面 | 按显示器能力：iPad XDR 为主；外接 HDR 显示器的 Mac 也可判图；内置 Studio Display SDR 不行 |
| iOS 的 Mac 支持 | Mac (Designed for iPad) |
| iOS 的 iPhone 支持 | 支持（device family 1,2），但「能跑」即可，不是第一等设计对象 |
| 命名 | 模块/包名按新结构；产品名与 bundle id 之后再决定，迁移期保持 `com.criphc.Photon` |
| 文档旧路径 | 不留 redirect stub，接受 `docs/archive/` 断链；归档冻结不改 |

## 2. 目标目录

```text
.
├── AGENT.md                          # agent 唯一入口：命令表 + 全局红线 + 文档归属 + 子 AGENT 链接
├── README.md                         # 人读的项目入口
├── Makefile                          # 唯一命令入口
├── workspace.xcworkspace             # 两个 app 工程 + 四个 package 的导航
├── Configs/
│   └── Shared.xcconfig               # team / 版本 / bundle id 占位（产品名确定后统一改）
├── contract/                         # 【SwiftPM】零依赖 leaf
│   ├── Package.swift
│   ├── Sources/ContractKit/{Wire,IPC}/   # Wire：HTTP JSON；IPC：GUI↔CLI 的 ready/status 事件
│   ├── Tests/ContractKitTests/
│   │   └── Fixtures/schema-0/        # 金样例唯一家（package resource）
│   └── README.md                     # wire + recipe + IPC 事件契约
├── server/                           # 【SwiftPM】原 app/
│   ├── Package.swift
│   ├── Sources/{EngineKit,ServerKit,ServerControl,appctl,ServerTestSupport}/
│   ├── Tests/{ServerKitTests,ServerControlTests,IntegrationTests}/
│   └── README.md                     # 交付 / report / appctl 启动契约
├── client/                           # 【SwiftPM】原 ipad/ 的逻辑
│   ├── Package.swift
│   ├── Sources/{ClientKit,ClientModel}/
│   └── Tests/                        # 原 PhotonTests 的逻辑 + parity
├── apps/
│   ├── ios/                          # iOS.xcodeproj
│   │   ├── Sources/{App,Features}/
│   │   ├── Resources/
│   │   └── Tests/
│   └── macos/                        # macOS.xcodeproj
│       ├── Sources/{App,Features}/
│       └── Tests/
├── design/                           # 【SwiftPM】薄
│   ├── Package.swift
│   └── Sources/{DesignTokens,DesignComponents}/
├── docs/
│   ├── README.md                     # 按任务导航的索引
│   ├── concept/                      # 原 01、02
│   ├── reference/                    # 原 08
│   ├── plans/                        # 阶段交接（09）与本文件
│   ├── decisions/                    # ADR，一条一个文件
│   ├── ui/
│   │   ├── inventory.md              # 屏幕/状态清单 + 进度 = agent 任务队列
│   │   ├── model-surface.md          # UI 只允许用的 model API
│   │   ├── tokens.md                 # token 的用法/命名/语义（不复制数值）
│   │   └── screens/
│   └── archive/                      # stage-1，冻结
├── fixtures/media/                   # 大件真实素材（gitignored；原 samples/）
└── tools/
    ├── toGainMapHDR/                 # MIT 外部 clone（gitignored）
    ├── verify-heic/
    ├── visual-check/
    └── make-fixtures/                # 原 m0-fixtures 的生成器
```

运行期目录 `inbox/`、`work/`、`out/`、`cache/` 留在根并 gitignored。旧仓库的 `templates/AGENT.md`（未跟踪）带过来，用于写根/子 `AGENT.md`，用完后删除或归档。

## 3. 硬性要求

### R1 模块边界

- `contract` 是零依赖 leaf：只有 Codable/纯数学，无 I/O。`EngineKit`、`ClientKit`、`ServerControl` 都依赖它。
- `server`：`EngineKit` = 渲染/编码/验证/交付（原 `PhotonCore`）；`ServerKit` = HTTP/wire/队列服务（原 `PhotonServer`）；`ServerControl` = GUI↔CLI 的进程契约（启动配置、readiness、日志、退出/终止状态机）；`appctl` = 薄 CLI，唯一 server 入口；`ServerTestSupport` 只给测试用。**三条边界不合并。**
- `client`：`ClientKit` = 传输/解码/recipe 草稿（无 UI，Foundation/ImageIO/CryptoKit 级）；`ClientModel` = 状态机。
- app 依赖 package；package 永不依赖 app。iOS app 不链接 `server` 包。macOS app 只依赖 `server` 的 `ServerControl`（不链接 `EngineKit`/`ServerKit`），通过子进程运行 `appctl`；需要读取服务数据时再引入 `ClientKit`（本阶段不需要）。
- `ServerControl` 的进程状态机必须可 headless 测试（注入假进程/假 readiness）。

### R2 一份 wire 契约 + 金样例

- HTTP JSON 的 Codable 定义只存在于 `ContractKit/Wire`；server 与 client 都 import，**禁止镜像文件**。
- `contract/Tests/ContractKitTests/Fixtures/schema-0/` 是唯一金样例家，作为 package resource；server 与 client 的测试从 `Bundle.module` 或相对路径读同一份，跑「新 server 读旧 client 字节 / 新 client 读旧 server 字节」。
- 迁移期间 JSON 形状保持 schema 0 不变；队列新状态（rendered/encoded/verified 等）属于 stage 2，届时定 schema 版本与兼容策略。
- `ContractKit/IPC` 只放 GUI↔CLI 的可序列化事件（ready/status），不放 HTTP 类型；进程的 argv/env 契约由 `ServerControl` 定义。

### R3 GUI = `appctl` 套壳（子进程）

- macOS GUI 的唯一职责：不碰命令行地启动/停止/重启 `appctl serve`，监控状态（starting/ready/running/failed/stopped、退出码）、捕获 stdout/stderr 日志、展示配对信息（host/port/token）。
- GUI↔CLI 契约 = 进程契约：argv/env（port、token、inbox、out）、机器可读的 readiness（`appctl serve` 在 stdout 打一行 ready 事件，含 port/pid；token 若由 GUI 生成则不必回显）、日志流、退出码、SIGTERM 优雅停止（超时后强制终止）。
- 不做：进程内 `ServerKit`、loopback `ClientModel`、独立常驻 daemon/launchd。`appctl` 仍是唯一 server 入口，GUI 不复制 server 逻辑。
- 打包：GUI 默认用 app bundle 内的 helper `appctl`（`make macos-build` 先构建再拷贝/签名）；开发期可指向仓库构建产物。沙盒/签名的细节到产品化时定 ADR。

### R4 三份契约

1. **server↔client**：`ContractKit/Wire` + `contract/README.md`。
2. **GUI↔CLI**：进程契约（`ServerControl` + `ContractKit/IPC` 的 ready/status 事件），文档就近放 `apps/macos/AGENT.md`。
3. **UI↔model**：`docs/ui/model-surface.md`。冻结后才允许双端 UI 并行；UI 只能通过 model 面（`@Observable` 只读状态 + 命令）。iOS 判图 UI 用 `SessionModel`/`JudgeModel`；macOS 套壳只暴露进程状态与命令，面很小。

### R5 模型拆分

- `SessionModel`：连接、items、服务端派生状态（双端共享）。
- `JudgeModel`：prepare→download→draft→post（仅 iOS 判图）。
- `ServerControl` 内的进程状态机：启动/就绪/失败/退出/终止（macOS 套壳用；可 headless 测试）。
- `Features/<Feature>/Model.swift` 只放 view-local state；**可测状态机必须进 package**。
- 将来若 macOS 要展示队列/items，再按 wire 读接口加模型，不在本阶段承诺。

### R6 两个 app

- **iOS**：一个 target，iPhone + iPad（`TARGETED_DEVICE_FAMILY = 1,2`），iOS 27；iPad 优先，iPhone 和 Mac（Designed for iPad）「能跑就行」。判图验收：iPad XDR 为主；Mac 接了外接 HDR 显示器时也可判图（Designed for iPad 运行），内置 Studio Display SDR 不行。
- **macOS**：原生 SwiftUI，`MenuBarExtra` + 主窗口；职责 = `appctl` 套壳（启动/停止/监控/日志/配对信息）；不内置 server、不提供判图 UI。判图若要上 Mac，走 iOS app（Designed for iPad）+ HDR 显示器，后续单独设计，不在本轮。
- 两个 app 各自 `.xcodeproj`（folder-synced），共享 `Configs/Shared.xcconfig`（team/版本）；`workspace.xcworkspace` 统一导航。
- 产品名/bundle id 延后：迁移期保持 `com.criphc.Photon`，命名确定后再统一改。

### R7 根 Makefile 唯一入口

- 目标：`test`、`integration`、`parity`、`ios-build`、`macos-build`、`ui-check`、`docs-check`、`check`、`cli`、`fixtures`。
- `macos-build` 先构建 `appctl` 再作为 helper 打包进 app bundle；`make cli` 构建独立 CLI。
- 必须继承现有两个 Makefile 里的 DSH 沙箱处理（`--disable-sandbox`、本地 `TMPDIR`/`CLANG_MODULE_CACHE_PATH`、xcodebuild 的 `-disable-sandbox`、`-derivedDataPath`、必要时 `xcrun xctest`）。
- 给并行 agent 的覆盖变量（`SCRATCH`、`TMP`、`MC`、`DD_*`）。
- `make check` 是合并门：`test` + `integration` + `parity` + 两个 build + `docs-check`（`ui-check` 可用后加入）。
- 测试数不是指标；encoder 缺失必须 fail，不能 skip；交付/report gate 不变。

### R8 design/ 薄

- 只有 tokens（间距、圆角、动效曲线、语义色）和 3–5 个真正同构的控件；**不共享布局**。
- token 值以 `design/` 代码为唯一源；`docs/ui/tokens.md` 只写用法、命名、语义，不复制数值。

### R9 按 feature 切

- `apps/*/Sources/App/` 只放 `@main`、Scene/WindowGroup/MenuBarExtra 装配、菜单。
- `apps/*/Sources/Features/<Feature>/{View,Model,Preview}.swift`；一个 feature 一个目录 = agent 的生成/编辑/删除/评审单元。
- 每个有状态的 feature 至少一个 state 的 `#Preview`；交互元素带 `accessibilityIdentifier`。

### R10 文档与 AGENT

- `docs/README.md` 按任务导航；`concept/`、`reference/`、`plans/`、`decisions/`、`ui/`、`archive/`。
- 组件契约就近：`server/README.md`（交付/report/CLI 启动）、`client/README.md`（客户端架构）、`contract/README.md`（wire/recipe/IPC 事件）。
- `AGENT.md` 拆分：根 = 入口/命令/红线/文档归属；子 = 各目录的构建与环境事实。用旧仓库的 `templates/AGENT.md` 模板。
- 旧文档路径不留 redirect stub，接受 archive 断链；迁移时更新代码注释与活文档里的旧路径（`docs-check` 扫旧路径）。
- 新决策进 `docs/decisions/`；归档不改。

### R11 验收不变

- 迁移不改变 engine 行为：8 项交付检查、report 推导、`AtomicFile`、shader parity ≤1e-4、设备验收梯子（iPad 安装/判图/回传/交付/Photos+Safari）保持。
- iPad XDR 是主验收面；接了外接 HDR 显示器的 Mac 可作为补充判图面，但不替代它。
- stage-2 功能（EXIF rewrap、verify 耗时、队列状态、UI 重做）在迁移完成后再做；迁移期间冻结功能改动。

### R12 平台与工程实践

- 部署目标 iOS 27 / macOS 27，Swift 6 工具链；尽量采用新 API。
- Liquid Glass 只用于管理 chrome，**不进判图区**（判图区保持中性暗色）。
- 新测试优先 Swift Testing；旧 XCTest 不强制重写。
- 外部依赖保持很少；新增依赖需 ADR。
- 迁移期间保持现有 Swift 5 language mode，避免并发改造混进搬家；Swift 6 模式作为迁移后的独立步骤/ADR。

## 4. 迁移阶段（只列阶段；细节由新 session 展开）

| 阶段 | 目标 | 绿的定义 |
|---|---|---|
| P0 决策与去风险 | ADR、三个 spike（`swift test` 跑 Metal parity；两个空 xcodeproj 链接本地包；GUI 用子进程起 `appctl`、读到 readiness、优雅停止）、装 iOS 27.2 runtime、tag + 分支 | spike 结论写入 ADR；分支可回滚 |
| P1 contract | ContractKit + Wire + 金样例 schema-0 | contract 与两端现有测试全绿 |
| P2 server | EngineKit/ServerKit/ServerControl/appctl + `appctl serve` readiness 输出 + 测试拆分 + 根 Makefile 骨架 | `make test` + `make integration` + 交付 gate 不变；readiness 有测试 |
| P3 client + iOS | 抽 ClientKit/ClientModel、MSL 单家、新 iOS 工程、`ipad/` 退役 | `make test` + parity 0 skip + iOS build + 设备验收 |
| P4 macOS 壳 | 新 macOS 工程、MenuBarExtra + 主窗口、用 `ServerControl` 启动/停止/监控 `appctl`（状态/日志/配对信息） | `make test` + macOS build + 手点 smoke（从 GUI 起 server，iPad 能连） |
| P5 基础设施 + 文档 | workspace、design/、AGENT 拆分、docs 重组、根 Makefile 完成 | `make check` + docs-check 0 旧路径 |
| P6 design + UI 规格 | tokens、model-surface 冻结、inventory/screens | 文档冻结，UI 可并行 |

P0–P6 完成 = 结构迁移完成；随后才是 UI 重做、stage-2 引擎工作；Mac 上的判图形态视阶段 3 再定。

## 5. 红线

- 不重写 engine / wire 行为；不动 `tools/toGainMapHDR/`。
- 不在迁移里做 UI 设计或 stage-2 功能；不把「搬家」和「改行为」放进同一个 diff。
- 不把 engine/CLI 搬进 Xcode project（保持 SwiftPM + headless 测试回路）。
- macOS app 不内嵌 server、不做 loopback 客户端、不做常驻 daemon/launchd；只套壳 `appctl`。
- 不共享跨端布局；不先定产品名；不在 app 的 feature 里放可测状态机；不镜像 wire 类型。
- 归档不改；旧文档路径不留 stub。

## 6. 本文不覆盖

文件级迁移清单与提交顺序、sed/脚本、Xcode 工程创建方式、每个 ADR 正文、`model-surface.md` 的具体 API、`screens/`/`inventory.md` 清单、`make` 目标的具体命令。这些属于执行 session 的产出。
