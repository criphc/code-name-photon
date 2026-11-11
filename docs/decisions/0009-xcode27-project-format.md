---
type: decision
owner: docs
updated: 2026-11-06
---

# ADR-0009：Xcode 27 的 JSON 工程格式与本地 SwiftPM 包接线

- 状态：已接受（工程格式；DSH 构建方式已选 **(b) MCP builds**，2026-11-05 用户拍板）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) R1、R6、R7、R12；
  [ADR-0001](0001-repository-package-split.md)、[ADR-0006](0006-migration-naming.md)
- 影响阶段：P3（iOS）、P4（macOS，推迟）、P5（workspace 与共享 xcconfig）

## 背景

Xcode 27 的工程不再是 `project.pbxproj`，而是 JSON：`<Name>.xcodeproj/project.xcproj`。
迁移要新建两个 app 工程（`apps/ios/iOS.xcodeproj` 的 `PhotonClient`、
`apps/macos/macOS.xcodeproj` 的 `PhotonServerWrapper`），且 app 必须链接 repo 根部的本地
SwiftPM 包（`client` / `design` / `server` 的 `ServerControl`）。工程创建方式与包接线方式
必须可脚本化、可提交、可 headless 复现。

## 决策

### 1. 工程用 JSON 手写/脚本生成，以 spike B 的工程为模板

- `project.xcproj` 是 JSON（允许尾逗号）；没有 `project.pbxproj`。
- 源文件用 **folder-synced** `{ "kind": "folder", "path": "Sources" , "target-membership": [...] }`；
  `path` 相对 `.xcodeproj` 所在目录。
- 每个工程带 `project.xcworkspace/contents.xcworkspacedata`（空即可）与
  `xcshareddata/xcschemes/<Target>.xcscheme`；`BlueprintIdentifier` 必须等于 target 的 `id`。
- Info.plist 用 `GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_KEY_*`；真实工程保留
  `DEVELOPMENT_TEAM = 289223FXNS`（Personal Team）+ 自动签名，headless 编译验证时传
  `CODE_SIGNING_ALLOWED=NO`。team / 版本 / bundle id 的实际值在 `Configs/Shared.xcconfig`（见 §4）。
- 最终工程的 `SWIFT_VERSION = 5.0`（迁移期保持 Swift 5 language mode，R12），
  `IPHONEOS_DEPLOYMENT_TARGET = 27.0` / `MACOSX_DEPLOYMENT_TARGET = 27.0`，
  iOS `TARGETED_DEVICE_FAMILY = 1,2`。

### 2. 本地包接线是两段固定 JSON

工程根（与 `files` / `targets` 同级）：

```json
"packages": [
  { "kind": "local", "path": "../../client" },
]
```

target 内（与 `build-phases` 同级）：

```json
"package-product-members": [
  { "package": "client", "product-name": "ClientKit",
    "build-phase": { "build-phase": "frameworks" } },
]
```

- `path` 相对 `.xcodeproj` 所在目录；`package` 是 target 里引用的包名（即 `packages` 条目的
  `name`；本地包条目可省略 `name`，写了也必须等于 `Package.swift` 的包名），`product-name`
  是 `products:` 里的产品名。
- `build-phase` 是嵌套对象 `{ "build-phase": "frameworks" }`，不是字符串 `"frameworks"`；
  不需要额外的 frameworks build-file 条目。
- **每个 package 的 `Package.swift` 必须声明 `platforms:`**，且与 app 的部署目标一致；否则
  Xcode 27.2 会静默丢掉 product（解析看似成功，构建报 `Missing package product 'X'`）。
  用字符串形式 `.macOS("27.0"), .iOS("27.0")` 可继续用 `swift-tools-version: 6.0`；若用
  `.v27` 枚举则需 tools 6.4——迁移期选择字符串形式，少动 manifest。

### 3. 工程创建/修改流程

以 spike B 的两个工程为模板（`.spikes/xcodeproj/apps/{ios,macos}`，gitignored）复制并改
target/product/id/scheme；改完用 `xcodebuild -list` 让解码器报错即修 JSON。不手点 Xcode 生成
工程，避免不可复现的差异。

### 4. 统一导航是 `workspace.xcworkspace`，共享配置是 `Configs/Shared.xcconfig`

- 根 `workspace.xcworkspace/contents.xcworkspacedata` 是 XML；用
  `<FileRef location = "group:<相对路径>">` 把工程和包目录加进导航，路径相对 `.xcworkspace`
  所在目录（repo 根）。指向含 `Package.swift` 的目录的 FileRef 会被当作本地包加载：
  `xcodebuild -list -workspace` 会列出 `Package: client / contract / server` 与
  `Resolved source packages`。当前成员是 `apps/ios/iOS.xcodeproj` 与三个包
  （`client` / `contract` / `server`）；macOS 工程和 `design/` 包落地后再加 FileRef。
  workspace 只做导航，构建/测试入口仍是根 `Makefile`。
- `Configs/Shared.xcconfig` 是 team / 版本 / bundle id 的单一来源：
  `DEVELOPMENT_TEAM = 289223FXNS`、`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、
  iOS 的 `PRODUCT_BUNDLE_IDENTIFIER = com.criphc.Photon.Client`（macOS 的 bundle id 以注释
  占位，随 macOS 工程接线）。
- JSON 工程支持 **per-configuration base configuration**：工程根的 `configurations` 可以写成
  对象（target 上是 `specialized-configurations`），`file` 值是该 xcconfig 在工程 `files`
  树里的 name path（导航器里的名字路径，不是文件系统路径）：

  ```json
  "configurations": [
    { "name": "Debug", "file": "Configs/Shared.xcconfig" },
  ],
  ```

  xcconfig 自身必须在 `files` 树里有一个引用；iOS 工程加一个 `Configs` group
  （`path = "../../Configs"`）和它的 `Shared.xcconfig` 文件引用。路径写成字符串时锚点是
  name path；xcconfig 是 folder-sync 发现的内容时用
  `{ "anchor": ..., "relative-path": ... }` 形式。
- 因此 apps/ios 的 `DEVELOPMENT_TEAM` / `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` /
  `PRODUCT_BUNDLE_IDENTIFIER` 已从工程 JSON 移到该 xcconfig；改值只改 xcconfig。根 Makefile 的
  `IOS_BUNDLE_ID`（`ios-launch` 用）是同一 bundle id 的副本，改 id 时两处同步。

## 证据（spike B + P0 复核）

- Xcode 27 的工程模板原型在
  `/Applications/Xcode.app/Contents/Frameworks/IDEFoundation.framework/Versions/A/Resources/UntitledAppProjectPrototype/Project.xcodeproj/project.xcproj`；
  `DevToolsCore` 的 JSON coding-key 表给出 kebab-case 键名。
- 两个 spike app（iOS `generic/platform=iOS`、macOS `platform=macOS`）通过 Xcode 构建：
  `BUILD SUCCEEDED`；构建日志有
  `Explicit dependency on target 'SpikeSupport-product'`；`nm`/`strings` 在
  `*.debug.dylib` 里找到 `_$s12SpikeSupportAAO8greetingSSyFZ` 与包内字面量。
- P0 复核：把外层 DSH 沙箱放开（一次性 full-access）后，同样两个工程用
  `xcodebuild build ... CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`
  均 `BUILD SUCCEEDED`。**工程格式与包接线本身是正确的。**
- workspace 与 xcconfig（2026-11-06 接线复核，DSH 内）：
  - 加 FileRef 后 `xcodebuild -list -workspace workspace.xcworkspace` 在 Package Graph 阶段
    列出 `Package: client / contract / server`（说明 FileRef 被当作本地包），随后与工程构建
    失败在同一处（见下节）。
  - 把 `apps/ios` 的工程 JSON 复制到 `.tmp` 并只去掉 package 引用（DSH 内唯一能过解码的做法），
    JSON 与 `Configs/Shared.xcconfig` 原样保留；`xcodebuild -showBuildSettings` 在 Debug 与
    Release 都得到 `MARKETING_VERSION = 1.0`、`CURRENT_PROJECT_VERSION = 1`、
    `DEVELOPMENT_TEAM = 289223FXNS`、`PRODUCT_BUNDLE_IDENTIFIER = com.criphc.Photon.Client`；
    删掉 `Configs/` 后四项全部为空（证明值来自 xcconfig，不是默认值）。
  - 真实工程的 `xcodebuild -list -project apps/ios/iOS.xcodeproj` 在 DSH 内仍只报 package
    resolution 失败、不报 JSON 键错误 → 含 `configurations` 对象的新 JSON 通过了解码。

## 已知限制与已定方案：DSH 下的 headless xcodebuild

在 **agent 的 workspace-write 沙箱内**，任何引用 SwiftPM 包的工程都会在解析阶段失败：

```
xcodebuild: error: Could not resolve package dependencies:
  sandbox-exec: sandbox_apply: Operation not permitted
```

原因是 DSH 外层已经是一个 sandbox，嵌套 `sandbox-exec` 被拒（`sandbox-exec -p '(allow default)'
/bin/echo` 也失败），同时 `~/Library/Caches` / `~/Library/Preferences` 只读。已验证：

- 不含包的工程 headless 构建正常 → 不是工程格式问题；
- workspace 同样命中：`xcodebuild -list -workspace workspace.xcworkspace` 在 Resolve Package
  Graph 阶段失败；错误发生在 workspace/工程解码之后（可用来区分格式错误与环境失败）；
- `CFFIXED_USER_HOME` / `SWIFTPM_MODULECACHE_OVERRIDE` / `-derivedDataPath` /
  `-packageCachePath` / `IDEPackageSupportDisableManifestSandbox` / `XBS_DISABLE_SANDBOXED_BUILDS`
  都不能让 xcodebuild 跳过 manifest 的沙箱；
- 先用 CLI `swift package --disable-sandbox` 预热 manifest cache，再让 xcodebuild 复用 → 仍然失败；
- 放开外层沙箱后同一命令成功（见上）。

**已定方案（选项 b，2026-11-05 用户拍板）**：

- **agent 内**：app 构建走 **Xcode MCP `BuildProject`**（Xcode 不在 DSH 沙箱内，能编译 package
  manifest；spike B 与 P0 复核均已验证）。app 构建的 agent 验收用 MCP，不用 `xcodebuild`。
- **普通终端 / CI**：根 `Makefile` 的 `ios-build` / `macos-build` 仍用 `xcodebuild`；这些目标在
  非嵌套沙箱环境（你的 shell、CI）可用。
- **根 `AGENTS.md` / 子项目卡片**已把 `make ios-build` 标为普通终端/CI 入口：DSH 内不要拿它
  当 app 构建门禁，改用 Xcode MCP；`make test` / `integration` / `parity` 仍按 Makefile 跑。
- **app 构建的绿** = MCP 构建绿 + 普通终端/CI 的 `make` 构建绿，两者都要记录；不能只报一边。
- 不采用 (a) 放宽 DSH 沙箱，不采用 (c) folder-sync 包源码；不把 token/构建路径依赖藏进脚本。

本 ADR 固定工程格式与接线；构建路径的例外是**环境事实**，不是产品决策。

## 后果

- 两个 app 工程可以完全由 JSON/脚本创建与审阅；app 通过真正的 SwiftPM product 链接包。
- 每个包的 `Package.swift` 必须有 `platforms:`；这是 Xcode 27.2 的硬要求。
- 根 Makefile 里 `ios-build`/`macos-build` 用 xcodebuild；DSH 内由子项目卡片指向 MCP
  `BuildProject`，不把「沙箱内 xcodebuild 失败」误报成红。
- `workspace.xcworkspace` 只是导航入口，不改变任何构建/测试命令；新增工程或包时只加 FileRef。
- team / 版本 / bundle id 改 `Configs/Shared.xcconfig` 一处；`make ios-launch` 用的 bundle id
  仍是 Makefile 里的副本。

## 备选与取舍

- **继续用 Xcode GUI 新建工程**：不可复现、难 review；拒绝。
- **把包源码 folder-sync 进 app**：`xcodebuild` 在 DSH 下能跑，但 app 不再依赖 package，
  模块边界与 `swift test` 门禁都弱化；作为 (c) 备选，不推荐。
- **只保留 `workspace.xcworkspace` 的包导航、不接 product**：app 拿不到类型；拒绝。
