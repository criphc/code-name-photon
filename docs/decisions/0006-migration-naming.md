---
type: decision
owner: docs
updated: 2026-11-05
---

# ADR-0006：迁移期两个 app 的 target 名与 bundle id

- 状态：已接受（2026-11-05，用户拍板）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) §1「命名」、R6
- 影响阶段：P3（iOS）、P4（macOS）、P5（文档/命令）

## 背景

原计划只把「产品名与 bundle id」延后，迁移期保持 `com.criphc.Photon`。但新增的 macOS app
和 iOS app 会在同一台 Mac 上共存：iOS app 可以以 Designed for iPad 形态安装，而原生 macOS app
是另一个 app。两者若用同一个 bundle id，会互相覆盖/冲突，也无法在本地同时调试。

## 决策

| 平台 | target / product 名 | bundle id |
|---|---|---|
| iOS | `PhotonClient` | `com.criphc.Photon.Client` |
| macOS | `PhotonServerWrapper` | `com.criphc.Photon.ServerWrapper` |

- **产品名（显示名、App Store 名）仍然延后**；这里只固定 target 名（即 Swift 模块名）和
  bundle id。
- 旧 iOS app（`Photon` / `com.criphc.Photon`）在 P3 新工程接管后退役；设备验收必须改用新 id。
- target 名同时决定 `@main` 类型名、scheme 名和日志前缀；P3/P4 一并改掉，不做兼容别名。

## 后果

- 旧的 `make install-device` / `xcrun devicectl ... com.criphc.Photon` 命令、`ipad/README.md`
  的设备步骤、`Info.plist` 的网络用途文案都要在 P3 更新。
- 两个 app 在 Mac 上可同时安装，互不覆盖。
- 将来确定产品名时，只需改显示名/App Store 配置，不改模块边界。

## 备选与取舍

- **两个都叫 `Photon`、都 `com.criphc.Photon`**：字面符合原计划，但与 Designed-for-iPad 的
  iOS app 在 Mac 上同 id 冲突；拒绝。
- **`PhotonIOS` / `PhotonMac`**：角色表达不如 `Client` / `ServerWrapper` 清楚；已由用户选择替代。

## 验证

P3 的 iOS build + 设备安装/启动使用新 bundle id；P4 的 macOS build 产出
`PhotonServerWrapper.app`。
