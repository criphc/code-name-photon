---
type: decision
owner: docs
updated: 2026-11-05
---

# ADR-0008：shader parity 在 SwiftPM 测试里跑（MSL 作为包资源）

- 状态：已接受（2026-11-05，P0，spike A 通过）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) R1、R2、R11、R12；
  [ADR-0001](0001-repository-package-split.md)
- 影响阶段：P3

## 背景

stage 1 的 parity gate（`ipad/PhotonTests/ShaderParityTests`）跑在 Xcode 的 macOS 测试 bundle
里：`HighlightShape.msl` 作为 app bundle 资源，app 与测试在运行时用
`device.makeLibrary(source:)` 编译同一份文本。迁移后 `client` 变成 SwiftPM 包，若 parity 仍
只能由 Xcode 工程跑，`make test` / headless CI 就摸不到这条关键规则（MSL 与 CPU 数学
≤ 1e-4 一致）。

## 决策

- `client` 包的 `ClientKit` target **拥有唯一的 `HighlightShape.msl`**，以
  `resources: [.copy("Shaders")]` 打包；app 与测试都通过同一个 `ShaderResource` loader 取字节，
  **不再用 `Bundle.main`**。
- parity gate 作为 `client` 包的 Swift Testing 用例，在 **macOS host** 上跑
  `swift test`（`swift test` 没有 iOS destination，这是刻意接受的事实：它验证的是 app 运行时
  编译的同一份 MSL 字节，不是模拟器渲染）。
- shader **保持 `.msl` 扩展名 + 运行时编译**；不引入 `.metal` / `.metallib` 构建步骤，不依赖
  Metal toolchain。
- 断言必须是真的：`MTLCreateSystemDefaultDevice()` 或 `makeLibrary(source:)` 失败 →
  **测试失败**，不允许 `XCTSkip` / `#if canImport` 静默变绿。64×64 解析夹具的快速 gate 无条件
  跑；trial-base 大图 parity 仍是 opt-in（需要 gitignored 的 `work/m21-final` 夹具）。
- 原来的 `ipad/PhotonTests/ShaderParityTests` 在 P3 搬迁并删除；不再保留第二份 MSL。

## 证据（spike A）

- 命令：`cd .spikes/metal-parity && mkdir -p .tmp .mc && TMPDIR=$PWD/.tmp
  CLANG_MODULE_CACHE_PATH=$PWD/.mc swift test --disable-sandbox --scratch-path .build-spike`
  → exit 0。
- 结果：3/3 测试通过；64×64（4096 px / 16384 样本）GPU dispatch；**最大绝对误差
  7.1525574e-07**，门限 1e-4；夹具实际覆盖 mask 0（2599 px）、transition（1197）、mask 1
  （300）、cap engaged（252）；`authoredDelta = 1.552642`（不是空跑）。
- `.copy` 保留 `…/Resources/Shaders/HighlightShape.msl`；`.process` 会拍平到 bundle 根。
  打包后的 MSL 与仓库源 sha256 一致（`73bb1e26…dd16d`）。
- 环境事实：M1 Max 上 headless Metal 可用；`--disable-sandbox` 在 DSH 下是**必需**的（否则
  manifest 编译阶段就被嵌套 sandbox 拒绝）；path 依赖的 package identity 是目录名 `contract`；
  Swift Testing 会先打一行 XCTest `Executed 0 tests`，真正的结论在
  `Test run with N tests … passed`。
- spike 代码在 `.spikes/metal-parity/`（gitignored，throwaway）；结论只保留在本 ADR。

## 后果

- `client` 包的 `swift test` 就能跑 parity；Xcode 只负责编译 app，不再承担 parity 门禁。
- app 与测试共享同一个 loader，MSL 只有一份；如果未来真的出现第二份副本，用 sha256 比对兜底。
- parity 不覆盖 iPad 实际渲染路径（EDR/headroom/缩放），这是预览与交付分工的既定事实；
  设备验收仍在 P3/P4 的手点与交付 gate 里。

## 备选与取舍

- **继续用 Xcode 测试 bundle 跑 parity**：迁到 SwiftPM 后 headless 门禁摸不到；拒绝。
- **`.metal` 资源 + 编译期 metallib**：需要 Metal toolchain，且测试编译的字节可能不是 app
  运行时编译的那份；拒绝。
- **模拟器/设备上跑 parity**：需要 iOS runtime 与签名，慢且脆；测试证明的是数学与 MSL 文本，
  不需要设备；拒绝（设备验收另算）。
- **失败时 skip**：会把「没有 GPU/编译失败」伪装成绿；拒绝。

## 验证

P3 的 `make test`（或 `client` 的 `swift test`）必须包含并实际执行 parity；0 skip；误差
≤ 1e-4。
