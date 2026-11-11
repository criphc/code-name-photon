---
type: record
owner: docs
updated: 2026-11-05
---

# P1 报告：ContractKit + Wire + schema-0 金样例

- 日期：2026-11-05
- 分支：`migration/p1`（从 `main` 的 P0 合并点切出），tag `p1`
- 对照计划：[p1-plan.md](p1-plan.md)（有一处提交顺序调整，见 §4）
- 结论：**P1 完成，全部门禁绿**；engine 行为未改，wire 形状仍是 schema 0。

## 1. 门禁结果（最终树）

| 门禁 | 结果 |
|---|---|
| `contract` `swift test` | **47 XCTest + 14 Swift Testing，0 failures** |
| `cd app && make test` | **87 tests，0 failures**（原 134；47 个契约测试搬到了 contract） |
| `cd ipad && make test-macos` | **65 tests，1 expected skip，0 failures** |
| `cd ipad && make parity` | **5 tests，0 failures，0 skips**（trial base 含在内） |
| `cd ipad && make build-ios` | `** BUILD SUCCEEDED **` |
| `git grep PhotonContract`（代码 + 活文档） | 0 条（历史 plan/ADR 保留旧名，描述这次改名） |
| wire 定义唯一性 | `struct ItemSummary` / `enum ItemState` / `struct PreviewMetadata` / `struct APIErrorBody` 只在 `ContractKit/Wire` 各一处 |
| 镜像 DTO | 已删除（server 的 wire 部分 + `ipad/ClientKit/Wire/APIModels.swift`） |

## 2. 交付内容

- **包改名**：`contract/Sources/PhotonContract` → `ContractKit`；package/target/product 都是
  `ContractKit`；平台按 R12 升到 iOS 27 / macOS 27（字符串写法，保持 tools 6.0）。`app` 的
  manifest 同步升到 macOS 27 并链接新 product。
- **测试跟着代码走**：`RecipeTests`、`MaskMathTests`、`HeadroomCapTests` 从
  `app/Tests/PhotonCoreTests` 搬到 `contract/Tests/ContractKitTests`（未重写）。
- **Wire 单一定义**（`ContractKit/Wire`）：
  `ItemModels`、`HealthResponse`、`PreviewMetadata`、`Responses`、`APIError`。
  `ItemSummary` 保留 client 需要的 `Identifiable`/`CaseIterable`；所有 wire 类型统一 `Equatable`。
- **IPC**（`ContractKit/IPC`）：`ReadyEvent`、`ErrorEvent`、`ProcessEvent`，按
  [ADR-0010](../decisions/0010-appctl-process-contract.md) 的 ready/error 行；`StatusEvent` 留到
  P4 真正需要时再加。
- **金样例**：`contract/Tests/ContractKitTests/Fixtures/schema-0/`
  - `server/`：stage-1 真实 server 字节（health、items-final、preview-meta、posted recipe）；
  - `client/`：用同一批真实 payload 组装的 prepare / recipe-post 信封，加上按契约形状写的
    api-error；
  - 作为 package resource 随测试 bundle；contract 测试与 ipad 测试读**同一批文件**
    （ipad 通过 `TestSupport.wireFixtureData` 相对路径），客户端内联 JSON 副本已删。
- **server 侧**：`APIModels.swift` → `ItemStoreProtocol.swift`，只留 `ItemStoreError` /
  `ItemStoreProtocol`；`APIRouter`/`ItemStore`/`HTTPServer`/测试显式 `import ContractKit`。
- **文档**：`contract/README.md` 增加 Wire/IPC 与金样例节；`app/README.md`、
  `ipad/README.md`、根 `README.md`、`AGENT.md` 的模块名/文件列表/环境事实同步。

## 3. 提交

| 提交 | 内容 |
|---|---|
| `0e79675` | `refactor(contract): rename PhotonContract to ContractKit` |
| `dce4784` | `refactor(contract): single home for wire types and IPC events`（含金样例与测试） |
| `c2e27f5` | `docs: point live docs at ContractKit and the single wire home` |

## 4. 与 P1 计划的偏差（内容一致，只调整了拆分）

- 计划里的「先加金样例、再搬 Wire」被合并成 `dce4784`：**金样例测试必须能 import 统一类型**，
  类型还在 server/client 时无法在 contract 测试目标里写。最终内容与计划一致，只是提交数从
  3+文档变成 2+文档。
- `ipad/PhotonTests/WireModelTests.swift` 不只是改 fixture 路径：原内联 JSON 的数值是
  client 自己手写的，和归档真实字节不同；现在改为读共享 fixture，并保留/补充了
  client 行为断言（state raw values、未知 state 报错、显式 JSON null、全部 error code）。
- `items` 金样例是归档的最终列表，只有 `pending`/`recipe_received`/`failed` 三种状态；
  `preview_ready` 由 client 的边界用例覆盖（读取显式 null 的 item）。这比为了凑四种状态去
  伪造字节更诚实。
- `contract`/`app` 的部署目标升到 27 是 R12 的要求，随改名一起落；iPhone/iPad 工程的 26 留到
  P3 新工程。
- 根 README/AGENT 里 `samples/` → `fixtures/media/` 的 P0 搬家事实也顺手修正了。

## 5. 留给后续阶段

- **P2**：`app/` → `server/`、`EngineKit`/`ServerKit`/`ServerControl`/`appctl` 拆分、
  `appctl serve` 的 ready 行、根 Makefile 骨架、`make test`/`integration`。
- **P3**：`client` 包 + 新 iOS 工程（`PhotonClient` / `com.criphc.Photon.Client`）；MSL 搬进
  client 包（[ADR-0008](../decisions/0008-metal-parity-in-swiftpm-tests.md)）。
- **P5**：docs 重组 + `docs-check`；注意排除 `contract/Tests/**/Fixtures/`（金样例里保留旧绝对
  路径），并清理 `app/README.md`/`docs/08` 里仍指向 `samples/` 的示例路径。
- **Swift 6**：按计划不并入迁移；P6 之后独立 ADR/阶段。
- **未做**：根 Makefile、workspace、design/、AGENT 拆分、UI 规格（P2–P6）。

## 6. 复现命令

```bash
cd contract && mkdir -p .tmp .mc && \
  TMPDIR=$PWD/.tmp CLANG_MODULE_CACHE_PATH=$PWD/.mc \
  swift test --disable-sandbox --scratch-path .build

cd app && make test
cd ipad && make test-macos && make parity && make build-ios

# 契约唯一来源
git grep -n PhotonContract -- ':(exclude)docs/archive' ':(exclude)docs/plans' ':(exclude)docs/decisions'
git grep -n "struct ItemSummary" -- app ipad contract
```
