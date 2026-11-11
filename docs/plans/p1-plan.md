---
type: record
owner: docs
updated: 2026-11-05
---

# P1 执行计划：ContractKit + Wire + schema-0 金样例

- 状态：待用户审核（P0 完成后）
- 上游：[迁移目标结构](00-new-structure-description.md) R2、R4；[ADR-0004](../decisions/0004-wire-contract-single-source.md)
- 范围：只动 `contract/` 与两端对契约的引用；不重做 UI、不改 engine 行为、不加根 Makefile（P2）

## 1. 目标与边界

**做什么**

1. `contract` 包改名：`PhotonContract` → `ContractKit`（目录、target、product、依赖方）。
2. 把 recipe schema / mask-gain 数学相关的测试从 `app/` 搬到 `contract/`（测试跟着代码走）。
3. 新增 `ContractKit/Wire`：HTTP JSON 的 Codable 唯一定义，server 与 client 都 import。
4. 新增 `ContractKit/IPC`：GUI↔CLI 的 ready/status 事件（形状见 ADR-0010）。
5. 建 `contract/Tests/ContractKitTests/Fixtures/schema-0/` 金样例（package resource），
   跑旧字节 × 新类型的解码/编码回归。
6. 删除两端的镜像 DTO（server `APIModels.swift` 的 wire 部分、client
   `Wire/APIModels.swift`），更新所有引用与文档。

**不做什么**

- 不动渲染/编码/验证/交付代码；不改 JSON 字段、不改 recipe 语义、不改 HTTP 路由与状态码。
- 不移动 `app/` → `server/`、`ipad/` → `client/`（P2/P3）。
- 不改 UI、不加根 Makefile、不改 iOS 工程结构（只改 contract 文件夹引用的路径）。
- 不新增 wire 状态（rendered/encoded/verified 属于 stage 2）。

## 2. 文件级清单

### 2.1 contract 包

| 动作 | 路径 |
|---|---|
| 改名目录 | `contract/Sources/PhotonContract/` → `contract/Sources/ContractKit/` |
| 改 manifest | `contract/Package.swift`：target/product 改 `ContractKit`；平台随 R12 升到 macOS 27 / iOS 27；加 `ContractKitTests` 测试 target + `Fixtures` resource；保持 Swift 5 language mode |
| 新增 | `contract/Sources/ContractKit/Wire/{ItemModels,HealthResponse,PreviewMetadata,Responses,APIError}.swift` |
| 新增 | `contract/Sources/ContractKit/IPC/{ReadyEvent,ErrorEvent}.swift`（`StatusEvent` 留到 P4 真正需要时再加，见 ADR-0010） |
| 新增 | `contract/Tests/ContractKitTests/{WireFixtureTests,WireRoundTripTests,IPCContractTests}.swift` |
| 新增 | `contract/Tests/ContractKitTests/Fixtures/schema-0/server/{health,items,preview-meta,recipe}.json` |
| 新增 | `contract/Tests/ContractKitTests/Fixtures/schema-0/client/{prepare-response,recipe-post-response,api-error}.json` |
| 搬入 | `app/Tests/PhotonCoreTests/{RecipeTests,MaskMathTests,HeadroomCapTests}.swift` → `contract/Tests/ContractKitTests/`（改 `import`，保留 XCTest，不借机重写） |
| 更新 | `contract/README.md`（模块名、Wire/IPC 节、fixture 位置；英文） |

manifest 要点：package identity 仍是目录名 `contract`，所以依赖方写
`.product(name: "ContractKit", package: "contract")`；不要写成 `package: "ContractKit"`。

### 2.2 server / app 侧

| 动作 | 路径 |
|---|---|
| 改依赖 | `app/Package.swift`：product `ContractKit`；测试 target 也显式依赖它 |
| 改 import | `app/Sources/PhotonCore/ContractReexports.swift`、`app/Sources/PhotonCore/DeliveryReport.swift`（`import PhotonContract` → `import ContractKit`；typealias 前缀同步） |
| 拆文件 | `app/Sources/PhotonServer/APIModels.swift`：删掉已搬走的 wire 类型；只留 `ItemStoreError` / `ItemStoreProtocol`（必要时改名 `ItemStoreProtocol.swift`） |
| 更新引用 | server 侧对 `ItemSummary` / `ItemState` / `PreviewMetadata` / `PrepareResponse` / `RecipePostResponse` / `APIErrorBody` 的引用改为 `import ContractKit`，不新增本地别名 |
| 更新测试 | `app/Tests/PhotonServerTests/*`：从 `ContractKit` 取 wire 类型；fixture 通过 `#filePath` 相对路径读同一份金样例 |

### 2.3 client / ipad 侧

| 动作 | 路径 |
|---|---|
| 改文件夹引用 | `ipad/Photon.xcodeproj/project.xcproj`：`../contract/Sources/PhotonContract` → `../contract/Sources/ContractKit` |
| 删除镜像 | `ipad/ClientKit/Wire/APIModels.swift`（类型改由同一文件夹编译进 app/test target 提供） |
| 更新测试 | `ipad/PhotonTests/WireModelTests.swift`：删掉内联 JSON 副本，改读 `contract/Tests/ContractKitTests/Fixtures/schema-0/` 的同一份文件；保留错误映射等行为断言 |
| 新增 helper | `ipad/PhotonTests/TestSupport.swift` 增加 fixture 路径解析（`#filePath` 上溯到 repo root） |
| 更新 | `ipad/README.md` 的 Layout/架构里 `PhotonContract` 指路（英文，原路径随 P3 再改） |

### 2.4 doc / AGENT 引用

- `AGENT.md` 里 `contract/`（SwiftPM 包 `PhotonContract`）→ `ContractKit`。
- `app/README.md`、`contract/README.md`、`ipad/README.md` 的模块名与路径同步；旧路径规则见
  [ADR-0007](../decisions/0007-docs-archive-policy.md)（这里改的是活文档，不碰归档）。
- 根 `README.md`/`AGENT.md` 的完整重写仍属于 P5；P1 只做「不改就会说谎」的最小更新。

## 3. 金样例的取舍

- **旧 server 字节**：直接取 stage-1 归档里的真实响应：
  - `docs/archive/stage-1/evidence/m3/evidence/server/health.json`
  - `.../items.json`（或用 `items-final.json`，二选一并说明）
  - `.../m3/server/<sha>/preview-meta.json`
  - `.../m3/evidence/server/recipe-R0003777-P3.json`
- **旧 client 字节**：取 `ipad/PhotonTests/WireModelTests.swift` 里现有的内联 JSON
  （prepare / recipe-post / api-error），**原字节**落盘，不再在测试里复制第二份。
- 归档字节里的 `path` 是旧的绝对路径（`/Users/criphc/Sites/llm-photon/...`）。**保留原字节**，
  不为了 docs-check 去改写金样例；P5 的 `docs-check` 明确排除 `Fixtures/`。
- 断言策略：
  - 每个 fixture 用统一类型解码，断言关键字段（id/state/尺寸/schema/renderKey 等）；
  - 用 `JSONEncoder`（sorted keys）重新编码，与 fixture 的 canonical 形式逐字节比较（pretty
    fixture 先 canonical 化再比）；
  - `WireRoundTripTests` 构造 `PrepareResponse` / `RecipePostResponse`，断言编码结果等于旧
    client 字节的 canonical 形式。

## 4. 提交顺序（每步独立可回滚）

1. `refactor(contract): rename PhotonContract to ContractKit`
   - 目录/manifest/app 依赖/ipad 文件夹引用/reexports/imports；
   - 搬入 3 个契约测试文件；
   - 文档最小更新。
   - 门禁：contract `swift test`、`app make test`、`ipad make test-macos` + `make parity` +
     `make build-ios` 全绿。
2. `test(contract): add schema-0 golden fixtures`
   - fixtures + package resource + fixture/round-trip tests；server/client 测试改读同一份。
   - 门禁：同上。
3. `refactor(contract): move HTTP wire types into ContractKit/Wire`
   - 新增 Wire 类型；删镜像；server/client 引用切换；IPC 类型（若 ADR-0010 已定）。
   - 门禁：同上，外加 `git grep` 确认无镜像定义、无 `PhotonContract` 残留。
4. `docs: point live docs at ContractKit and the single wire home`
   - `contract/README.md`、`app/README.md`、`ipad/README.md`、`AGENT.md` 的引用。
   - 门禁：`git grep` 旧名；P5 才有 `make docs-check`。

完成后在 `migration/p1` 上打 tag `p1`，合回 `main`（用户 review 通过后）。

## 5. 验收命令

```bash
# contract（根 Makefile 要到 P2 才有；先用 SwiftPM 的沙箱写法）
cd contract && mkdir -p .tmp .mc && \
  TMPDIR=$PWD/.tmp CLANG_MODULE_CACHE_PATH=$PWD/.mc \
  swift test --disable-sandbox --scratch-path .build

# server（engine 行为不变；encoder 缺失必须 fail 而不是 skip）
cd app && make test

# client 逻辑 + parity（trial 夹具在 work/m21-final；必须 0 skip）
cd ipad && make test-macos && make parity

# iOS 编译验证（P1 只改文件夹路径，不换工程）
cd ipad && make build-ios

# 契约单一来源
git grep -n "PhotonContract" -- ':(exclude)docs/archive' || true
git grep -n "struct ItemSummary" -- app ipad contract
```

## 6. 风险与注意

- **SwiftPM identity**：path 依赖的 identity 是目录名 `contract`，product 名是 `ContractKit`；
  写错 package 参数会报 “product not found”。
- **iPad 的编译方式**：P1 仍把 contract 源码文件夹编进 app/test target（不是 SwiftPM 依赖）；
  因此 contract 源码里不能出现只有 macOS 可用的 API。P3 才把 client 包接上。
- **重复类型**：删镜像和加新类型必须在同一个提交里，否则 app/ipad 会同时看到两份定义。
- **部署目标**：R12 要求 iOS 27 / macOS 27；contract/app 的 manifest 在 P1 升到 27。iPad 工程的
  `IPHONEOS_DEPLOYMENT_TARGET` 仍留在 26，P3 新工程再升——这不影响 P1 的源码文件夹编译。
- **测试迁移**：从 app 搬走 3 个测试文件是「移动」不是「删除」；app 的测试数下降是预期，
  验收看「全绿 + 0 unexpected skip」而不是数字。
- **fixture 旧路径**：保留原字节；`docs-check`（P5）排除 `contract/Tests/**/Fixtures/`。
- **IPC 形状**：`ContractKit/IPC` 与 `ServerControl` 的 argv/env 契约以 ADR-0010 为准；
  P1 只落可序列化事件，不实现进程管理。

## 7. P1 之后的门（不在本轮）

P2 才移动 `app/` → `server/` 并加根 Makefile；P3 才退役 `ipad/` 与新建 iOS 工程。P1 完成后
`make test` / parity 仍由两个旧目录的 Makefile 跑，属于预期状态。
