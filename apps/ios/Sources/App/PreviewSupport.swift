#if DEBUG
import SwiftUI
import ClientModel
import ClientKit
import ContractKit

// 预览专用：不连网、不落盘的假 transport。只在 Debug 里编译。
//
// 只实现外壳预览需要的那几个端点：`listItems` 给胶片条喂素材，其余抛错 ——
// 画布是 Metal/EDR，预览里本来也看不到，所以不去伪造 base。

private struct PreviewSettings: PhotonSettingsStore {
    let settings: PhotonConnectionSettings?

    func load() -> PhotonConnectionSettings? { settings }
    func save(_ settings: PhotonConnectionSettings) {}
}

private struct PreviewClient: PhotonClientProtocol {
    let items: [ItemSummary]

    func health() async throws -> HealthResponse {
        HealthResponse(version: "preview", itemCount: items.count, authRequired: false)
    }

    func listItems() async throws -> [ItemSummary] { items }

    func prepare(itemID: String) async throws -> PrepareResponse { throw ClientError.notFound }
    func previewPNG(itemID: String, progress: ((Double) -> Void)?) async throws -> Data {
        throw ClientError.notFound
    }
    func thumbnailHEIC(itemID: String) async throws -> Data { throw ClientError.notFound }
    func postRecipe(itemID: String, recipe: Recipe) async throws -> RecipePostResponse {
        throw ClientError.notFound
    }
}

/// 一个不连网的会话 + judge，`connect()` 后就有素材列表。
@MainActor
private func previewModels(_ items: [ItemSummary]) -> (SessionModel, JudgeModel) {
    let store = PreviewSettings(
        settings: PhotonConnectionSettings(host: "192.168.1.20",
                                           port: SessionModel.defaultPort,
                                           token: "preview")
    )
    let session = SessionModel(settingsStore: store, makeClient: { _ in PreviewClient(items: items) })
    return (session, JudgeModel(session: session))
}

private func previewItem(_ index: Int, name: String) -> ItemSummary {
    ItemSummary(
        id: String(format: "%064d", index),
        name: name,
        path: "/batch/\(name)",
        state: .previewReady,
        previewReady: true,
        hasRecipe: index.isMultiple(of: 2),
        width: 2560,
        height: 1700
    )
}

private let previewItems: [ItemSummary] = [
    previewItem(1, name: "R0003777-P3.tif"),
    previewItem(2, name: "R0003778-P3.tif"),
    previewItem(3, name: "R0003779-P3.tif"),
    previewItem(4, name: "R0003780-P3.tif"),
]

/// 长文件名 + 大字号：最容易把胶片条和状态条撑破的组合。
private let stressedItems: [ItemSummary] = [
    previewItem(11, name: "2026-11-08_FPL05190_CaptureOne_Export_Final_v3_DisplayP3.tif"),
    previewItem(12, name: "2026-11-08_FPL05191_CaptureOne_Export_Final_v3_DisplayP3.tif"),
    previewItem(13, name: "2026-11-08_FPL05192_CaptureOne_Export_Final_v3_DisplayP3.tif"),
]

/// 真实三栏外壳 × 三种宽度。宽度用 `fixedLayout` 固定，切换 canvas 设备也能看。
@MainActor
private func shell(_ items: [ItemSummary], adjustments: Bool = false) -> some View {
    let (session, judge) = previewModels(items)
    return ProductRootView(session: session,
                           judge: judge,
                           showsCompactInspector: adjustments)
        .task { await session.connect() }
}

#Preview("Shell · 未连接 · 窄", traits: .fixedLayout(width: 402, height: 874)) {
    let (session, judge) = previewModels([])
    ProductRootView(session: session, judge: judge)
}

#Preview("Shell · 已连接 · 有素材 · 窄", traits: .fixedLayout(width: 402, height: 874)) {
    shell(previewItems)
}

#Preview("Shell · 已连接 · 调整栏展开 · 窄", traits: .fixedLayout(width: 402, height: 874)) {
    shell(previewItems, adjustments: true)
}

#Preview("Shell · 已连接 · 有素材 · 中", traits: .fixedLayout(width: 834, height: 1194)) {
    shell(previewItems)
}

#Preview("Shell · 已连接 · 有素材 · 宽", traits: .fixedLayout(width: 1366, height: 1024)) {
    shell(previewItems)
}

#Preview("Shell · 空批次 · 宽", traits: .fixedLayout(width: 1366, height: 1024)) {
    shell([])
}

#Preview("Shell · 长文件名 + 大字号 · 中", traits: .fixedLayout(width: 834, height: 1194)) {
    shell(stressedItems).environment(\.dynamicTypeSize, .accessibility1)
}
#endif
