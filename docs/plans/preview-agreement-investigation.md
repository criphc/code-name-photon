---
type: record
owner: docs
updated: 2026-11-09
---

# previewAgreement 调查

*2026-11-09 启动；v2 先查 preview 路径，不预设 encoder 归一化。*

## 已知

- 失败证据：`work/p3-accept/bd486ca6…/rejected/5314fd618b56/`（2026-11-05，`migration/p3`）。
- 在 `main` 上用同一 recipe 跑 3 次：3/3 PASS，preview ΔE mean 1.1689 / p95 3.3；HEIC 字节与失败报告相同（sha `1c2ddb33…`）。
- decoded HDR vs `rejected/…/R0003777-P3-hdr.tif`：ratio p50 0.999 / p99 1.005 → decode/encoder 正常。
- 失败报告的 ΔE 分布 p50 32.76、83 % > 5，不像高光边缘的尺度差；更像 preview 侧污染/非确定性。

## 下一步

已完成：见「结果」与「修复」。

## 结果

**结论：可复现（不是 stale report，也不是 encoder 归一化）。** 2026-11-09 在 `main` 上用失败 recipe 跑 20 次预览比较，8 次失败（mean 7.75–51.1，正确值 1.1689），HEIC sha 全程不变；失败报告的 mean 40.1085 落在复现范围内。失败阶段是交付 HDR decode 的 Core Image render，不是 `HDRRendition`、`PreviewRenderer.downscale` 或 encoder。

### 20 次压力测试（`main`，2026-11-09）

命令（独立 scratch/cache，不跑 84 s verifier）：

```bash
cd server && TMPDIR=$PWD/../.tmp-preview CLANG_MODULE_CACHE_PATH=$PWD/../.mc-preview \
  swift test --disable-sandbox --scratch-path ../.build-preview --filter PreviewAgreementStress
```

| iteration | mean | p50 | p95 | p99 | >5 % |
|---|---|---|---|---|---|
| 1 | 51.1059 | 39.990 | 39.990 | 39.990 | 99.79 |
| 2 | 51.1059 | 39.990 | 39.990 | 39.990 | 99.79 |
| 3 | 51.1059 | 39.990 | 39.990 | 39.990 | 99.79 |
| 4 | 1.1689 | 0.810 | 3.300 | 5.280 | 1.25 |
| 5 | 1.1689 | 0.810 | 3.300 | 5.280 | 1.25 |
| 6 | 1.1689 | 0.810 | 3.300 | 5.280 | 1.25 |
| 7 | 38.3171 | 30.730 | 39.990 | 39.990 | 61.03 |
| 8 | 37.2327 | 30.470 | 39.990 | 39.990 | 79.46 |
| 9 | 1.1689 | 0.810 | 3.300 | 5.280 | 1.25 |
| 10 | 7.7514 | 1.090 | 39.890 | 39.990 | 25.17 |
| 11 | 51.1059 | 39.990 | 39.990 | 39.990 | 99.79 |
| 12 | 51.1059 | 39.990 | 39.990 | 39.990 | 99.79 |
| 13–20 | 1.1689 | 0.810 | 3.300 | 5.280 | 1.25 |

HEIC sha 全程 `1c2ddb33…`（与失败报告一致）。失败报告的 mean 40.1085 在本表 7.75–51.1 的范围内，所以 2026-11-05 的失败是同一类非确定性，不是过期报告。

同一天多次复跑：8/20、2/20、6/20 失败（失败 iteration 的 mean 是 51.1059，少数部分失败 50.03 / 38.3 / 37.2 / 7.75），HEIC sha 不变。失败率随 GPU/内存状态波动，符合“静默不写 buffer”的偶发特征。

### 失败阶段定位

对同一 recipe + 同一 HEIC 做 10 次分阶段诊断（`cgPeak` 用 `CGContext` 直接画 decode，绕开 Core Image）：

| iteration | cgPeak | ciPeak | pairPeak | r1Peak | r2Peak | r1==r2 | swPeak |
|---|---|---|---|---|---|---|---|
| 1–5 | 2.166 | 2.166 | 2.500 | 2.497 | 2.497 | yes | 2.497 |
| 6 | 2.166 | 2.166 | 2.500 | 0.000 | 2.497 | NO | 2.497 |
| 7 | 2.166 | 2.166 | 2.500 | 0.000 | 2.497 | NO | 2.497 |
| 8 | 2.166 | 2.166 | 2.500 | 1.449 | 2.497 | NO | 2.497 |
| 9 | 2.166 | 2.166 | 2.500 | 0.000 | 2.497 | NO | 2.497 |
| 10 | 2.166 | 2.166 | 2.500 | 2.497 | 2.497 | yes | 2.497 |

- `cgPeak` / `ciPeak` 2.166：ImageIO 的 HDR decode 正确（不是黑图）。
- `pairPeak` 2.500：`PreviewRenderer.downscale` 的预览 HDR 正确。
- `r1Peak` 0.000 / 1.449：**新建 GPU `CIContext` 的第一次 `PreviewRenderer.render` 偶发只写 0 或部分像素**。
- `r2Peak` 2.497：同一 context 的第二次 render 正常。
- `swPeak` 2.497：软件 renderer 正常。

`.scratch/preview-agreement/` 里保存的失败证据（测试取 20 次里 mean 最差的一次）：`preview-hdr.tif` 正常（max 2.5），`delivered-hdr-preview.tif` 的 RGB 全 0（alpha 1）。

### 根因假设

`PreviewRenderer.render` 用 `CIContext.render(_:toBitmap:...)` 在 GPU-backed context 上偶发在 GPU 完成前返回（或静默失败），destination buffer 保持零初始化（`[Float]` 全 0），函数不检查输出。新建 context 的第一次 render 最容易中招；同一 context 的后续 render 正常。生产里同一 API 既出现在 `PreviewRenderer.downscale`，也出现在 verifier 的 render 中，所以修复要覆盖两处。

### 修复验证（未改生产代码）

同一 HEIC 上 20 次对比：

- **共享一个 `CIContext`**：`sharedR1` 20/20 = 2.519，稳定。
- **`CIRenderDestination` + `startTask(toRender:to:)` + `waitUntilCompleted()`**：20/20 = 2.519，稳定；失败会 throw 而不是静默返回 0。
- `prepareRender` 预热 + destination：20 次里 1 次 throw（预热本身也可能失败，但至少可见）。

### 修复（2026-11-09 已应用）

采用「`CIRenderDestination` + 共享 `CIContext`」的组合：新增 `CIRender`（`CIRenderDestination` +
`CIRenderTask.waitUntilCompleted()`，GPU 命令缓冲被丢弃时重试一次），把 `PreviewRenderer` /
`SourceDecoder` / `DeliveryImageProbe` 的所有 bitmap render 切到它；`CIContext` 改为包级共享
`CIRender.sharedContext`。`CIRenderDestination.isFlipped = true` 保持原来的 top-down 行序。

验证：

- 压力测试 20/20：mean 1.1689 / p95 3.3，HEIC sha 全程 `1c2ddb33…`。
- 失败 recipe 的完整 `appctl deliver`：8/8 PASS，HEIC sha 不变，preview ΔE 1.1689。
- 回归测试保留：`server/Tests/EngineKitTests/PreviewAgreementStressTests.swift`。

### main vs migration/p3

`git diff main migration/p3 -- server/Sources/EngineKit/PreviewRenderer.swift server/Sources/EngineKit/ImageBuffers.swift server/Sources/EngineKit/DeliveryVerifier.swift`：

- `PreviewRenderer.swift`：无差异。
- `ImageBuffers.swift`：只差一条 doc 注释（`docs/reference/encoder.md` vs `docs/08 §3`）。
- `DeliveryVerifier.swift`：doc 路径替换 + ADR-0011 headroom warning（与 `previewAgreement` 无关）。

失败 run 的 commit（`2c83760`，2026-11-05 20:12）与 `main` 的预览路径功能等价，所以不是分支代码差异。

### 证据

- `.scratch/preview-agreement/preview-base.tif`、`preview-hdr.tif`、`delivered-hdr-preview.tif`（float TIFF，2560×1707）。
- 压力测试：`server/Tests/EngineKitTests/PreviewAgreementStressTests.swift`（在 `main` 上会失败，直到 render 修复）。
