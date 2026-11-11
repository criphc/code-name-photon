---
type: record
owner: docs
updated: 2026-11-05
---

# P3 报告：client 包 + 新 iOS 工程 + `ipad/` 退役

- 日期：2026-11-05
- 分支：`migration/p3`（从 `main` 的 P5-prep 合并点切出），tag `p3`
- 对照计划：[p3-plan.md](p3-plan.md)
- 结论：**P3 结构迁移完成**；产品 UI 按用户要求保持 placeholder，临时 debug 原型用于设备验收
  后已删除；`ipad/` 已退役。engine 行为未改，但发现一个独立的 `previewAgreement` edge case，
  见 [p3-known-issue-preview-agreement.md](p3-known-issue-preview-agreement.md)。

## 1. 门禁结果（最终树）

| 门禁 | 结果 |
|---|---|
| `make test` | contract **47 XCTest + 14 Swift Testing**；EngineKit **87**；ServerKit **103**；ServerControl **13**；ClientKit **66**（1 expected trial skip）；ClientModel **39**（10 suites）；全部 0 failures |
| `make integration` | **2 tests / 0 failures**（真实 appctl serve readiness + health + SIGTERM；deliver CLI smoke） |
| `make parity` | client 包：**6 tests / 0 failures / 0 skips**（trial base 含在内） |
| `make check` | **exit 0**（test + integration + parity，重跑确认） |
| Xcode MCP `BuildProject` | `apps/ios` Debug（simulator）**built successfully**，0 errors/0 warnings |
| `make ios-build` | `apps/ios` unsigned generic iOS **BUILD SUCCEEDED**（普通终端/完整沙箱外验证） |
| `make ios-build-device` | iPad 签名 Debug **BUILD SUCCEEDED**（Personal Team `289223FXNS`） |
| `make ios-install` / `make ios-launch` | `com.criphc.Photon.Client` 安装并启动成功（最终 placeholder 版） |
| 客户端测试 | ClientKit 66 / 1 expected trial skip；ClientModel 39；无 skip 除 trial |

## 2. 交付内容

### 2.1 client 包

```
client/
├── Package.swift                     package `client`；ClientKit/ClientModel + tests
├── Sources/ClientKit/                Transport/BasePNG/RecipeDraft/RenderContract
│   ├── Shaders/HighlightShape.msl    the single MSL source (package resource)
│   ├── ShaderResource.swift          the single loader (Bundle.module)
│   └── PhotonClientProtocol.swift    injectable transport surface
├── Sources/ClientModel/              SessionModel + JudgeModel + Notice + settings
├── Tests/ClientKitTests/             transport/base/draft/render-contract/parity
├── Tests/ClientModelTests/           Session/Judge state-machine tests
└── README.md                         client architecture/control/errors/parity/device facts
```

- `ClientModel` 现在真正拆开：`SessionModel` 管设置/连接/health/items/刷新/通知；
  `JudgeModel` 管选中/review 缓存/prepare→download→decode/draft/滑块/compare/overlay/
  post/receipt/dirty/409/判图通知。`AppModel` 已删除。
- 行为保持（p3-model 报告）：one-shot 409、缓存 A→B→A、stale load discard、clamped draft、
  receipt/dirty、401/404/422/network/retry。两个有意差异：阶段/通知拆分后由 app 让
  `judge.isShowingJudge` 优先；`disconnect()`/`reset()` 清 review 缓存（重连后重新下载）。

### 2.2 单一 MSL + parity

- `HighlightShape.msl` 只存在于 `client/Sources/ClientKit/Shaders`，`.copy("Shaders")`；
  app/prototype 和 parity 测试都通过 `ShaderResource` 读取。
- parity 在 `swift test` 跑；解析门无条件，trial base 由 `PHOTON_TRIAL_BASE_PARITY=1` 打开，
  `make parity` 0 skip；无 GPU 时 **fail 不 skip**；新增 packaged-vs-checked-in sha256 测试。
- `MetalRenderer` 不再用 `Bundle.main`，改为 `try ShaderResource.source()`。

### 2.3 apps/ios

- `apps/ios/iOS.xcodeproj`（Xcode 27 JSON）：target `PhotonClient`，
  `com.criphc.Photon.Client`，iOS 27，`TARGETED_DEVICE_FAMILY=1,2`，Personal Team
  `289223FXNS`；链接 `client` + `contract` 两个本地包产品，不链接 server。
- 产品 UI：Connection/Library/Judge 三个 placeholder；无网络/判图接线。
- 临时 debug 原型：旧视图/Render 搬到 `Sources/Prototype`，`#if DEBUG`，接
  `SessionModel`/`JudgeModel`，产品 placeholder 上的 “Open prototype (debug)” 入口；
  **设备验收后删除**（当前树不存在）。
- `Info.plist`/Assets 从旧工程移入 `Resources`；本地网络用途文案改为 `appctl serve`。

### 2.4 根入口与文档

- 根 Makefile：`test` 加 `client-test`；`parity` 改为 client 包；`ios-build` 指向
  `apps/ios`；新增 `ios-build-device`/`ios-install`/`ios-launch`（`DEVICE_UDID` 可覆盖）。
- `ipad/` 删除；`client/README.md` 接管客户端架构/控件语义/状态错误/parity/设备事实。
- 根 `README.md`/`AGENT.md`、`docs/01/02/08/09`、`server/README.md`、`contract/README.md`
  的 `ipad/` 路径改为 `client/`/`apps/ios`；`docs/09` 增加本条 known issue 指针（见下）。

## 3. 设备验收（iPad Pro 12.9″ 6th gen / iPadOS 27 / UDID `00008112-001E055E3EF0C01E`）

- app 安装并启动；Debug 原型连接 `appctl serve`（Mac LAN `192.168.10.104:8787`，
  batch `fixtures/media/sources`，token `p3-accept-token`）。
- 判图/post 了两张：`FPL05190-P3.tif` 和 `R0003777-P3.tif`。
- **通过图**：`FPL05190-P3` 的 8/8 检查 PASS，preview ΔE mean 0.7483；
  交付在 `out/p3-fpl/`。
- **问题图**：`R0003777-P3` 的 iPad recipe 在 `previewAgreement` FAIL（ΔE mean 40.1，其余 7 项
  PASS），交付门禁正确拒绝，rejected 留在
  `work/p3-accept/<sha>/rejected/…`；该 HEIC 只用于视觉对照，不是合格交付。
- 用户判断：两张图在 **Photos（View Full HDR 开/关）** 与 **Safari（visual-check 页面）**
  的 HDR/SDR 观感都正常；问题图的 rejected HEIC 没有肉眼可见异常。详见 known issue。
- 验收后删除 debug 原型，重建 placeholder app，`make ios-install` + `make ios-launch` 成功
  （最终树只有 placeholder）。

## 4. 独立问题

[p3-known-issue-preview-agreement.md](p3-known-issue-preview-agreement.md)：
authored peak（2.176）低于 cap 2.5 的 recipe 交付出现 preview vs delivered ΔE mean 40；
归档/Lift=2.0/FPL 的 cap-engaged recipe 都 8/8 PASS；视觉正常，疑似 `previewAgreement` 内部
比较/编码 headroom 归一化 edge case。**保持 open，不修，不绕过门禁**；修复后补交付回归。

## 5. 与计划的偏差 / 说明

- 产品 UI 不迁移旧界面，只留 placeholder；旧原型仅 debug 验收用，已删除（用户决定）。
- `SessionModel`/`JudgeModel` 现在就拆（用户决定）；行为差异见 §2.1。
- 本地包 manifest 名改为目录名 `client`/`contract`，`ContractKit` 仍是 product；这是 Xcode 27
  解析本地包唯一性的要求（否则 package name 冲突）。
- 签名改用已登录的 Personal Team `289223FXNS`（用户决定；原计划 team `67GJNQAKU5`）。
- `client/README` 以 P3 结束后状态描述：无 debug 原型；P6 再做产品 UI。
- `make ios-build` 在 DSH 沙箱内仍会因嵌套 sandbox/包解析失败；agent 用 Xcode MCP，
  普通终端/CI 用 make（与 ADR-0009 一致）。本次用一次性 full-access 验证了 make 链。

## 6. 下一步

- **P4**：macOS GUI（`PhotonServerWrapper`）用 `ServerControl` 监管 `appctl serve`；动态端口
  `--port 0`、TCC/Cmd+Q、孤儿 watchdog、app sandbox/entitlements 见 ADR-0010。
- **P5**：workspace、design/、AGENT 拆分、docs 重组、`docs-check`（排除 archive 与
  `contract/Tests/**/Fixtures/`）、根 Makefile 的 app build/docs/ui 目标收口；`AGENTS.md`
  在 P5 归档。
- **P6**：真正的 UI 设计与 model-surface 冻结；当前 placeholder 只保证 app 能构建/启动。
- **Known issue**：`previewAgreement` uncapped-HDR edge case 需独立修复/回归。

## 7. 复现

```bash
make test
make integration
make parity
make check
# agent 内 app 构建：Xcode MCP BuildProject（apps/ios, PhotonClient）
# 普通终端/CI：
make ios-build
make ios-build-device DEVICE_UDID=00008112-001E055E3EF0C01E
make ios-install DEVICE_UDID=00008112-001E055E3EF0C01E
make ios-launch DEVICE_UDID=00008112-001E055E3EF0C01E
```
