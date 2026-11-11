---
type: record
owner: docs
updated: 2026-11-05
---

# P3 执行计划：client 包 + 新 iOS 工程 + `ipad/` 退役

- 状态：已批准（2026-11-05；用户决定：现在拆 Session/Judge；产品 UI 只留 placeholder；
  旧原型 UI 仅作为 debug-only 验收入口，P3 结束删除；iPad UDID `00008112-001E055E3EF0C01E`）
- 上游：[迁移目标结构](00-new-structure-description.md) R1/R5/R6/R9/R11；
  [ADR-0005](../decisions/0005-judging-surface-by-display.md)、
  [ADR-0006](../decisions/0006-migration-naming.md)、
  [ADR-0008](../decisions/0008-metal-parity-in-swiftpm-tests.md)、
  [ADR-0009](../decisions/0009-xcode27-project-format.md)
- 范围：抽 `ClientKit`/`ClientModel`、MSL 单家、新 `apps/ios` 工程、`ipad/` 退役；engine 与
  server 不动；**不做 UI 设计**（P6）、不引入 `design/`（P5）。

## 1. 目标结构

```
client/
├── Package.swift
├── Sources/
│   ├── ClientKit/          # 传输/解码/recipe 草稿/render contract/唯一 MSL
│   │   ├── Transport/      PhotonClient + ClientError
│   │   ├── Base/           BasePNG
│   │   ├── Judging/        RecipeDraft
│   │   ├── RenderContract/ HighlightUniforms + BaseIdentity/BaseUploadGate
│   │   ├── Shaders/        HighlightShape.msl（package resource）
│   │   └── ShaderResource.swift
│   └── ClientModel/        # SessionModel + JudgeModel（@Observable，无 UI）
├── Tests/
│   ├── ClientKitTests/     # transport/decode/draft/render contract/parity
│   └── ClientModelTests/   # 状态机
└── README.md               # 客户端架构（原 ipad/README 的活内容）

apps/ios/
├── iOS.xcodeproj/          # Xcode 27 JSON；target PhotonClient
├── Sources/
│   ├── App/                # @main、Scene、装配、产品 placeholder 根
│   ├── Features/           # Connection/Library/Judge 的 placeholder
│   └── Prototype/          # DEBUG-only：旧视图 + EDRCanvas/MetalRenderer + adapter
├── Resources/              # Info.plist、Assets
└── (Tests 暂不建)
```

依赖方向：`ClientModel → ClientKit → ContractKit`；app → client 包 + `ContractKit`；**app 不链接
server**。`ClientKit` 不 import UI/SwiftUI，`ClientModel` 不 import UIKit/SwiftUI。

## 2. 已定决策

1. **SessionModel / JudgeModel 现在就拆**：
   - `SessionModel`：设置（host/port/token，可注入持久化）、`PhotonClient`/health/items、连接与
     列表刷新、连接/列表错误与重试。
   - `JudgeModel`：选中 item、prepare→download→decode、review 缓存、RecipeDraft、滑块、
     compare/overlay/headroom、post/receipt/dirty、409 重判与判图错误/重试。
   - 两者都 `@MainActor @Observable`；`JudgeModel` 依赖 `SessionModel` 的 client/items 与
     `refreshItems()`。测试用 `PhotonClientProtocol` 假实现 + 内存设置；不依赖网络/GPU。
2. **产品 UI = placeholder**：`apps/ios` 的产品路径只有 Connection/Library/Judge 的空白
   placeholder（说明 UI 在 P6）；不迁移旧视图作为产品界面。
3. **debug-only 原型 UI**：旧 `ConnectionView`/`LibraryView`/`JudgeView`/`RootView`/
   `EDRCanvas`/`MetalRenderer` 复制到 `apps/ios/Sources/Prototype/`，`#if DEBUG`；Debug app 的
   placeholder 页提供一个 “Open prototype (debug)” 入口，用于 P3 设备验收。**验收通过后删除
   整个 Prototype 目录和入口**，final P3 树只有 placeholder。
4. **iPad 验收**：UDID `00008112-001E055E3EF0C01E`；用 Debug + prototype 完成
   install/launch/连接/判图/回传/Photos+Safari；然后删除 prototype、重建 placeholder 并做
   install/launch smoke。Mac 外接 HDR 显示器是补充面。
5. **MSL 单家**：`HighlightShape.msl` 只存在于 `ClientKit/Shaders`；app 与 parity 测试都通过
   `ShaderResource` 使用它；不再用 `Bundle.main`；`.copy("Shaders")` + 运行时编译。
6. **新工程**：Xcode 27 JSON，`PhotonClient` / `com.criphc.Photon.Client`，iOS 27，
   `TARGETED_DEVICE_FAMILY=1,2`，team `67GJNQAKU5`；链接 `ClientKit`/`ClientModel`/`ContractKit`
   产品；不链接 server。agent 内用 Xcode MCP 构建；`make ios-build` 供普通终端/CI。

## 3. 文件级动作

### 3.1 client 包

| 动作 | 路径 |
|---|---|
| 新建 | `client/Package.swift`（package `PhotonClient`；targets `ClientKit`/`ClientModel`；tests；resources） |
| 移动 | `ipad/ClientKit/Transport/*` → `client/Sources/ClientKit/Transport/` |
| 移动 | `ipad/ClientKit/Base/BasePNG.swift` → `client/Sources/ClientKit/Base/` |
| 移动 | `ipad/ClientKit/Judging/RecipeDraft.swift` → `client/Sources/ClientKit/Judging/` |
| 移动 | `ipad/ClientKit/RenderContract/*` → `client/Sources/ClientKit/RenderContract/` |
| 移动 | `ipad/Photon/Shaders/HighlightShape.msl` → `client/Sources/ClientKit/Shaders/` |
| 新增 | `client/Sources/ClientKit/ShaderResource.swift`（`Bundle.module` 单一 loader） |
| 新增 | `client/Sources/ClientKit/PhotonClientProtocol.swift`（测试注入面；`PhotonClient` 遵守） |
| 移动/拆分 | `ipad/Photon/UI/AppModel.swift` → `client/Sources/ClientModel/{SessionModel,JudgeModel}.swift` |
| 新增 | `client/Sources/ClientModel/{Notice,PhotonConnectionSettings}.swift`（如拆分需要） |
| 移动 | `ipad/PhotonTests/*` → `client/Tests/ClientKitTests/`（按主题；ShaderParity 也在此） |
| 新增 | `client/Tests/ClientModelTests/`（状态机测试） |
| 新增 | `client/README.md`（客户端架构/控件语义/错误/parity/设备事实；替代 `ipad/README.md`） |

- `ClientKit` 的资源：`resources: [.copy("Shaders")]`；测试与 app 共用 `ShaderResource`。
- `ClientModel` 不依赖 `ClientKit` 的 UI；只依赖 `ClientKit` + `ContractKit` + Foundation/Observation。
- 测试路径：`client/Tests/ClientKitTests/TestSupport.swift` 的 `repositoryRoot` 从
  `#filePath` 上溯三层；trial base 仍在 `work/m21-final/`，`PHOTON_TRIAL_BASE_PARITY=1` opt-in。
- `ipad/PhotonTests/WireModelTests` 如只覆盖 ContractKit 类型，可留在 client 测试中作为
  客户端解码回归；不重复 contract 包已有断言。

### 3.2 apps/ios 工程

| 动作 | 路径 |
|---|---|
| 新建 | `apps/ios/iOS.xcodeproj/project.xcproj`（JSON；`PhotonClient` app target + shared scheme） |
| 新建 | `apps/ios/Sources/App/PhotonClientApp.swift`（`@main`，产品 placeholder 根 + DEBUG 入口） |
| 新建 | `apps/ios/Sources/Features/{Connection,Library,Judge}/PlaceholderView.swift` |
| 复制 | `apps/ios/Resources/{Info.plist,Assets.xcassets}`（从 `ipad/Photon`） |
| 复制 | 旧 `ipad/Photon/UI/*` → `apps/ios/Sources/Prototype/UI/`（仅 DEBUG） |
| 复制 | `ipad/Photon/Render/*` → `apps/ios/Sources/Prototype/Render/`（仅 DEBUG） |
| 新增 | `apps/ios/Sources/Prototype/DebugPrototype.swift`（compose Session/Judge 的旧 UI adapter + 入口） |
| 删除 | `ipad/`（新 app 构建/验收通过后，同一次收口） |

- 产品 placeholder 不做网络/判图；`Info.plist` 保留本地网络用途说明与 ATS（prototype 需要）。
- Prototype 视图只在 `#if DEBUG` 编译；产品 Release/Debug 默认都进 placeholder。
- `Makefile` 的 `ios-build` 指向新工程；agent 用 Xcode MCP（`XcodeOpenWorkspace` +
  `XcodeSwitchRunDestination` + `BuildProject`），普通终端/CI 用 xcodebuild。
- 设备：`DEVICE_UDID ?= 00008112-001E055E3EF0C01E`；install/launch 用 `xcrun devicectl`。

### 3.3 根 Makefile

- `test: contract-test server-test client-test`（server-test 继续 `--skip IntegrationTests`）。
- `client-test`：`cd client && swift test --disable-sandbox --scratch-path $(SCRATCH)/client`。
- `parity`：`cd client && PHOTON_TRIAL_BASE_PARITY=1 swift test --filter ShaderParity`，0 skips。
- `ios-build`：`xcodebuild -project apps/ios/iOS.xcodeproj -scheme PhotonClient -destination
  'generic/platform=iOS' -derivedDataPath $(DD_IOS) CODE_SIGNING_ALLOWED=NO ...`（agent 用 MCP；
  普通终端/CI 用 make）。
- 设备目标（如需要）：`ios-build-device`/`ios-install`/`ios-launch`，`DEVICE_UDID` 可覆盖；
  `ios-build` 仍是不签名的编译验证。
- 删除 `parity`/`ios-build` 对 `ipad/` 的委托；`check` 仍为 `test + integration + parity`。

### 3.4 文档

- `client/README.md`：客户端架构、控件语义、状态/错误、parity、设备事实（归并 `ipad/README`
  的活内容；删除 `ipad/README.md`）。
- 根 `AGENT.md`/`README.md`、`docs/01/02/08/09` 的 `ipad/`、`app/`、`photon` 引用改到
  `client/`/`apps/ios`/`appctl`。
- `docs/plans/p3-plan.md` 与 `p3-report.md`；P5 才做 docs 重组与 AGENT 拆分。
- 依 `AGENTS.md`：一件事只写一次；新增文档内容必须删掉被取代的旧段落；测试若重叠同提交删。

## 4. 并行拆分

Wave 0（Lead）：
- 建 `client/Package.swift` 骨架、目录移动、MSL/ShaderResource、AppModel 临时落点；
- 建 `apps/ios` 工程骨架（JSON/package refs/scheme/placeholder/Resources）与原型视图复制；
- 根 Makefile 骨架；`swift build`/`swift test` 能编译；提交 scaffold。

Wave 1（3 个并行 worker）：
| 子代理 | 写作用域 | 交付 |
|---|---|---|
| `p3-clientkit` | `client/Sources/ClientKit`（非 Shaders/ShaderResource）、`client/Tests/ClientKitTests`（非 parity） | 搬 Transport/BasePNG/RecipeDraft/RenderContract + 测试；行为不变 |
| `p3-model` | `client/Sources/ClientModel`、`client/Tests/ClientModelTests` | SessionModel/JudgeModel 拆分 + 可注入设置/client + 测试（连接、缓存、409、post/dirty、错误/重试） |
| `p3-shader` | `client/Sources/ClientKit/Shaders`、`ShaderResource.swift`、`ClientKitTests/ShaderParity*` | MSL 单家 + loader + `swift test` parity；trial opt-in |

Wave 2（blocked_by Wave 1）：
| `p3-app` | `apps/ios` | 产品 placeholder + DEBUG 原型视图接新模型 + 工程构建（Xcode MCP）；`appctl serve` 文案；无产品 UI 迁移 |

Wave 3（Lead）：整合、Makefile/docs、Xcode MCP 构建、iPad 设备验收（prototype）、删除
Prototype 与 `ipad/`、placeholder 重建/安装/launch smoke、全量门禁、tag `p3`/报告/merge。

## 5. 门禁

```bash
cd client && swift test                       # ClientKit + ClientModel
make test                                     # contract + server + client
make integration                              # 不变
make parity                                   # client parity, 0 skips（trial 含在内）
make check                                    # test + integration + parity
make ios-build                                # 新 apps/ios 工程（agent 用 Xcode MCP）
# 设备（prototype 验收后删除 prototype）：
# xcodebuild/MCP Debug -> devicectl install/launch -> appctl serve -> 判图/post ->
# appctl deliver -> Photos + Safari
```

- client 包测试必须 0 skip（trial 由 `make parity` 打开）。
- app 构建：MCP `BuildProject` 成功 + 普通终端/CI 的 `make ios-build` 成功；两边都记录。
- 设备验收：iPad XDR 上的完整判图/回传/交付/Photos+Safari；Mac 外接 HDR 为补充。
- `ipad/` 删除后仓库无 `PhotonContract`/旧 source-folder 编译；`client` 是唯一客户端包。

## 6. 风险 / 注意

- **Session/Judge 拆分**是最容易改变行为的地方：用现有 `AppModel` 的公开语义做对照，新增
  状态机测试；原型 UI 只作为验收探针，不作为产品 API。
- **debug prototype 生命周期**：验收后必须删除；final P3 树不能有旧视图/EDRCanvas。
- **产品 placeholder**：P3 不做连接/判图 UI；完整视觉验收在 P6。P3 的 iPad 验收用 prototype，
  记录在 `p3-report.md`。
- **Xcode 27 包依赖**：Xcode MCP 构建；`make ios-build` 在 DSH 内会因嵌套 sandbox 失败
  （ADR-0009 已记录），普通终端/CI 可用。
- **设备签名**：team `67GJNQAKU5`；UDID 已给；如账户/描述文件变化先问用户。
- **iPhone/Mac（Designed for iPad）**：family 1,2；P3 只要求能构建/启动，不是第一等设计对象。
- **UI 文案**：prototype 里的 `photon serve` 改 `appctl serve`；产品 placeholder 不涉及。
- **AGENTS.md 工作树改动**：不会被 P3 提交；提交时按路径暂存，避免 `git add -A`。
