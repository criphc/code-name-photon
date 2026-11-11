---
type: agent
owner: server
updated: 2026-11-09
---

# server

Mac 端渲染 / 编码 / 验证 / 交付 + LAN HTTP 服务；`appctl` 是唯一 server 入口（细节在 `docs/reference/`）。

## 布局

- `Sources/EngineKit/` — 解码 → SDR base → HDR 渲染 → 编码 → 验证 → 原子交付（report 与 8 项检查）
- `Sources/ServerKit/` — M2 LAN 服务：HTTP 编解码、路由/鉴权、item store、batch lookup
- `Sources/ServerControl/` — GUI↔CLI 进程契约：启动配置、readiness、日志、退出状态机（ADR-0010）
- `Sources/appctl/` — `prep` / `serve` / `deliver` 入口；`serve` 的 stdout 是协议
- `Sources/ServerTestSupport/` — 测试专用 fake process/readiness，绝不链接进 appctl
- `Tests/` — EngineKit / ServerKit / ServerControl / Integration（真实 appctl 子进程）

## 命令

| 目的 | 命令 |
|---|---|
| 包测试 | `make server-test` |
| 集成测试（真实 appctl） | `make integration` |
| CLI | `make appctl` / `make cli` |

## 不许破坏

- Capture One 的 SDR 导出是权威底图；只加高光亮度，绝不重新调色 / tone-map（`recipe.md`）。
- 只接受 Display P3 源；非 P3 在 decode 报 `unsupportedSource`，不许静默 clamp（`colour.md`）。
- 判断 HDR 只用 ImageIO；`sips`/Finder 会静默丢 gain map（`container.md`、`verification.md`）。
- 可替换产物一律 `AtomicFile`（temp + `rename(2)`），不 remove+move（`operations.md`）。
- `baseDeltaE` 两种比较不可混用：渲染目标 vs 容器规则（`deliver.md`）。
- 输出 profile 只走 `HEICEncodeOptions`（8/10-bit、quality、full/half map、ISO RGB/mono）；默认 `10/half/rgb`；10-bit base 是 profile，不是红线（ADR-0012）。所有请求的 profile 全 PASS 才安装（fail-closed）。
- metadata 只带 EXIF/TIFF/GPS/orientation；XMP/IPTC/Photoshop 丢掉；orientation 只透传 tag，解码端假定 1。

## 环境

- 编码在进程内（`CoreImageHEICEncoder`，Path A + metadata rewrap）；不需要 clone、`ENCODER` 或 `PHOTON_ENCODER`。
- `tools/toGainMapHDR` 只是本地、时间盒的 differential oracle，不进 CI，也不是 `make test` 的前提。
- `fixtures/media/`（gitignored）：`sources/` 为 P3/AdobeRGB 16-bit TIFF，`reference/` 为 iPhone HDR 参考；夹具运行时生成。
- `PreviewAgreementStressTests` 在 merge gate 默认跑 5 轮（`PHOTON_PREVIEW_STRESS=1` 跑 20 轮），读本机 gitignored 的 `fixtures/media/sources/R0003777-P3.tif` 与 `work/p3-accept/` 工件，缺失即 fail 不 skip——新 clone 需先备好这些本地工件。

## 去哪看

- wire / 交付 / report → `../docs/reference/wire.md`、`deliver.md`
- CLI / 编码器 / 验证 → `../docs/reference/cli.md`、`encoder.md`、`verification.md`
- 决策 → `../docs/decisions/0003-server-internal-layering.md`、`0010-appctl-process-contract.md`、`0012-core-image-encoder.md`
