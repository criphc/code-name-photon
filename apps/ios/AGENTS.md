---
type: agent
owner: apps/ios
updated: 2026-11-10
---

# apps/ios

iOS app（target `PhotonClient`）：iPhone + iPad，iPad 优先。v1 已收尾（2026-11-08）：横屏三栏（连接｜画布+胶片条｜调整）接上 `SessionModel` / `JudgeModel`，规格固化在 `docs/ui/spec/`。

## 布局

- `iOS.xcodeproj` — Xcode 27 JSON 工程；target `PhotonClient`；链接 `client` / `contract` / `design` 包；导航入口是根 `workspace.xcworkspace`
- `Sources/App/` — `@main`、`ProductRootView`（`NavigationSplitView` + `.inspector`）、`DevelopView`；`Resources/` — Info.plist、Assets
- `Sources/Features/{Connection,Library,Judge}/` — 三个区；`Judge/` 里还有画布渲染器、直方图、参数行、cap picker / compare / 状态条控件；编辑历史在 `client/Sources/ClientModel/EditHistory.swift`，不在 app 里

## 命令

| 目的 | 命令 |
|---|---|
| 编译检查 / 设备签名 / 安装、启动 | `make ios-build` / `ios-build-device` / `ios-install`、`ios-launch` |
| DSH 沙箱内构建 | `ios-build` 跑不了（解析本地包失败，ADR-0009）；用 Xcode MCP 的 `BuildProject` |

## 不许破坏

- **系统控件优先**：非必要不自制按钮/工具栏；只有系统不提供的复合视图才进 `design/Sources/Components`。
- **一次只改一屏/一个组件**；同一屏的多个方案先在 `#Preview` 里摆出来，由用户比较后收敛。
- **验收 = `#Preview` + 用户亲眼看**：每个改动留 `#Preview`，交付时说清文件与行号；用户随时在 Xcode canvas 看，阶段性在 iPad 实机验收。agent 不启动模拟器、不截图；可以用 headless preview 渲染自检。
- app 依赖 package，package 永不依赖 app；iOS 不链接 `server` 包。判图 UI 只用 `SessionModel` / `JudgeModel`，不写第二个状态机。
- 不改写 base 像素；渲染层只是 ClientKit 那份 MSL 的调用方，数学不在 app 里。
- 交互元素带 `accessibilityIdentifier`（v1 规格，首个稳定屏接入）。
- team / 版本 / bundle id 只在 `Configs/Shared.xcconfig` 改，不写回工程 JSON；`make ios-launch` 的 bundle id 是根 Makefile 里的副本。

## 环境

- iOS 27，`TARGETED_DEVICE_FAMILY = 1,2`，team `289223FXNS`（Personal Team，来自 `Configs/Shared.xcconfig`）；xcconfig 通过工程 `files` 树里的 `Configs` group 引用；设备 UDID `00008112-001E055E3EF0C01E`；验收以 iPad XDR 为主，Mac (Designed for iPad) 需外接 HDR 显示器。

## 去哪看

- UI 工作方式与踩坑、规格与 token → `../../docs/ui/`（数值在 `design/Sources/Tokens`）；客户端架构 → `../../client/AGENTS.md`、`../../docs/reference/client.md`；判图硬件与验收 → `../../docs/reference/hardware.md`
