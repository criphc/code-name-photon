# llm-photon 全项目审阅 — 2026-11-03

**审阅范围** 全部 60 个被跟踪文件：`app/`（PhotonCore 17 文件 + PhotonServer 8 文件 + CLI + 21 个测试文件，约 10.6k 行）、`docs/01–05`、`README.md`、`AGENT.md`、`tools/verify-heic/`、`tools/m0-fixtures/`，外加仓库卫生与 git 历史。按约定不审 `tools/toGainMapHDR/`（外部 MIT clone）与 `samples/`。

**方法** 本仓库是只读审阅 + 实测复核：三个审阅者分头读 PhotonCore / PhotonServer / 全部文档，Lead 独立复核关键结论并亲自跑通构建、测试与端到端管线。除已提交的文档修正（见「已修复」）外，**没有修改任何代码或被跟踪文件**。

**行号基准** commit `b3896d0`。文档中被修掉的旧行号不再引用，改按章节引用。

**状态更新（2026-11-03）** P0-1 / P0-2 / P0-3 已修复，每条带回归测试：`3f89f12`（编码产物拒绝 + 回读验证）、`e42ba2a`（读超时与 handler 超时拆分）、`bee3471`（recipe POST 重哈希源）、`1837eac`（文档）。`make test` **174 全绿**（PhotonCore 91 + PhotonServer 83），0 skip；端到端 `photon prep samples/sources/R0003777-P3.tif` 通过且 `verify-heic --expect-headroom 2.5` 仍 PASS（882,091 B），峰值 0.5 的源被 `hdrTooDim` 拒绝且不留产物。P0-4 此前已按 stage-2 标注处理。

**状态更新（2026-11-03，P1）** §4 的 **11 条 P1 全部修复**，`make test` **217 全绿**（PhotonCore 116 + PhotonServer 101，0 skip；原先 174）。两个需要拍板的口径按决定落地：**P1-4 只接受 Display P3 源（非 P3 在 decode 报错）**；**P1-5 缺编码器默认 fail（干净 checkout 必须先 clone `tools/toGainMapHDR`）**。提交：`8dfefb1`（AtomicFile 共用件）、`e54f34f`（P1-2 Lanczos 边界 / P1-3 writeHDR buffer 所有权 / P1-11 16-bit 装配共用）、`56ea179`（P1-5）、`1e4ccd4`（P1-4）、`4a0e106`（P1-1 状态机 / P1-8 health）、`414d3d1`（P1-6 renderKey / P1-7 真原子写）、`f141d06`（P1-9 竞争 / P1-10 codec）、`2c7ac95`（文档）。端到端复核：`photon prep samples/sources/R0003777-P3.tif` 成功且两次运行 `sdr.tif`/`hdr.tif`/`preview.heic` 字节一致；`sdr.tif`（`5378900171…`）与 `hdr.tif`（`ea3d888c…`）哈希与 docs/04 记录一致；`preview.heic` **881,253 B**（P1-2 边界修复后由 882,091 B 变化），`verify-heic --expect-headroom 2.5` PASS 7/7；Adobe RGB 源 exit 1 且不产生输出目录；`photon serve` 冒烟：health `authRequired:true` / `itemCount:6`、recipe-before-prepare 的 POST/`GET status`/`state.json` 三处均为 `pending`+`hasRecipe:true`、冷 prepare 后 `recipe_received`、LF-only → 400 与超限 `Content-Length` → 413 均 <5 ms。剩余未处理：§7 的文档口径问题（第 3、4、6、7、8 条等）与全部 P2/安全登记项。

---

## 1. 结论

1. **数学与结构是扎实的。** mask/gain（smoothstep、单调、无 NaN）、绝对 headroom cap、CIEDE2000（Sharma 34/34 组）、16-bit P3 量化（与 sRGB 曲线逐值一致）、ICC→线性 P3 不裁剪、确定性的字节一致，都有实测与真断言支撑；M1（`Pipeline`）与 M2.1（`PreviewBaseRenderer`）共享同一套 ToneMapper / PreviewRenderer / SDRQuantiser 实现，没有悄悄分叉。
2. **真正的风险是「契约靠文档、代码不设防」。** 三处最该先修（**已修，见 §4 各条的「已修」**）：编码器 `exit 0` 被当成「HDR 已交付」（合法输入可静默产出无 gain map 的 SDR HEIC）；HTTP 的 10 s 接收超时覆盖了 handler 执行（合法请求排队 >10 s 会收到 400）；`POST recipe` 不重新哈希源（原地重导出后旧 id 的 recipe 被 200 接受）。这三条都与 docs/03、docs/05、docs/04 的明文要求相反，且现有测试守不住。
3. **文档的主要病害是 M2.1 决策没有贯穿到「状态 / 验收 / 下一步」，外加一批可执行命令的路径错误。** 这一批已在本轮修掉（`b3896d0`）；剩下的是需要你拍板的口径问题（docs/02 与 stage-1 排除清单的冲突、重复内容收敛）。

---

## 2. 我实测复核过、可以放心的部分

| 检查 | 结果 |
|---|---|
| `cd app && make test`（默认构建目录，干净工作树） | **165 tests / 0 failures**（PhotonCore 86 + PhotonServer 79，与 `app/README.md`、`docs/04` 的数字一致；拆分 codec 34 / server 9 / router 19 / store 17 也对） |
| release CLI 端到端 `photon prep samples/sources/R0003777-P3.tif` | 成功：`sdr.tif` / `hdr.tif` / `preview.heic` / `meta.json`，authored peak **2.500000 linear（1.321928 stops）**，与 `docs/04` 的 M1 结果一致 |
| 产物容器验证 `tools/verify-heic/bin/verify-heic preview.heic --expect-headroom 2.5` | **PASS**：882,091 B，`tmap` ISO aux 存在，`contentHeadroom = 2.5000`，base 8bpc/32bpp、`noneSkipLast`（无 alpha）、Display P3 ICC，7/7 checks |
| 确定性 | 独立重跑得到 882,091 B 的同一产物（与 `docs/04` 记录的字节数相同） |
| `docs/05` §7 的复现命令 | 按修正后的版本实跑通过：合成图对 peak 3.9980567、base uniform 0.499986、编码器输出 4,203 B（与 `docs/05` 表格一致） |
| 测试计数拆分 | 86 = 8+8+6+11+16+16+4+5+12；79 = 34+9+19+17，与文档数字吻合 |
| `M2.1 base` 与 `M1 preview base` 的像素 | 审阅者实测同一 fixture 下 `downscaleBase(...).pixels == downscale(...).base.pixels`（逐样本相同） |

> 注：端到端 `prep` 本次测到 5.46 s / peak RSS 5.09 GB，高于 `docs/03` §7 的 ~3.0 s / ~5.2 GB。当时机器上同时有并行构建，**不作为性能漂移证据**；如需权威数字应在空闲机器上重测并更新 `docs/03` §7。

---

## 3. 本轮已修复（`b3896d0`、`e600a3b`、`a2ed94a`；无行为变更）

文档与注释类修正，不改变任何逻辑。第一批（`b3896d0`）是「过时信息 + 坏路径」；第二批按你 2026-11-03 的两个决定做：docs/02 标为 stage-2 目标（`e600a3b`），M2.1 契约全部收敛进 docs/04（`a2ed94a`）。

- `docs/04` 状态区仍写「M0 complete / M1 is next / repo 只有 docs…」；Definition of done 第 2 条仍是「preview HEIC 到 iPad」；「Next actions (M2)」还是已完成的 M2 内容，其中「`Pipeline.prepare` 是唯一渲染路径」在 M2.1 之后已不成立。三处都改成 M2.1 口径 + M3 行动项。
- `docs/02` §2「Mac 同时生成 SDR 和 HDR 两版」与 M2.1 决策相反，已改为「Mac 只渲染 SDR base，iPad 用 base + 三个控制量算 HDR」。
- `docs/03` §5 体积预算 10–30% → M0 实测 **+89%**；§7「Send the HEIC preview」标注被 M2.1 决策取代，并按 22.1 MB base 重算传输时间。
- `docs/05` §7「128 KB of TIFFs」→ 实际约 **17 MB**；复现命令补 `mkdir .tmp .mc`、改成子 shell 以免 `cd` 泄漏到后续仓库根相对路径；§4「the page … reproduced below」改为「页面留在 gitignored 的 `work/m0/deliverable/`，未入库」。
- `app/README.md` CLI/serve/curl 示例整体多一层 `..`（`../../samples` 不存在，`../samples` 才存在），且二进制路径与文档混用 app/ 与仓库根两种 cwd；统一为「从仓库根运行」。`--token SECRET` vs `TOKEN=secret` 统一成 `secret`。错误码清单补 `bad_request`（并说明它同时用于 413/501）。
- `AGENT.md`：`app/.build/release/photon` 不存在；`make release` 的产物是 `app/.build-release/release/photon`，已改并注明 `make build` 出 debug。
- `tools/m0-fixtures/README.md`：同样的 `TMPDIR` 缺失与路径修正。
- `tools/verify-heic/README.md`：自检脚本位于 gitignored 的 `work/m0/`，干净 clone 跑不了 —— 加一句「这是本地证据，不是随包测试」。
- 代码注释：`Recipe.transition`「roll-off width below `start`」应为 above；`renderKey` 并不用来命名 `work/<key>/`；`APIRouter` / `ServerConfig` 的端点与工件清单仍是 M2 的 HEIC/meta.json（实际是 PNG base + `PreviewMetadata`）；`PreviewRenderer` 头注释说「M2 发给 iPad 的 preview pair」已过时；`TIFFWriter.writeHDR` 的所有权注释是错的，并已标注它是 `docs/03` §3 警告的写法。

---

## 4. 待处理问题

### P0 — 会直接产出错误交付物 / 破坏契约

**P0-1 编码产物零验证：`exit 0` 被当成成功**
`app/Sources/PhotonCore/Pipeline.swift:210-217`、`app/Sources/PhotonCore/Encoder.swift`（`encode` 末尾）。
`Encoder` 的成功条件只有 `terminationStatus == 0 && fileExists(heic)`；`Pipeline` 拿到路径就 `replaceItem`，之后没有任何 ImageIO 回读。审阅者实测：合法 P3 源 + 默认 recipe（`start 0.62` 高于图像峰值 0.5，mask 全 0）走 `Pipeline.prepare` 返回成功，产物是**无 ISO gain map、`DecodeToHDR` 8 bpc、contentHeadroom = 1.0 的普通 SDR HEIC**，而 `meta.render.authoredPeakLinear = 0.49999`。这正是 `docs/05` §6 第 3 条（「编码前断言 HDR 回读峰值；不要用 exit 0 推断成功」）与 `docs/03` §3 明文禁止的情况。
**修法**：编码前 `guard authoredPeak >= 1.05`（把「lift = 0 / 全暗画面」当成明确的拒绝，而不是静默降级）；编码后用 ImageIO 断言 ISO aux 存在、`contentHeadroom` 与 `min(cap, authoredPeak)` 差 <5%、SDR decode 无 alpha；失败抛专门错误。`tools/verify-heic` 的这组检查可以抽成 PhotonCore 内的断言函数供 M4 复用。

**已修（`3f89f12`）**：新增 `EncodedHEICValidator`（`inspect` / `validate`，ImageIO-only，供 M4 复用）；`Pipeline.prepare` 在写任何产物前拒绝 `authoredPeak` / 预览峰 < 1.05（`PhotonError.hdrTooDim`），编码后、替换 `preview.heic` 前断言 ISO aux / `contentHeadroom` ±5%（含 `calculatedContentHeadroom` 兜底）/ 无 alpha / 尺寸（`PhotonError.encoderOutputInvalid`）。测试：`EncoderTests` 的真实编码断言 + 「峰值 0.5 仍 exit 0 但被拒绝」、`EncodedHEICValidationTests` 的无 gain-map HEIC、`DeterminismTests` 的两条 fail-fast。实测：真实试片仍 882,091 B、`verify-heic` PASS；峰值 0.5 的源退出码 1 且不产生输出目录。

**P0-2 10 s 接收超时覆盖 handler 执行，合法请求被误报 400**
`app/Sources/PhotonServer/HTTPServer.swift:55`（`receiveTimeoutSeconds`）、`:533`（`dispatch`）、`:568`（`scheduleTimeout`）。
超时在连接 ready 时挂上，只有 `send()` 才取消；handler 在单串行队列上跑，`ItemStore.prepare` 还持锁渲染。因此 N 个冷 prepare 排队就会让后面的请求在 10 s 后被回 400 `timed out after 10 s waiting for a complete HTTP request`。审阅者用「handler 睡 11 s」精确复现（11 s 后 handler 结果被丢弃）。按 `docs/04` 冷 prepare 1.46 s/张，7–8 张连续冷 prepare 即可触发。另一面：handler 永不返回时没有 watchdog，连接会拿到 400，但 handler 队列/锁永久堵死。
**修法**：拆成「读 deadline（收到数据就重置，解析出完整请求后立即 cancel）」与「handler deadline（或不把读超时算到 handler 上，`dispatch()` 前 cancel）」。同时把超时值改成可注入的 internal 配置，否则这条路永远测不到。

**已修（`e42ba2a`）**：`HTTPServer.Timeouts`（internal，10 s 无数据 / 600 s handler）注入到连接；读 deadline 每收到一块数据重置、解析完成即取消，`dispatch()` 前武装独立的 handler deadline（含串行队列排队时间）。超时文案改为 inactivity；handler 超时回 500 `internal_error`，迟到结果丢弃；挂死的 handler 仍占住队列/锁这一残余限制写进代码注释。测试：慢 handler（1.2 s）在 0.5 s 读超时下仍 200、半截请求 400 且提到 inactivity、handler 超时 500。

**P0-3 `POST recipe` 不重新哈希源：原地重导出后旧 id 的 recipe 被接受**
`app/Sources/PhotonServer/ItemStore.swift:286-323`（`storeRecipe`）vs `:458`（`verifySourceIdentityLocked`，只有 `prepare` 调用）。
`storeRecipe` 只比 `recipe.source.sha256 == item.id`，而 `item` 来自扫描 memo，可能已经 stale；宽高也只与已存 state 比。审阅者用「同长度改写 + `futimens` 还原 mtime」复现：POST recipe 返回 200 并落盘到旧 id 目录，紧接着 `prepare` 才报 `source_changed`。这与 `docs/04` M2「a re-export is a new id and a recipe for the old bytes is refused with 409」相反，iPad 会拿到假成功。
**修法**：`storeRecipe` 开头调用 `verifySourceIdentityLocked(item:)`（顺手刷新 memo）再比对 sha；补一条「in-place 重导出后 POST recipe → 409」的测试。

**已修（`bee3471`）**：`storeRecipe` 在 `resolveLocked` 之后、解码 body 之前重哈希源（陈旧 id 判 409 `source_changed` 而不是 400），并刷新 memo；`ItemStore` 与 `verifySourceIdentityLocked` 的注释写明 `prepare` 与 `storeRecipe` 共用同一道关。测试：原地重导出机制提炼成 helper（同 inode + 原始 `futimens`），新增 `testPostedRecipeAfterAnInPlaceReExportIsSourceChanged`（409、无陈旧 `recipe.json`、id 已刷新、状态回到 pending）。

**P0-4 `docs/02` 用户指南承诺了 stage-1 明确排除的东西 —— 已按决定处理**
`docs/02` 的 Inbox 监视、Mac app 作业态、自动发现与配对、胶片条、Settings 都分别被 `docs/01` §1.4 与 `docs/04`「Out of scope for stage 1」排除，且没有对应里程碑。**决定（2026-11-03）：标成 stage-2 target。** `docs/02`（`e600a3b`）现在有醒目的 scope 说明 + 逐项 `(stage 2)` 标注 + stage-1 的等价操作（CLI flag / recipe 字段）。

### P1 — 正确性与可维护性，M3/M4 前应处理

1. **状态机三处不一致** `ItemStore.swift:286-361`、`:492`（`summaryLocked`）。`POST recipe`（未 prepare）时 `state.json` 写 `recipe_received`，但 API summary 报 `pending`；删掉 `recipe.json` 后仍报 `recipe_received` + `hasRecipe:false`；`failed` 会隐藏完好的 preview。建议 summary 的 state 统一由工件推导（`hasPreview && hasRecipe → recipe_received`，`hasPreview → preview_ready`），或 recipe POST 前要求 `previewReady`。
2. **Lanczos 边缘变暗/振铃** `PreviewRenderer.swift:162`（`lanczos`）。采样到 extent 外时是透明黑，uniform 0.5 的 200×100 → 80×40 实测首行角落 0.4402 / 内部 0.4693 / 第二行 0.5104，中心 0.5000；这影响 M1 preview 和 M2.1 发给 iPad 的判图底图，而 `PreviewRendererTests` 用 `margin = 8` 显式跳过边界。建议 `.clampedToExtent()` 后再 crop，并补一条边界像素断言。
3. **`TIFFWriter.writeHDR` 仍用 `CIImage(bitmapData:)` + 局部 `Data`** `TIFFWriter.swift:69`（HDR 写段，`:85` 是 CIImage 构造）。这是 `docs/03` §3 与 `app/README` 明令禁止、`PreviewRenderer.ciImage` 已经改掉的写法。审阅者的 poison 探针**未能复现** UAF（本 SDK 上 CIImage 疑似在 init 时快照），但它依赖未文档化行为，且多一次全帧拷贝（100 MP 约 1.7 GB）。建议改用 provider/CGImage 路线，并顺便澄清 `docs/03` §3 那条经验的机制。
4. **非 P3 源在 16-bit 交付时静默丢色** `SourceDecoder.swift`、`SDRQuantiser.swift:15`。解码本身不裁剪（Adobe RGB 饱和绿 → 线性 P3 `r = −0.150`），但量化时 `min(max(x,0),1)` 把它压成 0，无警告、无测试；`docs/03` §4 早就写了「Adobe RGB 的绿在 P3 之外会 clip」，而 `docs/04` 决策 1 的交付路径是 `-P3` 导出。建议：明确只接受 Display P3 源（非 P3 直接报错）或先做 ColorSync 转换；至少 base 出现越界样本时警告。补一条 Adobe RGB 饱和色回归测试。
5. **最高风险的集成测试只断言 `ftyp`，缺编码器时还静默 skip** `Tests/PhotonCoreTests/EncoderTests.swift`。`testEncodeTinyPairProducesGainMapHEIC` 只检查文件名与 magic；普通 SDR HEIC 也能过。`requireRepoEncoder()` 在 `tools/toGainMapHDR` 缺失时 `XCTSkip`——而该工具按 `AGENT.md` 不入库，干净 checkout 里 4 个测试（3 Encoder + 1 Determinism）直接跳过，「绿色但没跑」。建议用 ImageIO 断言 ISO aux / `contentHeadroom ≈ cap`（±5%）/ 无 alpha / 尺寸；CI 里缺编码器改为 fail。
6. **`renderKey` 把 provenance-only 的 `source.path` 算进去，且写的是绝对路径** `Recipe.swift`（`canonicalRenderJSON`）、`Pipeline.swift:123`。`docs/04` 规定 `source.path` 只作 provenance、repo-relative；现在仓库挪位置或同字节文件换目录都会换 cache key。建议在 render JSON 里排除 path（或规范化成相对路径），并把契约写清楚。
7. **「原子写」实际是 remove + move** `Pipeline.swift:337-376`、`ItemStore.swift:730`。两步之间目标文件不存在，`docs/03` §6 的措辞是「temp + rename」。建议 `FileManager.replaceItemAt` 或 POSIX `rename(2)`；`preview-base.png` 目前也不是原子写。
8. **`/api/health` 会被冷 prepare 阻塞，且 `authRequired` 恒为 true** `HTTPServer.swift` 单串行 handler + `ItemStore.itemCount()` 同一把锁；`APIRouter` 用 `(try? store.itemCount()) ?? 0` 吞掉错误（batch 不可读时仍 200 `ok:true`）。M3 用 health 做可达性探测时会误判「掉线」。建议 health 用原子缓存的 count，并把 `authRequired` 传 `!token.isEmpty`。
9. **v5 语言模式下两处真实的跨队列数据竞争** `HTTPServer.swift`（`didClose` 在 handler 队列读、连接队列写；`port` 锁内写、锁外读）。现在不崩只是因为 Bool/UInt16 在 arm64 上原子。切 Swift 6 语言模式前必须先修。
10. **Codec 行为与注释/README 承诺不一致** `HTTPCodec.swift`。声明 body 超 4 MiB 时 `isCompleteRequest` 返回 false，连接一直等到 10 s 才 400，而不是注释承诺的 413；LF-only 请求同样等 10 s；重复 `Transfer-Encoding` 只看第一条。建议 header 完整后立即 413、多值 TE 全部检查、LF-only 在 64 KiB 内直接 400。
11. **跨路径等价性与 16-bit CGImage 装配** `TIFFWriter.swift` / `PNGWriter.swift` 各写了一份 16-bit P3 `CGImage` 装配（`SDRQuantiser` 只保住了传输+量化这一步）；目前没有测试断言「M2.1 PNG 样本 == M1 preview base 样本」。建议抽一个 `SDRBaseCGImage.make(from:)` 共用，并加一条像素等价测试（不需要编码器与 `samples/`）。

### P2 — 择机处理（有证据，不急）

- `Encoder.encode` 无子进程超时、不区分信号退出、stderr 全量进错误消息（M2 会当 HTTP body）；兜底「取目录里第一个 HEIC」在共享输出目录可能返回旧文件。
- `Pipeline.outputFile` 用 `try? … ?? 0` / `?? ""` 吞掉 stat/hash 错误，meta 会写成「0 字节、空 sha」而不是报错。
- `HDRRendition` 内联了一份 mask/gain（与 `HighlightShape` 重复），对 NaN luma 的行为与 `HighlightShape.mask` 不一致（前者抛错、后者归 0）。建议共用 `@inline(__always)` 实现。
- `Geometry` 的「alpha 恒为 1.0」不变量没有被初始化器强制（`HeadroomCap` 会原样拷贝任意 alpha，测试里就有 0.25/1.5）。
- `PNGWriter` 用标量 `LinearImage.isFinite` 扫全帧（`TIFFWriter` 用 vDSP 版 `SampleMath`）。
- `PreviewBase.profileName` 是硬编码常量而不是从写出的 PNG 回读；`/meta.base.longEdge` 是「请求的长边」而非产物实际长边（源小于 2560 时不相等），字段名建议改 `requestedLongEdge`。
- `/recipe` 返回未 decode/validate 的 `recipe.json` 原文；`hasRecipe` 只看文件存在。
- `writeAtomically` 崩溃后残留 `.*.tmp` 无人清理；`ItemStore` 的缓存判定完全依赖 `state.json`，损坏时会丢弃完好的 22 MB base（`preview-meta.json` 里其实有全部校验信息）。
- `PreviewBaseTests` 的临时目录不清理；`EncoderTests` 用 `chdir` 改进程全局 cwd（并行测试会竞态）；`ColourRoundTripTests` 的 ΔE 容差（mean<0.5/p95<1.0）比实测值（0.0）宽 3–4 个数量级。
- 死代码：`RGBA.transparent`、`RGBA.isFinite`、`fractionAbove`、`Geometry.map`、`Recipe.sourceKey` 零调用。
- 100 MP 的峰值内存未实测；按 24 MP 的 5.2 GB 外推约 21 GB（估算）。`docs/03` §7 建议补一条实测或明确限制。

### 安全（本轮不展开，仅登记；按你的要求）

- **空 token 会静默关闭认证**：`--token ''` 或 `PHOTON_TOKEN=` 启动后 `GET /api/items` 无 token 返回 200（CLI 用 `??` 取 env，不判空）。这是唯一值得在 M3 前顺手修的。
- 无并发连接数上限（每连接最多缓存 ~4.27 MB，10 s 超时是唯一约束）；重复 `Transfer-Encoding` 第二条被忽略、header value 未拒绝裸 CR/LF/NUL（当前无前置代理，不可利用）。
- `constantTimeEquals` 的长度项被截成 `UInt8`（理论上长度差 256 倍数时失效；需已知完整 token，不构成绕过）。
- token 不出现在错误体/日志（401 body 为通用文案），符合 README 声称。

---

## 5. 数学正确性专项（按你指定的重点）

**已核实正确（有测试或实测证据）**

| 项 | 结论 |
|---|---|
| `mask` / `gain` | `smoothstep(start, start+transition, luma)`，端点 C¹、单调非减；`lift ∈ 0…4` ⇒ gain ∈ 1…16；NaN/±inf luma 有防御；`mask = 0` 时严格返回 1.0 |
| 绝对 cap | `HeadroomCap.clamp` 是纯上界 clamp，≤ cap 的样本按位保留、幂等、无下界；Lanczos 之后再 clamp 一次（预览与交付同 headroom） |
| CIEDE2000 / CIELAB | 实现与 Sharma 的 34 组标准测试数据全部吻合（tests 真断言） |
| 16-bit P3 量化 | 与 sRGB 分段曲线逐值一致；TIFF 与 PNG 共用 `SDRQuantiser`，实测往返 ΔE2000 = 0 |
| ICC → 线性 P3 | 不做色域裁剪（Adobe RGB 饱和绿保留负值），orientation 固定 1，无 alpha |
| 确定性 | `renderKey` 排除 `created`；重复运行 `sdr.tif` / `hdr.tif` / `preview.heic` 字节一致（本次实测 882,091 B 与文档记录相同） |

**发现的问题（按影响排序）**

1. **编码结果不校验**（P0-1）：数学上算出了正确的 HDR 版本，但交付物可能根本没有 gain map，而管线不会发现。
2. **Lanczos 边界**（P1-2）：预览/判图底图的最外 1–2 px 偏暗并带振铃；交付物（全分辨率）不受影响。
3. **mask/gain 两份实现**（P2）：`HDRRendition` 的内联版本与 `HighlightShape` 对 NaN luma 处理不同，违反 docs/04 风险表「一份实现」的意图。
4. **越界语义**：工作缓冲不裁剪 ✓，但 16-bit 交付会 clamp；应把「只接受 P3 源」或「越界即警告」写进契约（P1-4）。
5. **alpha 不变量**：类型层不强制，靠调用方自觉（P2）。

---

## 6. 测试质量与覆盖缺口

**总体**：165 个测试全绿、fixtures 全部运行时生成、不依赖 `samples/` 与 `work/`；核心数学有真断言。问题在于「最贵、最高风险的一条路径（编码器集成）断言最弱」，以及失败路径与状态机几乎没测。

**P0（进 M4 前必须补）**

1. 编码产物断言：正常 pair 必须存在 ISO aux、`contentHeadroom ≈ cap`（±5%）、SDR decode 无 alpha、尺寸正确；低峰值（mask 全 0 / lift 0 / cap 1）必须被拒绝而不是写普通 SDR。 ✔ 已补（`3f89f12`：`EncoderTests` + `EncodedHEICValidationTests` + `DeterminismTests`）。
2. 解码「不裁剪」断言：带 Adobe RGB ICC 的饱和色 fixture，断言负值/超 1 值保留，并断言 16-bit 写出时的处理方式。
3. Encoder 错误路径：`/bin/false` → `encoderFailed` 且带 stderr；exit 0 但无文件 → `encoderOutputMissing`；路径含空格；3-channel float TIFF 必须被拒。
4. 编码集成测试不再只看 `ftyp`（同 P1-5）。 ✔ 已补（`testEncodeTinyPairProducesGainMapHEIC` 现在断言 ISO aux / headroom / alpha / 尺寸）。

**P1**

5. `storeRecipe` 在 in-place 重导出后必须 409；复用时基保持技巧（ItemStoreTests 已有）。
6. recipe-before-prepare 的状态转换：POST 响应 / `GET /status` / `state.json` 三者一致。
7. corrupt/缺失 `state.json` + 完好 preview；`recipe.json` 删除/corrupt；`failed` 与完好 preview 并存。
8. 并发：N 线程同 item `prepare`（互斥 + `cached` 一致性）、`prepare` 与 `storeRecipe` 交错。
9. 慢 handler / 请求 deadline（需要先做 P0-2 的可注入超时）。
10. `previewLongEdge` 变化使缓存失效（现在只测 `appVersion` bump）。
11. 跨路径像素等价（M2.1 PNG 样本 == M1 preview base 样本）；`/meta.base.longEdge` 语义（源小于长边时）。
12. Router/Codec 边界：HEAD/OPTIONS、`//api//items`、`..`/`%2e%2e`、双 auth header 优先级、空 token、LF-only、CL 超限应立即 413、重复 TE。
13. 确定性跨进程：现在只在同进程跑两次；建议加 CLI 级 byte-identity，并让「缺编码器」在 CI 里 fail。

**现有 flaky 风险**

- `HTTPServerTests.rawExchange` 把 `ECONNRESET` 当失败，而 server 可能在未读完 pipelined bytes 时 `cancel()` 发 RST。
- `testPortInUseThrowsClearError` 断言错误文案里含英文 `in use` / `48`，依赖系统本地化。
- 多处 mtime 断言在粗粒度时间戳的文件系统上可能偶发。

---

## 7. 文档与仓库卫生（本轮修复之外）

**已修** 见 §3。**以下是需要你决定的口径问题**，我没有擅自改：

1. **AGENT.md「一件事只详细写一次」—— 已按决定处理（`a2ed94a`）**：M2.1 决策原来散在 7 处、端点/错误码契约在 `app/README` 与 `docs/04` 各写一遍。**决定（2026-11-03）：全部放进 `docs/04`。** 现在 `docs/04` 有 "M2.1 — the base-first contract" 小节（决策+理由、端点表、传输/认证、identity/状态机、错误码+curl 矩阵、缓存规则），其余 6 处各一句 + 链接；归属表补了 `docs/04` 的职责范围与缺失的 `app/README.md` 行。
2. **docs/02 的 stage 范围**（同 P0-4）。
3. `docs/01/02/03` 仍写「Design document N of 3」，但 `docs/` 现在有 5 篇（04 是计划、05 是记录）。建议去掉「of 3」或说明「设计文档 01–03；04 计划；05 记录」。
4. `docs/03` §6 与 `docs/04` M2 都说 TLS/Bonjour「deferred to M3」，但 `docs/04` 的 M3 工作包没有这两项。建议二选一：写进 M3 验收，或统一改成「未排期」。
5. `.gitignore` 只忽略 `samples/sources/` 与 `samples/reference/`，而 `README`/`AGENT` 说「`samples/` 仅本地、已被忽略」。建议改 `samples/`。
6. `Makefile` 的 `release` 硬编码 `--scratch-path .build-release`，不接受 `SCRATCH`，与文档宣传的「并行 agent 用 SCRATCH/TMP/MC 分开构建」不一致。
7. `docs/04` M2 的 curl matrix 与错误码清单没有 `bad_request` / 413 / 501（`app/README` 已补，`docs/04` 建议加一行）。
8. 术语：`P3` 与 `Display P3` 混用（canonical 是 `DisplayP3`）；`docs/03` §4「Set headroom to the actual peak」与「cap 是像素上限、广告 headroom 由内容推导」表述冲突。
9. 历史提交信息：早期有 `"1"` / `"agent aks"` / `"better 04"` / `"doc 01"` 等无信息量提交，`510b192` 一个提交做两件事；按 AGENT.md 不改写历史，从下一次起沿用 `docs:` / `feat(...)` 风格即可。

**仓库卫生：干净。** `git status` 空、`git ls-files` = 60、无构建产物/二进制/缓存被跟踪；`.build*`、`.mc*`、`.tmp*`、`bin/`、`work/`、`inbox/out/cache/`、`samples/*`、`tools/toGainMapHDR/` 都已忽略。唯一的小风险是上面第 5 条。

**测试/工具与文档的一致性：一致。** `docs/05` 的 M0 数字（3,853,079 B、`AlternateHeadroom 1.321928`、base meanAbs 1.4753 / bias +0.0907 / p99 7 / p99.9 12 / max 138）与本次 `verify-heic` 复跑完全吻合；`docs/04`/`docs/05` 的 recipe 实例与磁盘上的 `work/m0/deliverable/R0003777-M0.recipe.json` 逐字段一致；`make-pair` 两次运行字节一致。

---

## 8. 建议顺序（M3 之前 / M4 之前）

**M3 开工前（约半天到一天）**

1. ~~修 **P0-1 / P0-2 / P0-3**，每条配一个测试（编码产物断言、可注入超时 + 慢 handler、storeRecipe 重哈希）。~~ —— 已完成：`3f89f12` / `e42ba2a` / `bee3471`（文档 `1837eac`），`make test` 174 全绿、0 skip。
2. 顺手修 **空 token 静默免认证**（一行 `!token.isEmpty`）。
3. ~~拍板 docs/02 的 stage 口径~~ —— 已按「stage-2 target」落地（`e600a3b`）。
4. ~~重复内容收敛~~ —— 已全部收敛进 `docs/04`（`a2ed94a`）。M3 的 iPad 客户端现在只应读 `docs/04` 的 M2.1 一节作为契约。

**M4 之前**

5. 补齐 §6 的 P0/P1 测试清单；把编码产物断言搬进 `PhotonCore` 作为 M4 的前置 gate。
6. 决定 `renderKey` 是否排除 `source.path`（会影响缓存 key 的语义，越早越好）。
7. 原子写改成 `replaceItemAt`/`rename`；`/api/health` 去锁优化。
8. 在空闲机器上重测 `docs/03` §7 的性能数字（本次测量受并行构建干扰，不作数），并补 100 MP 的内存实测或明确限制。

**M5（验收）之前**

9. `docs/02` 与真实交付流程对齐后，再按 `docs/03` §5 的 reject criteria 做 iPad Photos/Safari 验收。
