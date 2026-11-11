---
type: agent
owner: contract
updated: 2026-11-10
---

# contract

两端共享契约（SwiftPM `ContractKit`，零 I/O）：recipe schema、mask/gain 数学、Rec.709 luma、wire 类型、appctl→GUI IPC 事件。改动同时影响 server 与 client。

## 布局

- `Wire/` — HTTP JSON 类型的唯一定义：item 列表、health、SDR-base preview 元数据 + `recipeDefaults`、prepare/recipe 响应、API 错误
- `IPC/` — appctl→GUI stdout 事件：`ReadyEvent` / `ErrorEvent` / `ProcessEvent`
- 其余按功能分文件：recipe schema 与 `renderKey()`、mask/gain 数学、HDR 夹取、几何与错误族；文件级细节以源码为准

## 命令

| 目的 | 命令 |
|---|---|
| 契约测试 | `make contract-test` |
| 全部测试 | `make test` |

## 不许破坏

- `Wire/` 是 HTTP JSON 的唯一定义；server/client 只 import，不镜像（ADR-0004）。
- 金样例只在 `Tests/ContractKitTests/Fixtures/schema-0/`；改这些字节 = 改 schema 版本。
- `IPC/` 只放 GUI↔CLI 事件，不放 HTTP 类型；argv/env 与进程状态机在 `ServerControl`（ADR-0010）。
- recipe 字段只选择渲染，不得修改 SDR 底图；`renderKey()` 的输入集合不可扩大。
- 零 I/O：只允许 Foundation/CryptoKit。
- 依赖方向：`server`/`client` 以 path dependency 链接本包，`apps/ios` 经 SwiftPM product 链接；package 永不依赖 app。

## 环境

- Swift 6 工具链；无第三方依赖。

## 去哪看

- 字段 / 数学 / `renderKey` → `../docs/reference/recipe.md`；wire / IPC → `../docs/reference/wire.md`、`ipc.md`
- 决策 → `../docs/decisions/0004-wire-contract-single-source.md`、`0010-appctl-process-contract.md`
