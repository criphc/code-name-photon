---
type: agent
owner: client
updated: 2026-11-10
---

# client

判图客户端逻辑（无视图：不 import SwiftUI / UIKit）：`ClientKit` 传输 / 解码 / recipe 草稿 + 唯一 MSL；`ClientModel` 的 `SessionModel` / `JudgeModel` 状态机。iOS app 在 `apps/ios/`。

## 布局

- `Sources/ClientKit/` — 传输（URLSession、超时/取消、下载进度）、错误映射、16-bit P3 PNG base、recipe 草稿、渲染契约、唯一 MSL
- `Sources/ClientModel/` — `SessionModel` / `JudgeModel` 状态机、banner、设置存储、缩略图缓存、编辑历史、状态条数据（`CanvasStatus`）
- `Tests/` — ClientKit（含 parity）/ ClientModel 状态机
- `apps/ios/` — 见 [apps/ios/AGENTS.md](../apps/ios/AGENTS.md)

## 命令

| 目的 | 命令 |
|---|---|
| 包测试 | `make client-test` |
| shader parity（0 failure / 0 skip） | `make parity` |
| iOS 编译检查 | `make ios-build` |

## 不许破坏

- 不写第二个 renderer / 第二个 wire 客户端；`renderKey()` 由 server 返回，客户端不计算。
- 只改 recipe 的 `hdr` + `created`；`base`/`encoder`/`versions` 原样保留。
- 客户端不改写 base 像素；16-bit P3 PNG 只做校验 / 线性化。

## 环境

- iOS 27 / Swift 6；Xcode 27 JSON 工程（`apps/ios/iOS.xcodeproj`，target `PhotonClient`，bundle id `com.criphc.Photon.Client`）。
- agent 内构建用 Xcode MCP；`make ios-build` 供普通终端/CI。
- trial-base 大图 parity 是 opt-in（`make parity` 设 `PHOTON_TRIAL_BASE_PARITY=1` 才跑，夹具 `work/m21-final/preview-base.png` + `meta.json`）；开启而夹具缺失会 **fail**，不 skip（ADR-0008）。

## 去哪看

- 架构 / 控件 / 状态 / 错误 → `../docs/reference/client.md`；wire / 硬件验收 → `../docs/reference/wire.md`、`hardware.md`
