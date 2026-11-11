# M3 近三个 commit 代码审阅（仅代码问题）— 2026-11-03

**范围**：`03ca0d8`（`feat(ipad): M3 iPad EDR judging client`）引入的 `ipad/` 代码：`ClientKit`、`Photon`（AppModel / SwiftUI / Metal·EDR / MSL）、`PhotonTests`、`Makefile` 与 Xcode 工程。`5011817` / `115de57` 的文档错误已在本 session 修正（commit `4002ec3`），不计入本报告。报告行号基准 = `4002ec3`（代码与 `03ca0d8` 相同）。

**验证方式**：全量静态阅读；在 macOS 上复跑 `cd app && make test`、`cd ipad && make test-macos`（含 parity）和 `make build-ios`。本机无 iOS Simulator runtime，App 未在设备上跑过——所有 SwiftUI/Metal 运行时结论以代码推理为准，已逐条标注「静态判断」。

**分级**：P0 1 · P1 1 · P2 12 · P3 见文末。

---

## P0

### P0-1 缓存重选显示上一张图的像素（base 纹理永不重传）

**位置**：`ipad/Photon/UI/AppModel.swift:138`（`imageVersion` 唯一计数器）、`:401-406`（缓存命中分支）、`:458`（唯一自增点）；`ipad/Photon/Render/EDRCanvas.swift:96`、`:120-124`（`guard version != imageVersion`）；`RootView.swift:44-53`、`JudgeView.swift:89-105`（JudgeView / EDRCanvas 在整个过程中保持同一身份）。

**复现（三次点击，无网络）**：选 A（未缓存 → `loadReview` 解码成功 → `imageVersion = 1`，纹理 A）→ 选 B（→ 纹理 B，`imageVersion = 2`）→ 再选 A（`reviews[A]` 命中 → `review = A`，但**没有** bump `imageVersion`）。`EDRCanvas.updateUIView` 调 `coordinator.apply(image: A, version: 2)`，被 `guard version != imageVersion` 直接 return，`setBase` 永不执行。屏幕上：A 的标题/草稿/滑杆/headroom + **B 的像素**；按 Done 时 `buildRecipe` 用 `current.item.id`（A）做 `source.sha256` 校验（`AppModel.swift:583-593`），所以 POST 的身份是对的——即"看着 B 判图、按 A 提交"，视觉判断与交付 recipe 错位且不容易察觉。

**同源第二表现**：`loadReview` 开头 `review = nil`（`:427-430`）但版本不变；`isShowingJudge = review != nil || phase == .loading`（`:196`），loading 期间 JudgeView 仍在层级里，旧纹理继续被绘制在 loading 卡片后面，`setBase(nil)` 不可达。

**影响**：违反 §1.2 "canvas samples the PNG the iPad received"；任何"回到看过的图"的判图都是错的。`docs/06 §10` 的 "item switching reuses the in-session cache" 只对状态成立，对像素不成立；设备验收从未做过 A→B→A，因此没暴露。

**修复**：把上传门控从"只在成功解码时自增的计数器"改成显式身份：给 `EDRCanvas` 传 `(itemID, imageVersion)`，`Coordinator.apply` 比较该元组并在 `nil` 时清空纹理；或至少在缓存命中分支与 `review = nil` 之后 bump 版本。并加回归测试（见 P2-10）。

---

## P1

### P1-1 无 dirty/baseline：POST 成功后继续改滑杆，"recipe sent" 横幅与旧 renderKey 仍在

**位置**：`ipad/Photon/UI/AppModel.swift:151-154`（`postedMessage` / `lastRenderKey`）、`:504-513`（`mutateDraft` 只把 `.posted` 降回 `.judging`）、`:595-598`（`dismissPosted`）；`ipad/Photon/UI/JudgeView.swift:40-46`（`postedMessage != nil` 就渲染绿色成功横幅）；`ipad/ClientKit/Judging/RecipeDraft.swift:46-58`（`isDirty` / `resetToDefaults` 是死代码，grep 无调用点）；`docs/06 §4.4:102` 要求 editor state 含 `baseline` / `isDirty`。

**影响**：post → 再调 lift/start → UI 仍显示 "recipe sent to the Mac; M4 writes the HEIC" 和旧 `renderKey`，用户会以为新 look 已交付（服务端仍是旧 recipe 的 `recipe_received`）。

**修复**：按 item 记录产生 `lastRenderKey` 的 `postedSnapshot`；`isDirty = draft != snapshot`；`mutateDraft` 在变脏时清 `postedMessage` / `lastRenderKey` 并显示中性的 "edited — not sent"；把 `RecipeDraft.isDirty`/`resetToDefaults` 接到 UI 或删除。

---

## P2

### P2-1 `BasePNGError` 对用户不可读

`ipad/ClientKit/Base/BasePNG.swift:33-49` 只有 `Error, Equatable, Sendable`，没有 `LocalizedError`；`AppModel.message(for:)`（`:785-793`）只特判 `ClientError` / `PhotonError`，其余落回 `(error as NSError).localizedDescription`。因此校验本来要覆盖的失败——22 MB 下载被截断（`hashMismatch`，`BasePNG.swift:127-129`）、8-bit/sRGB、带 alpha、尺寸不符——都显示成 `The operation couldn't be completed. (Photon.BasePNGError error N.)`，而不是 `docs/06 §4.4` 要求的可操作文案。**修复**：每 case 一句具体文案并 conform `LocalizedError`，同时在 `AppModel.message(for:)` 加 `BasePNGError` 分支。

### P2-2 会话图像缓存无上界，且 `disconnect()` 不清

`AppModel.swift:127-136`（`Review.image` 藏在 `reviews` 字典）、`:449-458`（写入）、`:315-333`（`disconnect` 清 `review`/`items` 但**不清 `reviews`**）、`:360-378`（离开 batch 的 item 仍保留）。一张 2560×1707 的 `LinearImage` = 66.7 MiB；6 张验收批次 ≈ 400 MiB，长会话/大批次线性增长，有 jetsam 风险。**修复**：缓存按 item 保留 `meta` + `draft`，图像只留当前 1–2 张 LRU（或 `NSCache`），`disconnect()` 清空；与 P0-1 的纹理门控一起设计。

### P2-3 base 解码 + 线性化 + 66.7 MiB 纹理上传都在主线程

`AppModel` 是 `@MainActor`，`loadReview` 在 `:446` 同步调 `BasePNG.load`：CryptoKit SHA-256（22.1 MB）+ ImageIO 16-bit PNG decode + float32 `CGContext` draw，随后 `EDRCanvas.updateUIView` → `MetalRenderer.setBase` → `texture.replace`（66.7 MiB）也在主线程（`MetalRenderer.swift:156-186`）。每次冷选有数百 ms 的主线程停顿，loading 指示冻结、交互失效。**修复**：`Task.detached { try BasePNG.load(...) }`（`LinearImage` 是 Sendable，函数是纯静态），保留 `generation` 检查；上传也挪离主线程或至少只让上传在 main。**静态判断 + 本机 probe 测得过 240 ms 解码/线性化**（同机 iPad 会不同，量级参考）。

### P2-4 切换 item 不取消前一请求

`select()` 只 bump `loadGeneration`（`:384-408`），完成回调靠 generation 丢弃状态；但启动的 `Task` 从不保存/取消（`LibraryView.swift:55`、`ConnectionView.swift:73`），`disconnect()` 也只 bump generation（`:315-333`）。传输层其实支持取消（`PhotonClient.swift:168,176-182,188`）。快速切换会让多个 22 MB `GET preview` 和 Mac 端 cold `prepare` 并发，下载完的 22 MB `Data` 再被丢弃。**修复**：保存 `loadTask`，在 `select`/`disconnect` 先 `cancel()`；`handleError` 加 `CancellationError` 静默分支（否则取消会走 NSError 文案）。

### P2-5 `retry()` 先清 `failureStep` 再 await：双击 Retry 可在 POST 在飞时 reload base

`AppModel.swift:603-625`：`retry()` 捕获 step 后立即 `failureStep = nil` 再 await。双击失败 POST 的 Retry：task1 进入 `postRecipe`（`phase = .posting`），task2 见 `failureStep == nil` 走 `.none` 分支 → 因为 `client != nil && selectedItemID != nil` 而 `reload(itemID:)`，把 `review` 清掉、phase 改 `.loading`，而 POST 还在飞；POST 返回后在已被丢弃的 review 上设置 `postedMessage`/`phase = .posted`。**修复**：`isRetrying` 守卫（`defer` 清除）；`failureStep` 在进入步骤后再清；`.none` 分支在 `phase == .posting/.loading` 时拒绝 reload。

### P2-6 409 自动 re-judge 的 Task 无 generation 守卫，可覆盖用户之后的选择

`AppModel.swift:647-673`（`Task { await rejudgeAfterSourceChange() }`）、`:730-765`（先 `await refreshItems()`，再 `reload(itemID: target.id)`）、`:412-419`（`reload` 无条件改选择）。用户在 refresh 期间选别的图，re-judge 完成后会把 `selectedItemID`/`review`/`phase` 覆盖回重导出的 item，静默丢掉用户选择。**修复**：进入任务前捕获 `loadGeneration`，`refreshItems` 返回后若已变化则放弃并清 notice；或走带守卫的 `select`。

### P2-7 renderer 失败静默黑屏，Done 仍可用

`MetalRenderer.swift:67-128,324-328`：MSL 缺失、runtime 编译失败、pipeline 创建失败都只 `print("[Photon] MetalRenderer unavailable: …")` 一次，状态保持 nil；`EDRCanvas.swift:36-59` 没有把失败传给 SwiftUI；`AppModel.canPost`（`:188`）不依赖 renderer。结果是黑画布 + 可拖滑杆 + 可按 Done，成功横幅照常出现。**修复**：`EDRCanvas` 加 `onRendererUnavailable` 回调，转成 `.error` notice，renderer 未就绪时禁用 Done。

### P2-8 契约字段未校验 / 未知 `ItemState` 让整列表解码失败

`ipad/ClientKit/Wire/APIModels.swift:99-100` 定义 `PreviewMetadata.currentSchema` 但从未比较（同 `:165,174`），未知 metadata schema 会被静默接受，直到 Done 才在 `Recipe.validate()` 报错；`WireModelTests.swift:168-171` 把"未知 state 必须报错"钉死，而 M4 计划明确要加 `rendered` / `encoded` / `verified`（`docs/01 §2.1`、server `APIModels.swift:4-5`），届时 M3 客户端会整批列表解码失败。**修复**：`loadReview` 里校验 `meta.schema`；对未知 `ItemState` 做前向兼容（跳过/标记）或加 API 版本门。

### P2-9 host 校验可被 typo 改写实际目标

`PhotonClient.swift:59-96` 只拒绝空白与 `/`，但 `URL(string:)` 接受更多：probe 得 `"192.168.1.5?x"` → host 解析为 `192.168.1.5` 且 **port 丢失为 80**、`"#x"` 同理、`"user@host"` 变成 userinfo、`"host%2F24"` 解出带 `/` 的 host；带 scope 的 IPv6（`fe80::1%en0`）被拒但只报 "cannot build a URL"。**修复**：用 `URLComponents` 构造，断言 `components.host == host && components.port == port`，显式拒绝 `? # @ %` 并给出明确文案。

### P2-10 App/UI/Render 层零自动化测试

`ipad/Photon.xcodeproj/project.xcproj:14-31`：`PhotonTests` 只编译 `ClientKit`、`../contract/Sources/PhotonContract` 与 `PhotonTests` 自己；`Photon/`（AppModel 794 行 + UI + Renderer）只属 app target，`grep -rln "AppModel\|EDRCanvas\|MetalRenderer" ipad/PhotonTests/` 为空。P0-1/P1-1/P2-5/P2-6 都发生在这层。**修复**：`AppModel` 只 import Foundation/Observation，可编进 macOS 测试 target（给 `PhotonClient` 加 protocol seam，用现成 `StubHTTPServer`），补：A→B→A 重选、posted→编辑清横幅、Retry 双击、409 期间用户改选、409 序列；renderer 可用 parity harness 的 Mac GPU 模式测。

### P2-11 404 的解释会被自动 refresh 抹掉

`AppModel.swift:676-692` 在 `not_found` 时设 `.error` + notice 并立刻 `Task { await refreshItems() }`；refresh 成功把 phase 推回 `.connected`（`:338-358`），此时 `RootView.swift:55-116` 的 guidance 只在 `.error`/`.unconfigured` 下显示 `notice?.message`，而 `NoticeBanner` 只在 `JudgeView.swift:31-39` 渲染。用户最终停在 "Pick a photo"，没有任何解释。**修复**：把 notice banner 放到 split-view detail 的全局位置（或 guidance 内），只在用户关闭或成功选中新 item 后清除。

### P2-12 重连失败后旧 batch 仍可点，点击静默无反应

`AppModel.swift:302-312`：`connect()` 失败时清 `review`/选择但**不清 `items`**（只有 401 分支 `:634-644` 清）；`LibraryView.swift:53-66` 的 row 在 `!isConnected` 时仍可点；`loadReview` 的 `guard let client else { phase = .unconfigured; return }`（`:422-426`）不设 notice。表现：Mac 消失 → Reconnect 失败 → 侧栏仍是旧列表，行高亮但什么都不发生。**修复**：失败时清 `items`/`reviews`，或断开时禁用列表并显示 banner；`client == nil` 时 `select` 给出 notice。

### P2-13（测试代码）parity gate 会静默跳过，且 trial base 是旧产物

- `ipad/PhotonTests/ShaderParityTests.swift:170-173`：trial-base 用例在 `TestSupport.loadWorkBasePNG()` 为空时 `XCTSkip`；`TestSupport.swift:36-41` 只认 gitignored 的 `work/m21-final/preview-base.png` 或 `$PHOTON_M3_BASE_PNG`。实测 `PHOTON_M3_BASE_PNG=/nonexistent` → `Executed 5 tests, with 1 test skipped and 0 failures`，**exit 0**；`TestSupport.swift:138` 的 "no Metal device" 也会让 5/5 skip 而全绿。这违反 `AGENT.md` 「绿但没跑不算证据」；证据运行没有断言 skipped=0。
- 更隐蔽：该 trial base 是 **P1-2 修复前**的产物（`work/m21-final/preview-base.png`，sha `560889eb…`，22,111,140 B），不是 M3 server 实际下发的 base（`work/m3/server/bd486ca6…/preview-base.png`，sha `2da032fa…`，22,112,102 B）。两份 PNG 有 4,360,957/4,369,920 像素不同（最大原始差 10,838/65,535）；`1.43e-06` 的 parity 结论仍成立，但测的是被取代的 base。
- **修复**：`make parity` 证据目标断言 `skipped == 0`；trial base 改指 M3 实际下发文件（或用 `$PHOTON_M3_BASE_PNG` 注入并在 CI 必填）；无 Metal 时让 gate 失败而不是 skip。

---

## P3（择要，按文件）

1. **主线程 runtime 编译 shader**：`MetalRenderer.swift:59-63` 在 `makeUIView`（main）里 `device.makeLibrary(source:)`，第一次进判图可能有数十 ms 停顿；`EDRCanvas.swift:45` 的 `preferredFramesPerSecond = 60` 在 `isPaused = true` 下无意义。
2. **compare/overlay 交互**：overlay 打开时按住 compare 无可见变化（`AppModel.swift:200-205` 的优先级为 overlay 胜），按钮却显示按下（`JudgeView.swift:266-267`）；overlay 无颜色图例（`JudgeView.swift:179-190`），而 2.5 cap 下"超出显示 headroom"band 在文档设备上不可观测。
3. **可达性/布局**：hold-to-compare 只是空 action 的 `Button` + `isPressed`（`JudgeView.swift:264`），VoiceOver 激活不会进入 compare；固定 176×40 槽位（`:289`）在超大字号会裁切，控制行最小宽约 430 pt 会溢出 ~320 pt 的 compact Stage Manager 窗口。
4. **compact 宽度导航风险**：`JudgeView.swift:26` 隐藏 nav bar，`RootView.swift:16-21` 没有 `NavigationStack`；split view 折叠时返回侧栏的唯一按钮就在该 nav bar 里（**静态判断，未在设备验证**）。
5. **token 明文存 `UserDefaults`**：`AppModel.swift:77-83,776-781`；与 M3 信任局域网的决定一致，但凭据会进 app 容器备份，建议 Keychain 或至少在文档注明。
6. **滑杆范围二次硬编码**：`RecipeDraft.swift:20-22` 与 `PhotonContract.Recipe.validate`（`Recipe.swift:254-257`）各写一份 `0…1 / 0…4 / 0.001…1`，应把 range 从 contract 导出共用。
7. **progress 可倒退**：`AppModel.swift:438-443` 每个 URLSession 进度回调都 `Task { @MainActor … }`，调度可乱序，`loadProgress` 可能回退；建议节流或 `max(loadProgress, progress)`。
8. **错误映射小问题**：`ClientError.swift:134-150` 的 408/429 分支对本 server 不可达；`PhotonClient.swift:211-216` 把请求编码失败归为 `.decoding`；`.timedOut` 统一映射 `.network`（对 `prepare` 60 s 超时的提示会误导为"检查 host/Wi-Fi"）。
9. **Display-P3 检测依赖 ImageIO 字符串**：`BasePNG.swift:144-147` 比较 `CGImage.colorSpace?.name`，`copyICCData() != nil` 不能证明 PNG 真的带 ICC chunk（命名色彩空间也会返回非 nil）；建议按 ICC 数据内容判断。
10. **分配前无尺寸上限**：`BasePNG.swift:171-179,190` 直接用（hash 校验过的）metadata 尺寸分配 `w*h*4` float；对可信 server 无害，但损坏/恶意对端是 OOM crash 而非抛错。
11. **死代码/未接线 API**：`RecipeDraft.isDirty`/`resetToDefaults`（仅测试用）、`Review.meta`（写过从未读）、`BasePNG.validate`/`BaseFacts`（仅测试用）、`MetalRenderer.hasBase`/`isReady`/`baseSize`、`HealthResponse.authRequired`、`PrepareResponse.cached`（spinner 本应据此区分冷/热）——要么接线要么删除。
12. **其余 UI 状态**：Connect/Reconnect 在 `.loading/.posting` 时仍可点但 `connect()` 立即 return（`AppModel.swift:263`、`ConnectionView.swift:52-62`）；`.posting` 时点行静默忽略（`:385`）；连接状态绿点只由成功 `connect()` 设置、之后请求失败不失效（`ConnectionView.swift:80-92`）；422/`prepare_failed` 不刷新列表，侧栏 badge 会停在旧状态（`AppModel.swift:694-702`）。
13. **半精度存储不在 parity gate 内**：app 的中间纹理是 `rgba16Float`（`MetalRenderer.swift:32,195-210`），parity 用 `.rgba32Float`（`ShaderParityTests.swift:530-562`）；cap=2.5 附近 half-ULP ≈9.8e-4，约 gate 的 10 倍（视觉上 0.04%）。建议 docs 注明 gate 覆盖 float32 算术，或按实际格式 gate。
14. **测试质量**：`TransportTests.swift:9-10,219-229` 把 stub server 启动失败一律转 `XCTSkip`；`WireModelTests.swift:261-265`、`BasePNGTests.swift:313-319` 有真实资产 skip；两套件都不检查 skip 数。tolerance 1e-4 比观测误差（9.5e-7）宽 100 倍，secondary 1e-6/1e-3 无来源说明；`RecipeDraftTests.swift:237-247` 与 `BasePNGTests.swift:252-268` 的测试名 overclaim（后者在合法 PNG 上只断言错误，先解码再哈希也能过）；取消测试 `TransportTests.swift:621-648` 依赖 200 ms sleep；`TestSupport.make16BitDisplayP3PNG` 与 `BasePNGTests.makePNG` 重复实现 PNG builder；`xcodebuild test`/scheme 未被实际跑过（只 build-for-testing）。
15. **仓库/证据卫生（非产品代码）**：contract 抽取藏在 `c858df8 "chore: ignore local build scratch"`（消息未提，10 文件 52 行）；`work/m3/evidence/ipad-screenshots/IMG_1790.jpeg` 实为 PNG 字节且 notes 未列；设备侧 "2032×1357 vs 2030×1355" 量测没有留下脚本/ROI 证据；`ipad/default.profraw` 是遗留 profiling 产物（gitignored）。

---

## 范围外（预存，不是这三个 commit 引入，供新 session 参考）

- `app/Tests/PhotonCoreTests/PreviewRendererTests.swift:182` 的 `testDownscaleIsBitIdenticalAcrossCalls` 会在 Core Image 两次渲染出现 1 ULP 差异时失败（本轮完整跑出现过 1 次：0.6748047 vs 0.67431647；单独重跑 20/20 通过）。建议把断言放宽到 ≤1 ULP 或标注 GPU-load-sensitive。
