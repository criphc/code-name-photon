---
type: decision
owner: docs
updated: 2026-11-05
---

# ADR-0001：仓库拆成 4 个 SwiftPM 包 + 2 个 app 工程 + 1 个 workspace

- 状态：已接受（2026-11-05，P0）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) §2、R1、R5、R6、R12
- 影响阶段：P1–P5

## 背景

stage 1 只有两个目录：`app/`（`PhotonCore` + `PhotonServer` + `photon` CLI）和 `ipad/`
（Xcode 工程，直接编译 `contract/` 源码）。这个形态能跑通一条照片，但挡不住接下来三件事：

1. iPad UI 要重做（现有 UI 是原型界面，没有设计前提）；
2. 新增 macOS GUI（`appctl` 的套壳），它不应该把 server/engine 编进 GUI；
3. 朝可分享产品演进，需要清晰的模块边界和可独立测试的包。

同时，engine 的行为（wire 形状、8 项交付检查、report 推导、`AtomicFile`、shader parity）
必须零变化。

## 决策

仓库采用「4 个 SwiftPM package + 2 个 app 工程 + 1 个 workspace + 根 Makefile」：

| 位置 | 包 / 工程 | 模块 |
|---|---|---|
| `contract/` | SwiftPM，零依赖 leaf | `ContractKit`（Wire + IPC） |
| `server/` | SwiftPM | `EngineKit`、`ServerKit`、`ServerControl`、`appctl`、`ServerTestSupport` |
| `client/` | SwiftPM | `ClientKit`、`ClientModel` |
| `design/` | SwiftPM，薄 | `DesignTokens`、`DesignComponents` |
| `apps/ios/` | `iOS.xcodeproj` | app target `PhotonClient` |
| `apps/macos/` | `macOS.xcodeproj` | app target `PhotonServerWrapper` |

- **依赖方向**：app → package，package 永不依赖 app。iOS app 链接 `client` / `design`，不链接
  `server`；macOS app 只链接 `server` 的 `ServerControl`，不链接 `EngineKit` / `ServerKit`。
- **engine 留在 SwiftPM**：渲染/编码/验证/交付不搬进 Xcode project，保留 headless 的
  `swift test` 回路。
- **部署目标**：iOS 27 / macOS 27；工具链 Swift 6.4，但**迁移期间保持 Swift 5 language mode**，
  避免并发改造混进搬家。Swift 6 模式是迁移后的独立步骤/ADR（R12）。
- `workspace.xcworkspace` 只做导航：两个工程 + 四个包；构建/测试入口仍是根 `Makefile`。
- `Configs/Shared.xcconfig` 承载 team / 版本 / bundle id 占位。

## 后果

- 每个包可以独立 `swift test`；server/engine 的 CI 回路不依赖 Xcode。
- app 工程必须能链接本地 SwiftPM 包 —— 这是 P0 用 spike B（[ADR-0009](0009-xcode27-project-format.md)）
  先验证的风险点。
- 目录移动本身不改变任何 engine 行为；P1–P4 每阶段都有独立门禁，可回滚。

## 备选与取舍

- **保留 `app/` + `ipad/` 两个大目录**：省事，但 macOS 壳会被迫链接 server，UI 与 engine 继续
  纠缠；拒绝。
- **只做一个 SwiftPM 包**：iOS 会链接到 server/engine 的模块图，边界名存实亡；拒绝。
- **把 engine/CLI 搬进 Xcode project**：会破坏 headless 测试与 Makefile 门禁；红线，拒绝。

## 验证

- P0 spike B：两个空 app 工程链接本地包并 headless 构建通过（结论见
  [ADR-0009](0009-xcode27-project-format.md)）。
- P2/P3 的 `make test`、`make integration`、iOS build 是这条结构的正式门禁。
