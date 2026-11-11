---
type: record
owner: docs
updated: 2026-11-09
---

# v2 执行计划：server 与 engine

*2026-11-09 启动。v1 已收尾；本计划只覆盖 server 与 engine，UI 不动。*

## 范围

- **engine**：用 Core Image/ImageIO 自研 HEIC writer 替换 `tools/toGainMapHDR`；输出不是固定 10-bit，而是可配置的 profile：
  - bit depth：8 / 10；
  - 压缩质量；
  - gain map 分辨率：full / half；
  - gain map 类型：ISO RGB / ISO mono（Apple 风格）；
  - SDR fallback 固定 8-bit。
- **metadata**：EXIF/GPS/orientation 透传；orientation 只保留 tag，解码端假定 1，不做旋转分支。
- **交付门禁**：8 项检查按 profile 重新标定；新 writer 能准确写 `AlternateHeadroom` 后，把 ADR-0011 的 headroom warning 恢复为 gate。
- **server**：thumbnail API（胶片条不再拉 preview base）+ `serve` 启动并行预热缩略图；同步 `appctl deliver --batch`（已完成）。
- **previewAgreement**：已修复（2026-11-09）；保留短回归。
- **verify 性能**：已优化（2026-11-09）；debug verify 84.9 → 11.1 s。

## 非目标

- 多批次/目录树：单批次、单层目录够用。
- cap 16 / 4-stop：v2 不做；recipe cap 仍 1…8。
- async 交付队列 / 重启恢复 / recipe-post 自动交付：v2 不做。
- TLS/Bonjour、macOS GUI、UI 改动：不做。
- 10-bit 之外的容器格式（AVIF/JPEG Ultra HDR）：不做。

## 决策

- **输出 profile 是配置，不是常量**：bit depth（8/10）、质量、map 分辨率（full/half）、map 类型（ISO RGB / ISO mono）都走 `HEICEncodeOptions`；recipe 的 `encoder` 块承载这些字段。
- **默认 profile set**：`10/half/rgb`；可选 `8/half/rgb`、`10/full/rgb`、`10/half/mono`；“同时”= 传一个 profile 列表（例如 8+10）。
- **一个 delivery 一个 report，按 profile 分组**（`profiles: [...]`），不是每个 profile 一个文件。
- **fail-closed**：所有请求的 profile 都 PASS 才安装整个 set；任何一个失败，什么都不装。
- **Path A + rewrap**：`writeHEIF10Representation` + `.hdrGainMapImage` + `.hdrGainMapAsRGB`；metadata 用 `CGImageDestinationCopyImageSource` + 源 TIFF 的 `CGImageMetadata`。Path B 的 raw-aux 在 macOS 27 上 finalize 失败，不在 v2 路线。
- **metadata 只留 EXIF/GPS/orientation**：丢掉 XMP/IPTC/Photoshop；GPS 带；orientation 只透传 tag，解码端假定 1，不做旋转分支。
- **`{stem}-sdr.heic` 固定 8-bit**。
- **半分辨率 `previewAgreement`**：`fractionAbove5 ≤ 10%` 干净 PASS；10–20% PASS + warning；>20% FAIL；mean < 2.5 / p99 < 10 不变。full-res 仍 5%。
- **Apple mono 是 v2 交付 profile**：Path A `.hdrGainMapAsRGB: false` 写 ISO mono `L008`；gate 语义按 profile 定（`container` 记录 map kind）。
- **确定性**：同机同 OS 字节一致；跨 OS 接受像素级（base bit-exact + HDR decode ΔE 0 + metadata 一致），测试 pin OS。
- **oracle**：`toGainMapHDR` 只保留到新 engine 就位为止；本地、时间盒的 differential tool，不进 CI。
- **缩略图与 preview base 分离**：胶片条用 512 高、10-bit HEIC（ImageIO 降采样解码，不走 Core Image）；判图仍用 2560/16-bit base。预热并发 4（实测 12 张 0.65 s、`phys_footprint` 137 MB）。见 [ADR-0013](../decisions/0013-thumbnail-api.md)。
- **batch deliver 全串行**：不做 item/profile 并发；已完成。
- **verify 优化先落地**：strip 并行 + `Colorimetry.lab` 标量化 + clipping 并行；`make appctl` 改 release。

## 工作流

### 1. previewAgreement（已完成，2026-11-09）

- 结论：可复现的 preview 路径非确定性，不是 encoder 归一化；根因是 GPU `CIContext` 的 render 偶发不写 destination buffer。
- 修复：`CIRender`（`CIRenderDestination` + `waitUntilCompleted`，共享 `CIContext`）；压力测试 20/20，同一 recipe 8/8 PASS。
- 回归：`server/Tests/EngineKitTests/PreviewAgreementStressTests.swift` 保留；默认 5 轮（merge gate），`PHOTON_PREVIEW_STRESS=1` 跑 20 轮。
- 证据与结论见 [preview-agreement-investigation.md](preview-agreement-investigation.md)。

### 2. Core Image engine + 输出 profile

- 目标：`HEICEncoder` 单 profile 抽象 + `DeliveryRenderContext`（source + SDR base + HDR rendition + 最高请求分辨率的 gain map）；pipeline 循环 profile。
- 输入：`LinearImage` SDR base + `LinearImage` HDR rendition + `Recipe` + `SourceMetadata` + `HEICEncodeOptions`；不再落 staging TIFF。
- 输出：Path A 写 base（8/10）+ gain map（full/half，ISO RGB / ISO mono）+ ISO metadata；`CopyImageSource` rewrap 写 EXIF/GPS/orientation；`EncodedHEICFacts` 读回。
- 关键点：10-bit 量化、gain map 的 log2 编码与 metadata、half-res 尺寸、no alpha、SDR fallback、`contentHeadroom` 与 authored peak 一致。
- 迁移：`HEICEncoder` 协议 + `ExternalToolEncoder`（oracle，时间盒）+ `CoreImageHEICEncoder`；`DeliveryPipeline` 改为依赖协议；oracle 只本地跑，新 engine 通过 8 项 + differential 后删除。
- spike 初测结果见 [engine-spike-report.md](engine-spike-report.md)：Path A 可行，Path B raw-aux 在 macOS 27 失败，metadata rewrap 可用，half-res 需要 profile 阈值。
- 验收：每个 profile 的 8 项检查全 PASS；`verify-heic` 交叉检查；10-bit/半分辨率/EXIF 读回断言；同一输入与 oracle 的 base/headroom/像素对比。
- 文档：ADR-0012（替换 encoder、profile、metadata）；重写 [encoder.md](../reference/encoder.md)；改 [container.md](../reference/container.md) 的 10-bit 红线；改 [deliver.md](../reference/deliver.md) 的阈值；删 [server/AGENTS.md](../../server/AGENTS.md) 的 clone 说明和 [Makefile](../../Makefile) 的 `ENCODER`。

### 3. 门禁重标定

- `baseDeltaE`：8-bit 与 10-bit base 的 codec loss 分别测；阈值按 profile 定。
- `fallback`：8-bit map-stripped copy 的 LSB/ΔE 阈值重测。
- `headroom`：新 writer 准确写 `AlternateHeadroom` 后，5% 匹配从 warning 恢复为 gate（ADR-0011 回收）；FPL05190 是试金石。
- `container`：ISO RGB（`tmap` + ISO aux，`420f`）与 ISO mono（`tmap` + ISO aux，`L008`）分别定义 PASS 规则；legacy Apple `HDRGainMap` 不用。
- `previewAgreement`：full-res 5%；half-res 10% PASS / 20% warning。
- `clipping`/`alpha`/`identity`：按 profile 读回检查。
- `verify-heic`：8/10-bit base、full/half map、RGB/mono map、EXIF/orientation 的断言。

### 4. thumbnail API + 启动预热

- **端点**：`GET /api/items/{id}/thumbnail` → 512 高、10-bit HEIC、Display P3；on-demand 生成 + 缓存。无新 `Wire/` 类型，schema-0 金样例不变。
- **渲染**：`EngineKit.ThumbnailRenderer`；ImageIO 降采样解码 + HEIC 写，**不走 Core Image**（成本在解码；且避免再引入 GPU render 写入路径）。orientation/P3 校验只读 properties。
- **尺寸**：按高度 512，`maxPixelSize = min(ceil(512 * max(1, width/height)), 2560)`；与 client `ThumbnailCache.maxPixelHeight` 对齐，2560 宽上限保持旧路径（从 2560 长边 base 缩）的物理上限。
- **缓存**：`thumbnail-512-v1.heic`；文件名编码高度 + 渲染器 tag，命中要求可打开且 header 高在 1…512；不含 `appVersion`。
- **预热**：ready line 之后后台跑整批，**并发 4，默认开、无关闭开关**；渲染不持主锁，按 item id 去重。
- **state**：推导忽略缩略图（只有缩略图仍是 `pending`）；缩略图失败不改 item 状态。
- 不做：`appctl prep --batch`；「prepare 第一张」。
- 决策与实测见 [ADR-0013](../decisions/0013-thumbnail-api.md)。

### 5. batch deliver（同步、串行）

- `appctl deliver --batch <dir>`：对 batch 内所有有 stored recipe 的 item 逐张 deliver；item 之间串行，profile 之间也串行；失败继续/汇总；复用现有 pipeline。
- 一个 item 的多个 profile 共享 `DeliveryRenderContext`，但编码和 verify 串行。
- 不做 queue/重启恢复。

### 6. verify 性能（已完成，2026-11-09）

- 84.9 s 的 verify 里 96% 是 scalar 逐像素循环；strip 并行 + `Colorimetry.lab` 标量化 + clipping 并行后，debug verify **11.14 s**（实测，delivery 20.48 s），8 项检查数值不变。
- `make appctl` 改 release；release 实测 verify **3.96–3.97 s**（delivery 8.1–8.4 s）。
- 细节与 benchmark 见 [verify-performance-investigation.md](verify-performance-investigation.md)。

## 顺序

1. ~~previewAgreement 调查~~ 已完成（2026-11-09）。
2. ~~verify 优化~~ 已完成（2026-11-09）：并行 + 标量化 + clipping；release appctl。
3. ~~engine 设计评审 + ADR-0012~~ 已完成（[ADR-0012](../decisions/0012-core-image-encoder.md)）。
4. ~~Path A + rewrap 生产 `HEICEncoder` + 输出 profile~~ 已完成（`b14b208`、`9f81b5c`）。
5. ~~门禁重标定~~ 已完成（2026-11-09）：headroom gate 恢复、half-res 10/20、fallback ΔE 1.5、`baseDeltaE` 按 profile（8-bit 2.5/6.0，10-bit 2.0/5.0）、`verify-heic` 的 10-bit/half/EXIF 断言。
6. ~~`prep`/测试去外部依赖~~ 已完成：`prep` 走新 engine；`EncoderTests` 缺 oracle 时 skip；`make integration` 不再要求 clone。
7. ~~thumbnail API + 启动预热~~ 已完成（2026-11-09）：端点、ImageIO 渲染器、启动并发 4 预热、client 数据源与缓存命名空间。
8. ~~batch deliver（串行）~~ 已完成（2026-11-09）：`appctl deliver --batch`，规则见 [deliver.md](../reference/deliver.md#batch-delivery)。
9. ~~文档收口~~ 已完成（ADR-0012 + reference docs + status）。

## 收尾

**v2 已完成（2026-11-09）**：Core Image engine（Path A + metadata rewrap，HDR 和 8-bit fallback 都带 EXIF/TIFF/GPS/orientation）、profile pipeline、report schema 1、门禁重标定（`baseDeltaE` 按 profile、`verify-heic` 的 10-bit/half/EXIF 断言）、`prep`/测试去外部依赖、`appctl deliver --batch`、缩略图端点 + 启动预热、ADR-0012/0013 + reference docs。真实 R0003777 `10/half/rgb` **8/8 PASS**（release 7.3 s）。`make check` 绿。

**不要做**：多批次/目录树；async 队列/重启恢复；item/profile 并发；TLS/Bonjour；macOS GUI。

## 风险

- 确定性：Core Image/HEVC 跨 OS/硬件不一定字节相同；`DeterminismTests` 要改成同机字节或像素级确定性，并 pin OS。
- metadata 保真：gain map 的 ISO metadata 是主要风险；从已知好文件 clone 再改，读回断言。
- 性能：verify 已从 84.9 s 降到 11.1 s（debug）；batch 全串行，吞吐由 verify + encode 决定。
- 缩略图预热：墙钟大头是读盘与现有的 hash 扫描，不是缩略图本身（单张 138–240 ms，并发 4 下 12 张 0.65 s）；别把预热慢归因错。
- half-res `previewAgreement` 的 mean（2.5）未按 map 分辨率标定（2026-11-10 实机重跑发现）：R0003777 的 ADR-0011 极端 recipe（start 0 / transition 1 / cap 8）在 `10/half/rgb` 下 mean 2.71 > 2.5 FAIL——fractionAbove5 9.6% 在干净带内，full map 下同一 recipe PASS。合法 recipe 可触门禁；下次标定 half-res 阈值时按 map 分辨率处理。
