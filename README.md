# HDR Highlight Finisher

个人工具：把 Capture One 导出的 16-bit **Display P3** TIFF 做成 **gain-map HEIC（ISO 21496-1）** 的 HDR 照片。Mac 负责色彩管理渲染、编码、验证与交付；iPad 在 XDR 屏上判图，只回传一份带版本号的 recipe。Capture One 的 SDR 导出始终是权威底图。

**当前状态**：项目迁移已结束；v1（iPad UI）与 v2（server/engine）均已收尾，macOS GUI 推迟——见 [docs/status.md](docs/status.md)。

## 阶段

- **v1**（iPad UI 重做）与 **v2**（server/engine：进程内 Core Image 编码器、profile 门禁、缩略图、batch deliver）均已收尾；见 [docs/ui/plan/v1-plan.md](docs/ui/plan/v1-plan.md) 与 [docs/plans/v2-plan.md](docs/plans/v2-plan.md)。
- 历史 `M{0-5}` / `P{0-6}` / stage-1/2/3 编号只出现在 `docs/plans/` 与 `docs/archive/`，不再是路线图。

## 目录

```text
workspace.xcworkspace  工程 + 包的统一导航（当前：iOS 工程 + 3 个包）
Configs/                共享 xcconfig（team / 版本 / bundle id）
server/                 Mac 端 SwiftPM：EngineKit + ServerKit + ServerControl + appctl
contract/               两端共享契约（无 I/O）：recipe / wire / IPC
client/                 判图客户端包：ClientKit + ClientModel
design/                 v1 新建：DesignTokens + DesignComponents（薄）
apps/ios/               PhotonClient iOS 工程（iPad 优先；v1 重做 UI）
docs/                   文档：status、reference、plans、decisions、ui（v1）、archive
fixtures/               本地素材（gitignored）
tools/                  toGainMapHDR（外部 clone，仅 oracle）、verify-heic、visual-check、make-fixtures
AGENTS.md               agent 入口：命令、红线、文档路由
```

## 文档

[docs/README.md](docs/README.md) 是按任务导航的索引。最常看的是 [docs/reference/](docs/reference/)（精确事实）与 [docs/status.md](docs/status.md)（现在做到哪）。

## 开发环境

- macOS 27.2 / Apple Silicon / Xcode 27.2 / Swift 6.4；判图需 iPad Pro（M2，Liquid Retina XDR），iPadOS 27。
- 编码在进程内（Core Image/ImageIO）；`tools/toGainMapHDR/` 是外部 MIT clone，只作本地 differential oracle，不随仓库跟踪，不是 `make test` 的前提。
- `fixtures/media/`、`tools/toGainMapHDR/`、`docs/archive/stage-1/delivery/` 仅本地存在。

## 说明

- 归档 `docs/archive/` 是冻结的历史文档与证据，非必要不读；新决策写活文档。
- 视觉验收工具只展示，不能证明 HDR；判断 HDR 只用 ImageIO（`tools/verify-heic`）。
