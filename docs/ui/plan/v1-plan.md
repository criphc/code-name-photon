---
type: record
owner: docs
updated: 2026-11-10
---

# v1 执行计划：先做对一屏，再反向固化规格

*2026-11-06 启动 · 2026-11-08 收尾：iPad UI 的 v1 结束，规格已从实现反向固化到
[../spec/](../spec/00-index.md)。macOS GUI 推迟到 v2 之后。*

## 定位

迁移已结束：包结构、wire 契约、交付门禁、parity 不再改动。v1 是第一个产品化迭代，**只做 UI**；engine / wire / 交付行为冻结。

- v1 范围 = 「design + UI 规格」+「iPad UI 重做」。
- **核心方法不是先写规格书**，而是：一条端到端竖切片（手调）→ 提取重复项 → 逐屏铺开 → 文档反向固化。
- `docs/ui/` 的第一版是「做完 2–3 屏后总结出来的决策记录」，不是事前规格书；规格书会持续产生过时内容。
- 不在 v1：macOS GUI、队列/批量、EXIF rewrap、verify 性能、配对/分发/签名。

## 目标形态

用户 2026-11-06 的 iPad 布局草稿是 v1 的设计输入（原文与映射表见 [v1-ui-draft.md](v1-ui-draft.md)）。当前实现：

- **三栏**：`NavigationSplitView(sidebar:detail:)` + detail 的 `.inspector`（宽度 `inspectorColumnWidth`）；横屏为基准。
- 左栏 = 连接页（已连接状态 + host/port/token 表单 + 状态条）；目录/源树与 `⚙` 设置 sheet 未做。
- 中间 = 工具栏 + 画布（背景 3 档）+ 状态条 + 胶片条。
- 右栏 = 直方图（横轴上限随 cap）+ HDR 操作（3 个滑条 + cap stops picker）。
- 窗口工具栏：Compare（三段：原样 / SDR 基座 / 假色，交互见「开放决策」）、调整栏开关、Submit（主操作，`paperplane` + prominent 样式）。假色不再单独占位。
- 与草稿的差异都记在「开放决策」，未拍板前不动对应部分。

## 设计原则（硬规则）

1. **系统控件优先**。非必要不自制按钮 / 工具栏；OS 27 标准控件自带材质、动效、指针/触摸反馈，自建容易做出「网页味」。
2. **一次只改一个组件**，小步迭代，避免做无用功。
3. **一次给多个方案**：同一屏给 2–3 个实现，放在 `#Preview` 里让用户比较后收敛，不要替用户拍板视觉。
4. **单一 app target + 自适应布局**：当前仍是 `apps/ios`（device family 1,2；Mac 走 Designed for iPad）。
5. **`#Preview` + 用户实机验收**：改动留 `#Preview` 并指出文件/行号；用户随时在 Xcode canvas 看、阶段性上 iPad。没有用户确认不算完成；agent 不启动模拟器、不截图。
6. **三件套**：
   - `#Preview` 多状态变体；Xcode 27 preview 可改尺寸，用来验三种宽度；
   - snapshot testing 做像素基线（首屏收敛后建基线）；
   - UI 测试用 `accessibilityIdentifier`，不做文案匹配。
7. **UI 只读 model 面**：`SessionModel` / `JudgeModel` 是唯一状态来源；view-local state 只放不可测的视觉状态。

## design/ 与 docs/ui 的分工

**文档描述「意图」，代码持有「数值」。**

```text
design/Sources/Tokens/       # 唯一真值：数值只在这里（已建）
design/Sources/Components/   # 只放系统不提供的产品复合视图（先不建）
design/Sources/Specimen/     # token 画廊：一个 ScrollView + 两个 #Preview（已建）
docs/ui/                     # 只写决策、约束、状态、验收条件；禁止 hex / px / 字号数值
```

### Tokens 三条规则

- **字号不做 px token**：用语义 Text Style（`.title2`、`.body`、`.caption`），自动响应 Dynamic Type、无障碍放大与 Liquid Glass 缩放。
- **颜色不用 hex 常量**：用 asset catalog color set 或系统语义色；Liquid Glass 的可调 tint、深色/增强对比度变体不能用硬编码色表达。
- **数量强制收敛**：spacing 5 档、radius 3 档、color role ≤8。非设计师 + agent 很容易产出 60 个 token，第三屏就没人遵守。

### Components 先不建

只有「系统不会给你的东西」才进 Components：recipe 行、前后对比滑块、缩略图网格单元、参数滑杆组。判断标准：**长得像系统控件，就用系统控件。**

### Specimen 是关键件

一个可滚动查看「所有 token、所有组件、所有状态」的可运行页面（先做一个大 `#Preview`，必要时再包 Debug 入口）。它同时是 agent 的验收台（改 token 立刻看到全局影响）和用户的学习工具。

## 工作顺序

### 已完成（2026-11-07 · 11-08）

1. 横屏三栏骨架；三栏开合时画布做缩放动画（列宽本身由框架控制，见 `docs/ui/reference/swiftui-layout.md`）。
2. 连接页接 `SessionModel`：字段绑定、Connect、phase、notice alert、Use Last Server（连接成功后才出现）。
3. 胶片条接 `SessionModel.items`：选中走 `judge.select`，状态点来自 `item.state` / `hasRecipe` / posting；拖顶部改高度。
4. 调整栏接 `JudgeModel.draft`：三个参数写回、双击复位、滚轮数值输入；cap 用 stops picker（0.5–3），无滑条。
5. 画布接真实图像：Metal/EDR 跑 ClientKit 的 MSL（compute → present），fit-to-screen；Compare 走 `JudgeRenderMode.compare`。
6. 直方图接真实数据：按草稿 gain 分桶，横轴上限随 cap（SDR 线性 + 0…log2(cap) stops），SDR 白线，150ms 防抖。
7. 工具栏接模型：Submit（prominent，`paperplane`）、三段式 Compare、调整栏开关；judge 错误与提交结果用 alert。
8. Compare 交互：轻点 A↔B、按住预览另一段、A 上双击进假色、假色里任何操作回原样、拖出取消。按下判定改成「长按手势给按下、拖拽手势给释放」，原因和实测见 [gestures.md](../reference/gestures.md)。
9. 画布背景 3 档：长按画布 1 秒切下一档，前两档跟系统深浅色（黑/白、深灰/浅灰），第三档固定中性灰；档位记在 `@AppStorage`。
10. 状态条：画布与胶片条之间，`.safeAreaBar(edge: .bottom)` + `.bar` 材质，和胶片条连成一块 chrome；左边是预览尺寸/色域/位深，右边是显示器 headroom 的 stops。`displayHeadroom` 的 1 秒轮询一并补上——之前 `updateHeadroom` 全仓库无人调用，画布 uniform 里恒为 1。
11. 胶片条缩略图：客户端把 preview base 缩到高度 ≤512px，内存 + 磁盘两级缓存，串行后台补齐；格子按源图比例，没有缩略图时用文件名占位；空批次显示一条中性文案。（2026-11-09 被 [ADR-0013](../../decisions/0013-thumbnail-api.md) 取代：缩略图改走服务端 `GET /api/items/{id}/thumbnail`）
12. 状态条空态：没有图像时左边是 `No image`、加载中是 `Loading…`，右边 headroom 显示占位 `@ — Stops`（那时没有 EDR 内容，读不出有意义的当前值）。
13. 编辑历史：一条全局时间线，编辑和「切换图片」都算一步，撤销能跨图片回退（Capture One 的行为）。一次连续编辑（一次拖动、一次滚轮会话、一次双击复位、一次粘贴）= 一步。redo 只在撤销过之后出现。
14. 复制/粘贴调整：应用内剪贴板，只存 4 个 hdr 参数；和「清缩略图缓存」一起收进工具栏溢出菜单。提交成功的 alert 带上 item 名和 renderKey 前 8 位。
15. 真实逻辑的单测：`EditHistory` / `CanvasStatus` 挪进 `ClientModel`（无视图依赖），用 Swift Testing 在 Mac 上跑——跨图撤销、严格时间线、redo 失效、headroom 取整、位深解析。顺手抓到两个 bug：headroom 在 `Float` 里算丢了精度；第一次选中被记成一步死撤销。
16. 多宽度 `#Preview`：`#Preview(traits: .fixedLayout(...))` + `#if DEBUG` 的假 transport，铺出未连接 / 已连接有素材 / 空批次 / 长文件名 + 大字号。跑第一遍就抓到紧凑宽度下 inspector 自动弹 sheet。
17. 紧凑宽度：`preferredCompactColumn` 让连上后直接落在判图页；调整栏改走底部内嵌面板（不再弹全屏 sheet），展开时胶片条让位、直方图压矮，画布从 249 pt 涨到 488 pt。面板出现的动画做不出来，v1 不加 —— 试过什么、为什么不行见 [swiftui-layout.md](../reference/swiftui-layout.md)。

### 收尾（v1 UI 结束）

v1 的 iPad UI 到此为止。下面三条是**明确不做**，不是待办：

1. snapshot 像素基线 + UI 测试 —— identifier 已经铺好，等真有回归需求再建。
2. `design/Sources/Components` —— 组件等第二块屏之后再从界面里反向提取。
3. 调整栏出现的动画 —— 三条路都试过，做不出来，见 [swiftui-layout.md](../reference/swiftui-layout.md)。

### 之后

- 性能与内存：base 纹理上传在主线程、`JudgeModel.reviews` 是会话级无上限缓存。
- 这两条是 client 侧遗留，v2 未覆盖，未排期。

## 开放决策

### 已定（2026-11-07 · 11-08）

1. **左栏层级**：v1 单批次，不改 server/wire；左栏暂时就是连接页，目录树留给将来。
2. **检视器操作栈**：1 个 HDR 操作 + 3 个滑条 + cap stops picker（0.5–3）；recipe 不扩（cap 仍在 schema 1…8 内）。
3. **对比**：三段式按钮，假色并入其中：A 原样 / B SDR 基座 / C 假色。轻点 A↔B，按住预览松手会落到的另一段，A 上双击进 C，C 里轻点/长按/双击/拖出都回 A（随后冷却）；拖出取消。按下必须即时，判定方式见 [gestures.md](../reference/gestures.md)。
4. **画布**：fit-to-screen，不做 zoom/pan。
5. **缩略图**：客户端拿 preview base 缩（不加 server 端点，wire 冻结）；位图高度 ≤512px，格子按源图比例，内存 + 磁盘缓存。（2026-11-09 被 [ADR-0013](../../decisions/0013-thumbnail-api.md) 取代：缩略图改走服务端 `GET /api/items/{id}/thumbnail`）
6. **judge 反馈**：错误与提交结果都用 `.alert`，不进状态条；提交成功的正文先是 `item 名 · renderKey 前 8 位`，再接那句「recipe sent to the Mac」。
7. **画布背景**：3 档，长按画布 1 秒切下一档，一次长按只切一档、按住不放不连播；前两档跟系统深浅色，第三档固定中性灰；档位跨启动记住。
8. **状态条**：画布与胶片条之间，只放只读信息（预览尺寸/色域/位深 + 显示器 headroom）。headroom 显示成 `@ 2.0 Stops`（`floor` 到一位小数），和 cap 的 stops 域直接对照；没有图像时显示占位 `@ — Stops`。
9. **撤销/重做**：一条全局时间线，编辑和切换图片都算一步；一次连续编辑合并成一步；历史是 view-local 的（后改为 ClientModel 包内类型，见工作顺序 15 与 [ui/reference/models.md](../reference/models.md)），按 item 不可达时清空。redo 只在撤销过之后出现。
10. **复制/粘贴**：应用内剪贴板，范围就是 4 个 hdr 参数（`base`/`encoder`/`versions` 是每个 item 自己的，不能跨 item 复制）；入口在工具栏溢出菜单；粘贴是一步可撤销的编辑。
11. **参数复位**：双击**滚轮**复位，不是双击滑条 —— 滑块的触摸被原生控件吞掉，外层 SwiftUI 手势收不到（见 [gestures.md](../reference/gestures.md)）。
12. **紧凑宽度布局**：调整栏走底部内嵌面板而不是 sheet（sheet 会盖住画布），展开时胶片条收起；面板出现**不加动画**，瞬时切换。细节见 [swiftui-layout.md](../reference/swiftui-layout.md)。

### 待定（留给 v2 之后）

1. 间距要不要改成级数（现在按角色命名），以及底部两条 chrome 的留白要不要统一。
2. Specimen 要不要长成组件画廊；产品名 / bundle id。

## 非目标 / 已知遗留

- `previewAgreement` known issue：已修复（2026-11-09），调查记录见 [preview-agreement-investigation.md](../../plans/preview-agreement-investigation.md)。
- advertised headroom 的 5% 匹配：已从 warning 回收为 gate（[ADR-0012](../../decisions/0012-core-image-encoder.md) 取代 ADR-0011）。
- 批量、EXIF rewrap、verify 性能：v2 已做（[v2-plan.md](../../plans/v2-plan.md)）。
- macOS GUI 的 parent-death watchdog、进程组 kill、动态端口、sandbox/entitlements 另立阶段。
- 队列状态、iPad 缓存/草稿、TLS/Bonjour、分发/签名：未排期。
