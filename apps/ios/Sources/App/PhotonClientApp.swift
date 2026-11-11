import SwiftUI
import UIKit
import ClientModel
import ClientKit
import ContractKit

@main
struct PhotonClientApp: App {
    @State private var session: SessionModel
    @State private var judge: JudgeModel

    init() {
        let session = SessionModel()
        _session = State(initialValue: session)
        _judge = State(initialValue: JudgeModel(session: session))
    }

    var body: some Scene {
        WindowGroup {
            ProductRootView(session: session, judge: judge)
                .task { await session.start() }
        }
    }
}

/// 三栏：左栏连接 macOS server，detail 是画布 + 胶片条，调整栏挂 detail 的 inspector。
struct ProductRootView: View {
    let session: SessionModel
    let judge: JudgeModel
    /// 预览用：紧凑宽度下调整栏默认收起，这里可以一开始就展开。
    var showsCompactInspector = false

    @State private var visibility: NavigationSplitViewVisibility = .all
    /// 紧凑宽度下显示哪一列。连上之后把判图页顶上来，返回按钮由系统给。
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility,
                            preferredCompactColumn: $compactColumn) {
            ConnectionSetupView(session: session)
                .navigationTitle("Connection")
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            DevelopView(session: session,
                        judge: judge,
                        showsCompactInspector: showsCompactInspector)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: session.phase) { _, phase in
            // 紧凑宽度下连上就把判图页顶上来；常规宽度忽略这一项。
            // 自动重连也算：直接落在画布上，返回按钮回连接页。
            if phase == .connected { compactColumn = .detail }
        }
    }
}

struct DevelopView: View {
    let session: SessionModel
    let judge: JudgeModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showsInspector = true
    /// 紧凑宽度下调整栏贴在底部（和画布同屏），和 inspector 分开记：窄屏默认收起。
    @State private var showsCompactInspector: Bool
    @State private var compactInspectorHeight: CGFloat = 320
    @State private var compactInspectorDragStart: CGFloat?
    @State private var filmstripHeight: CGFloat = 175
    @State private var alert: JudgeAlert?
    @State private var history = EditHistory(animate: { withAnimation(.smooth(duration: 0.25), $0) })
    /// 应用内剪贴板：只存一份草稿，关掉 app 就没了。
    @State private var copiedDraft: RecipeDraft?

    init(session: SessionModel, judge: JudgeModel, showsCompactInspector: Bool = false) {
        self.session = session
        self.judge = judge
        _showsCompactInspector = State(initialValue: showsCompactInspector)
    }

    var body: some View {
        VStack(spacing: 0) {
            CanvasView(image: judge.baseImage,
                       identity: judge.baseIdentity,
                       uniforms: judge.renderUniforms)
                .safeAreaBar(edge: .bottom) {
                    StatusBarView(status: CanvasStatus.make(meta: judge.review?.meta,
                                                            displayHeadroom: judge.displayHeadroom,
                                                            isLoading: judge.phase == .loading))
                }
            // 状态条和胶片条同材质，没有这条线就找不到胶片条顶部的拖动区。
            // 调整栏占着下半屏时胶片条让位，把高度留给画布。
            if !hidesFilmstrip {
                Divider()
                FilmstripView(items: session.items,
                              thumbnails: session.thumbnails.images,
                              selectedID: judge.selectedItemID,
                              postingID: judge.phase == .posting ? judge.selectedItemID : nil,
                              height: $filmstripHeight,
                              onSelect: select)
                    .task(id: session.items) {
                        await session.thumbnails.prefetch(items: session.items, client: session.client)
                    }
            }
            if isCompact && showsCompactInspector {
                Divider()
                compactAdjustments
            }
        }
        // 每次编辑 +1，用来确认屏幕上是不是最新构建。
        .navigationTitle("0000002")
        .toolbarTitleAlignment(.leading)
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    Task { await history.undo(judge: judge) }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!history.canUndo || history.isApplying || !judge.isEditing)
                .help("Undo")
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("judge.undo")
                
                // 只有撤销过才出现：没得重做时不占位。
                if history.canRedo {
                    Button {
                        Task { await history.redo(judge: judge) }
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(history.isApplying || !judge.isEditing)
                    .help("Redo")
                    .accessibilityLabel("Redo")
                    .accessibilityIdentifier("judge.redo")
                    .transition(.opacity)
                }
            }
            
            ToolbarSpacer(.flexible)
            
            ToolbarItemGroup(placement: .automatic) {
                CompareControl(judge: judge, isEnabled: judge.draft != nil)

                Button {
                    if isCompact { showsCompactInspector.toggle() } else { showsInspector.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Adjustments")
                .accessibilityLabel("Adjustments")
                .accessibilityValue(isAdjustmentsShown ? "Open" : "Closed")
                .accessibilityIdentifier("judge.adjustments")

                Menu {
                    Button("Copy Adjustments") { copiedDraft = judge.draft }
                        .disabled(judge.draft == nil)
                    Button("Paste Adjustments", action: pasteAdjustments)
                        .disabled(copiedDraft == nil || judge.draft == nil || !judge.isEditing)
                    Divider()
                    // DEBUG-only：验收期临时项，验收后删掉。清掉缩略图缓存再重新拉一遍。
                    #if DEBUG
                    Button("Clear Thumbnail Cache") {
                        session.thumbnails.clear()
                        Task {
                            await session.thumbnails.prefetch(items: session.items,
                                                              client: session.client)
                        }
                    }
                    #endif
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("More")
                .accessibilityLabel("More")
                .accessibilityIdentifier("judge.more")
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await judge.postRecipe() }
                } label: {
                    if judge.phase == .posting {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!judge.canPost)
                .help("Submit")
                .accessibilityLabel("Submit")
                .accessibilityIdentifier("judge.submit")
            }
        }
        // 紧凑宽度下没有 inspector 列，调整栏走上面的底部面板。
        .inspector(isPresented: Binding(get: { showsInspector && !isCompact },
                                        set: { showsInspector = $0 })) {
            AdjustmentsView(judge: judge, history: history)
                .inspectorColumnWidth(min: 280, ideal: 360, max: 420)
        }
        // 显示器 headroom 没有变更通知，只能轮询；它同时是画布 uniform 和状态条的输入。
        .task {
            while !Task.isCancelled {
                judge.updateHeadroom(current: currentEDRHeadroom)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: judge.activeNotice) { _, notice in
            if let notice { alert = .notice(notice) }
        }
        .onChange(of: judge.postedMessage) { _, message in
            if let message { alert = .posted(postedText(message)) }
        }
        .onChange(of: judge.selectedItemID) { _, id in
            // 没有选中项 = 批次没了 / 被重置：历史里的 item 已经不可达。
            if id == nil { history.clear() }
        }
        .alert(alertTitle,
               isPresented: Binding(get: { alert != nil },
                                    set: { if !$0 { alert = nil } })) {
            if case .notice(let notice)? = alert, notice.canRetry {
                Button("Retry") {
                    Task { await judge.retry() }
                }
            }
            Button("OK", role: .cancel) {
                if case .notice? = alert { judge.dismissNotice() }
                alert = nil
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var alertTitle: String {
        switch alert {
        case .notice(let notice): notice.severity == .error ? "Couldn't finish" : "Notice"
        case .posted: "Submitted"
        case nil: ""
        }
    }

    private var alertMessage: String {
        switch alert {
        case .notice(let notice): notice.message
        case .posted(let message): message
        case nil: ""
        }
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// 调整栏此刻是不是展开的：常规宽度看 inspector 列，紧凑宽度看底部面板。
    private var isAdjustmentsShown: Bool {
        isCompact ? showsCompactInspector : showsInspector
    }

    /// 紧凑宽度下调整栏展开时，胶片条让位给画布。
    private var hidesFilmstrip: Bool {
        isCompact && showsCompactInspector
    }

    /// 紧凑宽度下的调整栏：贴着底部，画布留在上面；顶边 16pt 可拖动改高度。
    private var compactAdjustments: some View {
        AdjustmentsView(judge: judge, history: history, histogramHeight: 64)
            .frame(height: compactInspectorHeight)
            .overlay(alignment: .top) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = compactInspectorDragStart ?? compactInspectorHeight
                                compactInspectorDragStart = start
                                compactInspectorHeight = min(max(start - value.translation.height, 240), 560)
                            }
                            .onEnded { _ in compactInspectorDragStart = nil }
                    )
            }
    }

    private func select(_ id: String) {
        guard id != judge.selectedItemID else { return }
        history.recordSelect(from: judge.selectedItemID, to: id)
        Task { await judge.select(itemID: id) }
    }

    /// 粘贴是一步可撤销的编辑：先记下当前草稿，写完再记一步。
    private func pasteAdjustments() {
        guard let copiedDraft, let before = judge.draft, let id = judge.selectedItemID else { return }
        history.apply(copiedDraft, to: judge)
        if let after = judge.draft {
            history.recordEdit(itemID: id, before: before, after: after)
        }
    }

    /// 提交成功的正文：先报是哪张图、哪次渲染，再是模型给的那句话。
    private func postedText(_ message: String) -> String {
        let label = [judge.selectedItem?.name, judge.lastRenderKey.map { String($0.prefix(8)) }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return label.isEmpty ? message : "\(label)\n\(message)"
    }

    /// 屏幕当前的 EDR headroom。`UIScreen.main` 已废弃，从窗口场景取。
    private var currentEDRHeadroom: Float {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
        return Float(screen?.currentEDRHeadroom ?? 1)
    }
}

private enum JudgeAlert: Identifiable {
    case notice(Notice)
    case posted(String)

    var id: String {
        switch self {
        case .notice(let notice): "notice-\(notice.id)"
        case .posted(let message): "posted-\(message)"
        }
    }
}

#Preview {
    let session = SessionModel()
    return ProductRootView(session: session, judge: JudgeModel(session: session))
}
