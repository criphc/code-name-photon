---
type: decision
owner: docs
updated: 2026-11-09
---

# ADR-0013：缩略图端点与启动预热（胶片条不再拉 preview base）

- 状态：已接受（2026-11-09，v2）
- 关联：[wire.md](../reference/wire.md)、[client.md](../reference/client.md)、
  [v2-plan](../plans/v2-plan.md)、[ADR-0004](0004-wire-contract-single-source.md)、
  [ADR-0012](0012-core-image-encoder.md)、[preview-agreement-investigation](../plans/preview-agreement-investigation.md)
- 影响阶段：v2 server（M2.1 wire 增量）+ client（缩略图数据源）

## 背景

胶片条的缩略图一直是从 preview base 缩出来的：client 对每个 item 请求 `GET /api/items/{id}/preview`，
server 冷缓存时先跑一次完整 `prepare`（全尺寸解码 + GPU float 渲染 + 2560 长边 16-bit PNG 写盘，
约 22 MB），iPad 收下 22 MB 再用 ImageIO 缩到 512 px。一批 20 张新图连上 iPad 时，这是
**约 440 MB 传输 + 20 次全量渲染**，只为显示一条胶片条；而且它使「浏览」成为全量 prepare 的
触发者。原计划的「`serve` 启动 batch prepare」是在优化这个本不该发生的工作。

浏览只需要 512 px 的显示数据，判图才需要 2560/16-bit 的 base。两者没有理由共用一条路径。

## 决策

1. **缩略图是独立产物**，不属于 `PreviewBaseRenderer`：`EngineKit.ThumbnailRenderer` 从源 TIFF
   直接生成，产物 `work/<sha>/thumbnail.heic`。
2. **新端点** `GET /api/items/{id}/thumbnail`，返回 512 高、HEIC、Display P3 的字节。返回原始
   字节（与 `/preview` 同风格），**不新增 `Wire/` JSON 类型**，schema-0 金样例不变。
3. **用 ImageIO，不用 Core Image**：`CGImageSourceCreateThumbnailAtIndex`（降采样解码）+
   `CGImageDestination`（HEIC，quality 0.8）。理由见下节。
4. **尺寸按高度**：`maxPixelSize = ceil(512 * max(1, width / height))`，与 client
   `ThumbnailCache.maxPixelHeight = 512` 对齐。按长边会让 3:2 横图只有 341 px 高。
5. **缓存键不含 `appVersion`**：文件名编码目标高度和渲染器版本 tag（`thumbnail-512-v1.heic`），
   命中要求文件能打开且 header 高度在 `1...512`（读 header，不解码像素）。开发期改版本号不触发
   整批重烤；改缩略图实现时手动 bump tag。高度上限而不是等号，是因为 ImageIO 不放大：源高
   < 512 时产物也 < 512。
6. **启动预热并发 4，默认开，不提供关闭开关**：ready line 之后后台跑整批；渲染不持
   `ItemStore` 主锁；按 item id 做 in-flight 去重。
7. **`state` 推导忽略缩略图**：只有缩略图的 item 仍是 `pending`；缩略图失败不改 item 状态，
   端点返回错误，胶片条回落到文件名。错误映射沿用 `prepare`：非 P3 → 422 `source_unreadable`，
   orientation ≠ 1 → 500 `prepare_failed`。
8. **不做「prepare 第一张」**：client 没有自动选中第一张的逻辑，预热它只是猜。

## 为什么不走 Core Image

- **成本在解码，不在缩放或编码**。`SourceDecoder.decode` 走 `CGImageSourceCreateImageAtIndex`
  + GPU 渲 float RGBA，与目标尺寸无关；`CIImage(contentsOf:)` 同样按全尺寸解码。用 Core Image
  等于为「把一张已经能便宜拿到的缩略图写成 HEIC」付全尺寸解码的代价。
- **这个项目已经被 Core Image 的写入路径坑过一次**：`previewAgreement` 的可复现非确定性，
  根因是 GPU `CIContext` 的 render 偶发不写 destination buffer，最后靠 `CIRender` +
  `waitUntilCompleted` 才压住。缩略图渲染器没有理由再引入一类同源的 GPU 写入路径。
- 色彩不需要 Core Image：`c1_match_v1` 是 identity（Capture One 导出就是 SDR base），所以从源
  TIFF 直接缩出来的缩略图与画布同源同色，差别只有重采样滤波器和量化。

## 证据

2026-11-09，M1 Max / macOS 27.2，三张真实 Capture One P3 导出，ImageIO 降采样解码 + HEIC 0.8：

| 源 | 尺寸 | 文件 | 缩略图 best | HEIC | 输出 |
|---|---|---:|---:|---:|---|
| R0003777-P3 | 6000×4000 | 144 MB | 138 ms | 154 KB | 768×512，10-bit，Display P3 |
| FPL05190-P3 | 8423×5599 | 283 MB | 240 ms | 123 KB | 771×512，10-bit，Display P3 |
| IMG_0543-P3 | 6960×4640 | 193 MB | 162 ms | 45 KB | 768×512，10-bit，Display P3 |

12 个不同文件的预热（warm page cache）：

| 并发 | wall | `phys_footprint` | RSS |
|---|---:|---:|---:|
| 1 | 2.26 s | 41 MB | 386 MB |
| 2 | 1.21 s | 73 MB | 682 MB |
| 4 | **0.65 s** | **137 MB** | 1264 MB |
| 8 | 0.44 s | 268 MB | 1620 MB |

- 提交内存约 **34 MB/并发**；RSS 的大头是 mmap 的源文件只读页，内核可回收。
- 1→2 是 1.87×、2→4 是 1.86×、4→8 只有 1.48×（HEIC 编码器开始排队），所以取 4。
- 20 张在 4 路下约 1.1 s；真实批次首次预热的墙钟大头是读盘与现有的 hash 扫描，不是缩略图。

## 后果

- 胶片条不再触发任何 `prepare`；一批 20 张的胶片条传输从约 440 MB 降到约 1–3 MB。
- 缩略图与 preview base 的缓存键、失效规则、产物完全分开；`PreviewBaseRenderer` 不变。
- 新增一条渲染路径（ImageIO）。它不是第二个 renderer 意义上的重复实现：判图的 base 仍只有
  `PreviewBaseRenderer` 一条路。
- client 的缩略图磁盘缓存要 bump 命名空间，否则从 base 缩出来的旧缩略图会和新缩略图混在一起。
- 缩略图是 10-bit HEIC（ImageIO 对 16-bit 源的默认），与交付 profile 的 10-bit base 无关
  （10-bit 是 profile，不是红线，ADR-0012）：它不是交付物，不进 8 项检查。
  （2026-11-10 修订：原文用了已被 ADR-0012 反转的「10-bit 红线」措辞。）

## 重审条件

- 预热墙钟仍不可接受时，先查读盘与 hash 扫描，再考虑提高并发或缓存源哈希。
- 需要更小的缩略图（弱网/更多张）时，重定高度与质量，并 bump 渲染器版本 tag。
- 若将来判图也要走「先看缩略图再加载 base」的两段式，重新考虑缩略图是否该携带更多元数据。
