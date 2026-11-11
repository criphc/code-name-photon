---
type: reference
owner: docs/ui
updated: 2026-11-10
---

# Token 与 Specimen

视觉值只有一处：`design/Sources/Tokens`。app 链接它，`docs/` 里不写数值。

## 有什么

| 组 | 收的是什么 |
|---|---|
| `PhotonSpacing` | 按角色命名的间距：底部 chrome 条、面板、胶片条、缩略图内部、连接页 notice 块 |
| `PhotonRadius` | 面板圆角、缩略图圆角（比例 + 下限） |
| `PhotonType` | 四个语义字号：chrome、缩略图占位、空态、说明小字 |
| `PhotonPalette` | 底部 chrome 材质、占位面、画布三档背景 |

## 三条规则

1. **按角色命名，不发明尺度**。现在没有 4/8/12/16 这样的级数，只有 `barHorizontal`、
   `filmstrip` 这种「用在哪」的名字。要不要改成级数未拍板。
2. **字号用语义 Text Style**，不写 px；这样 Dynamic Type 和无障碍放大自动生效。
3. **颜色用系统语义色或材质**，不写 hex。画布第三档的中性灰是唯一例外，它是物理量
   （18% 反射灰），不是主题色。

## 什么时候加一个 token

同一个值在**两个以上**地方出现，并且语义相同，才提出来。一次性出现的值留在原地，
避免 Tokens 变成一堆没人用的常量。

## 看 Specimen

`design/Sources/Specimen/SpecimenView.swift`，一个 ScrollView + 明暗两个 `#Preview`。

它没有链接进 app，所以预览要用 design 包自己的 scheme：在 Xcode 里打开
`design/Package.swift`，切到 design 的 scheme，再开 canvas。

## 还没收的

- 组件（`design/Sources/Components`）还没建：等 2–3 屏都收敛后再从界面里反向提取。
- 底部两条 chrome 的留白现在不一样（状态条和连接页状态条 / 胶片条），要不要统一未拍板。
