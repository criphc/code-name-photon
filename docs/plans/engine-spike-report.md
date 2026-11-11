---
type: record
owner: docs
updated: 2026-11-09
---

# Engine spike：Core Image HEIC writer

*2026-11-09 初测。输入是失败 recipe 的 `sdr.tif`（16-bit P3）和 `hdr.tif`（32-bit float 线性 P3），
即 `appctl deliver` 当时交给外部 encoder 的同一对文件。*

## 结论

- **Path A 可行**：`CIContext.writeHEIF10Representation` + `.hdrGainMapImage` + `.hdrGainMapAsRGB`
  写出了 10-bit base、半分辨率 RGB/mono map、ISO aux；`contentHeadroom` 2.175782 与 authored peak 一致。
- **Path B 的 raw-aux 路线在 macOS 27 上失败**：`CGImageDestinationAddAuxiliaryDataInfo` +
  `kCGImageAuxiliaryDataTypeISOGainMap` + raw RGB8 的 `CGImageDestinationFinalize` 返回 false；
  换 `PixelFormat`（EXIF 2 / fourCC）没有改变。新的 `kCGImageDestinationEncodeRequest` surface 是
  唯一剩余路线，未测。
- **metadata 可以简单 rewrap**：`CGImageDestinationCopyImageSource` + 源 TIFF 的 `CGImageMetadata`
  保留了 gain map 和 10-bit base，并写入了 EXIF（相机/镜头/曝光等）；orientation 1；GPS 源里没有，
  代码路径会带。
- **半分辨率 map 的 `previewAgreement` 需要 profile 阈值**：mean/p99 都过，`fractionAbove5`
  6.63%（10-bit）/ 8.32%（8-bit）超过当前 5% gate；全分辨率 map 是 1.25%。
- **gain map 计算是性能风险**：debug 脚本 21 s（逐像素 Swift）；生产要用 CIKernel/vImage/Accelerate，
  目标 < 2 s。encode 本身 0.33 s。

## 结果表

| profile | base | map | headroom | preview mean | p95 | p99 | >5 % |
|---|---|---|---|---|---|---|---|
| Path A 10-bit | 10 | half RGB | 2.175782 | 1.8425 | 5.05 | 5.26 | 6.63 |
| Path A 8-bit | 8 | half RGB | 2.175782 | 2.1665 | 5.14 | 5.79 | 8.32 |
| Path A 10-bit | 10 | half mono | 2.175782 | 1.8426 | 5.05 | 5.27 | 6.61 |
| 外部工具（full-res RGB） | 8 | full RGB | 2.175782 | 1.1689 | 3.30 | 5.28 | 1.25 |

Path A 的文件：10-bit 6.4 MB，8-bit 更小；aux data description 的 `PixelFormat` 是 `420f`
（RGB）或 `L008`（mono），宽高 3000×2000（half-res）。

## Path B

- `CGImageDestinationAddAuxiliaryDataInfo` 的 raw RGB8 + `kCGImageAuxiliaryDataTypeISOGainMap`
  在 `CGImageDestinationFinalize` 失败；`kCGImagePropertyPixelFormat` 试过 EXIF 2 和 fourCC，均失败。
- 新的 `kCGImageDestinationEncodeRequest` / `kCGImageDestinationEncodeToISOGainmap` /
  `kCGImageDestinationEncodeGainMapSubsampleFactor` 是剩余路线；文档稀疏，需要单独 spike。
- 建议：第一次 cutover 用 Path A + rewrap；Path B 只在 Path A 的 metadata/质量不够时再查。

## Metadata rewrap

- `CGImageDestinationCopyImageSource(dest, pathA, [kCGImageDestinationMetadata: sourceTIFFMetadata])`
  → EXIF 齐全、ISO aux 保留、HDR decode 10-bit、headroom 2.175782、orientation 1。
- 源 TIFF 没有 GPS；有 GPS 的源会走同一条路径。
- 完整 `CGImageMetadata` 还带 XMP/IPTC/Photoshop tag；如果只要 EXIF/TIFF/GPS/orientation，需要按
  namespace 过滤。

## 待定

1. 半分辨率 `previewAgreement` 的 `fractionAbove5` 阈值：half-res（和 8-bit）用 10%，mean/p99 不变？
2. “同时 deliver”：两个 HDR 文件（`-hdr8` / `-hdr10`）加 per-profile report，还是一次只选一个 profile？
3. Apple mono：v2 的交付 profile，还是只做 engine 能力？当前 `container` 检查能过（ISO aux + `tmap`），
   但 gate 语义需要 profile 规则。
4. metadata 过滤：只留 EXIF/TIFF/GPS/orientation，丢掉 XMP/IPTC/Photoshop？
5. Path B：现在查新的 encode-request surface，还是先走 Path A + rewrap？
