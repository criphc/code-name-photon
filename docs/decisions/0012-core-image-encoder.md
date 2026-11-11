---
type: decision
owner: docs
updated: 2026-11-09
---

# ADR-0012：用进程内 Core Image/ImageIO writer 替换 `tools/toGainMapHDR`

- 状态：已接受（2026-11-09，v2）
- 关联：[encoder.md](../reference/encoder.md)、[container.md](../reference/container.md)、
  [deliver.md](../reference/deliver.md)、[recipe.md](../reference/recipe.md)、
  [ADR-0011](0011-headroom-mismatch-is-a-warning.md)、
  [v2-plan](../plans/v2-plan.md)、[engine-spike-report](../plans/engine-spike-report.md)
- 影响阶段：v2 engine（编码器、输出 profile、metadata、交付门禁）

## 背景

v1 的唯一容器 writer 是外部 MIT clone `tools/toGainMapHDR`：不进仓库，跑 `make test` 前要手动
clone；每张图起一个子进程；只能写 8-bit base；不能带 EXIF/GPS/orientation；`-R` 在 `-b` 下无效；
`-H` 会写坏 headroom；alpha 依路径而变；交付 headroom 上限约 8×。v2 需要可配置 profile
（8/10-bit、质量、full/half map、ISO RGB/mono）、metadata 透传，以及能准确写 `AlternateHeadroom`
的 writer（ADR-0011 的重审条件）。

## 决策

1. **writer 进程内化**：`EngineKit.CoreImageHEICEncoder` 实现 `HEICEncoder` 协议；
   `DeliveryPipeline` 只依赖协议，不再依赖外部工具。`HEICEncodeRequest` 收 `LinearImage` 的
   SDR base + HDR rendition + authored peak + `HEICEncodeOptions` + 源 URL + 输出 URL
   （SDR fallback 可空，每个 delivery 只写一次）；`HEICEncodeResult` 返回读回 facts、
   gain map 尺寸/类型和分步耗时。
2. **Path A**：`CIContext.writeHEIF10Representation`（10-bit）/ `writeHEIFRepresentation`（8-bit）
   + `.hdrGainMapImage` + `.hdrGainMapAsRGB`。Path B（`CGImageDestinationAddAuxiliaryDataInfo`
   + raw aux）在 macOS 27 上 `Finalize` 失败，不作为 v2 路线；`kCGImageDestinationEncodeRequest`
   留作以后单独 spike。
3. **metadata rewrap**：`CGImageDestinationCopyImageSource` 复制编码好的 HEIC（base + ISO aux），
   只把 image metadata 换成过滤后的源 TIFF `CGImageMetadata`；保留 EXIF/TIFF/GPS，丢
   XMP/IPTC/Photoshop；orientation 是 TIFF tag，原样透传，解码端假定 1，不做旋转分支。
4. **profile 是配置**：`HEICEncodeOptions` 承载 bit depth（8/10）、quality、map resolution
   （full/half）、map kind（iso-rgb/iso-mono）；默认 `10/half/rgb`；recipe 的 `encoder` 块是
   默认 profile，CLI 可传列表。产物按 profile 命名 `{stem}-hdr-{profile}.heic`；
   `{stem}-sdr.heic` 固定 8-bit、无 aux、所有 profile 共享。
5. **10-bit base 是 profile，不是红线**：v1 的 container 规则「不要升 10-bit」被本 ADR 反转。
   旧规则的前提是「10-bit 文件没有 8-bit SDR fallback」；v2 的 fallback 是独立的 8-bit
   `{stem}-sdr.heic`，前提不再成立。gain map 仍是精度瓶颈，10-bit 只多约 25% 字节。
6. **ISO gain map metadata**：从 checked-in 的 `Resources/iso-gainmap-template.heic` clone 后改；
   `HDRToneMap:AlternateHeadroom` 与每个 channel 的 `GainMapMax` 都设为 `log2(authoredPeak)`，
   `GainMapMin` 设为 0，与 `GainMap` 的归一化一致。
7. **外部工具降级为 oracle**：`toGainMapHDR` 只做本地、时间盒的 differential 对照
   （base/headroom/像素），不进 CI，不再是 `make test` 的前提；新 engine 通过 8 项检查 +
   differential 后删除。
8. **ADR-0011 回收**：新 writer 能准确写 `AlternateHeadroom`，`headroom` 的 5% 匹配恢复为
   gate（verifier 已按此实现）；FPL05190 与 R0003777 的实机重跑作为验收证据补上。

## 证据

2026-11-09，M1 Max / macOS 27.2，6000×4000 trial image：

| 指标 | Path A 10-bit half | Path A 10-bit full | 外部工具 8-bit full |
|---|---:|---:|---:|
| preview ΔE2000 mean | 1.82 | 1.82 | 1.17 |
| base ΔE2000 mean | 1.06 | 1.06 | 1.44 |
| `contentHeadroom` | 2.176 | 2.176 | 2.176 |

- 8-bit half 的 preview mean 2.17（spike 表 2.1665），所以 half-res 的 `previewAgreement` 需要
  profile 阈值（10% PASS / 20% warning）；full-res 仍 5%。
- Path A 的 10-bit 文件 6.4 MB；aux `PixelFormat` 是 `420f`（RGB）或 `L008`（mono），half-res
  尺寸是 base/2。
- Path B 的失败记录、half-res 全表和 rewrap 细节见
  [engine-spike-report](../plans/engine-spike-report.md)。

## 后果

- 不再需要 clone / `ENCODER` / `PHOTON_ENCODER` 环境；编码在进程内，无子进程，也不再落
  staging TIFF。
- 输出 profile、metadata、per-profile report（schema 1）成为交付契约的一部分；8 项检查按
  profile 重新标定。
- 确定性口径改为：同机同 OS 字节一致；跨 OS 接受像素级（base bit-exact + HDR decode ΔE 0 +
  metadata 一致），测试 pin OS。
- 外部工具的 `-H`/`-R` 旧坑随工具一起退出交付路径，只留在 oracle 对照里。

## 重审条件

- Path B 的 `kCGImageDestinationEncodeRequest` surface 成熟，或 Path A 的 metadata/质量不够时，
  重开 writer 路线。
- gain map 计算改用 Core Image kernel/vImage 后，重测性能与 half-res 阈值。
- 4-stop/16 进 v2 时，重跑 8 项检查与 headroom gate。
- 跨 OS 确定性有实测冲突时，重定 determinism 口径。
