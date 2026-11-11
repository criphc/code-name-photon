---
type: decision
owner: docs
updated: 2026-11-05
---

# ADR-0005：判图能力按显示器定义，不按平台

- 状态：已接受（2026-11-05，P0）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) §0、§1、R6、R11
- 影响阶段：P3（iOS）、P4（macOS）

## 背景

stage 1 把「判图」绑定在 iPad XDR 上；Mac 的 Studio Display 是 SDR-only，无法验证 HDR。但
「能不能判图」的真正条件是**显示器有没有 EDR/足够 headroom**，不是设备是 iPad 还是 Mac：

- iPad Pro（Liquid Retina XDR）是主验收面；
- 接了外接 HDR 显示器的 Mac，用 iOS app（Mac Designed for iPad）也可以判图；
- 内置 Studio Display（SDR）不行。

## 决策

- 判图能力按**显示器能力**定义；iPad XDR 仍是主验收面。
- iOS app：一个 target，`TARGETED_DEVICE_FAMILY = 1,2`（iPhone + iPad），部署目标 iOS 27；
  iPad 优先设计，iPhone 与 Mac（Designed for iPad）「能跑就行」，不为此加平台分支。
- macOS app（`PhotonServerWrapper`）不提供判图 UI；Mac 判图走 iOS app + 外接 HDR 显示器。
- 判断 HDR 仍只用 ImageIO（`tools/verify-heic`）；display headroom 只影响预览呈现，不影响交付
  契约。
- 主验收协议不变：iPad XDR 上的 Photos + Safari 双端验收；外接 HDR 的 Mac 是补充面，不替代。

## 后果

- iOS UI 不能假设 iPad 尺寸；但设计优先级明确，iPhone 只保证不崩、可用。
- Mac 上的两种 app 并存：原生 macOS 壳（服务管理）+ Designed for iPad 的判图 app（[ADR-0006](0006-migration-naming.md)）。
- 不再出现「Mac 端不能判图」的硬编码；是否判图由显示器和 app 形态决定。

## 备选与取舍

- **只支持 iPad**：会放弃 Mac + HDR 显示器的补充判图面；拒绝。
- **给 macOS app 加判图 UI**：与「GUI 只套壳 appctl」冲突，且要重做 Metal/EDR 路径；本阶段拒绝。
- **按平台做两个判图前端**：重复 UI 与 shader，违反一份数学原则；拒绝。

## 验证

P3 的 iOS build + iPad XDR 设备验收不变；Mac（Designed for iPad）在接 HDR 显示器时做一次补充
smoke，不阻塞 P3。
