import Foundation
import Observation
import ClientKit
import ContractKit

/// 调整历史：一条全局时间线，编辑和「切换图片」都算一步。
///
/// 这样撤销能跨图片回退（Capture One 的行为）：编辑 A → 切到 B → 编辑 B，
/// 连按三次撤销依次是「撤销 B 的编辑」「切回 A」「撤销 A 的编辑」。
///
/// 语义是**严格按时间回退**：切图本身也是一步。所以「编辑 A → 切到 B → 编辑 B →
/// 切回 A → 撤销」会先切回 B，而不是撤销 A 的编辑。
///
/// 栈顶动作总是属于当前 item —— 每次切换都记了一步，所以撤销时不用先找对 item。
/// 历史只存草稿快照，不复制模型状态。
@MainActor
@Observable
public final class EditHistory {
    public enum Step: Equatable {
        case edit(itemID: String, before: RecipeDraft, after: RecipeDraft)
        case select(from: String, to: String)
    }

    public private(set) var undoSteps: [Step] = []
    public private(set) var redoSteps: [Step] = []
    /// 正在应用一步（可能要先切图，是异步的）。期间按钮禁用，免得连点把两步叠在一起。
    public private(set) var isApplying = false

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    /// redo 按钮的显隐由 `redoSteps` 驱动。动画是视图的事，这里只调注入的闭包，
    /// 这样包本身不依赖 SwiftUI。
    @ObservationIgnored
    private let animate: (@escaping () -> Void) -> Void

    public init(animate: @escaping (@escaping () -> Void) -> Void = { $0() }) {
        self.animate = animate
    }

    // MARK: - 记录

    /// 一次连续编辑（一次拖动、一次滚轮会话、一次复位、一次粘贴）结束后调用。
    public func recordEdit(itemID: String, before: RecipeDraft, after: RecipeDraft) {
        guard before != after else { return }
        push(.edit(itemID: itemID, before: before, after: after))
    }

    /// 只记「从一张图切到另一张」。第一次选中（from == nil）不是可撤销的导航步骤 ——
    /// 撤销它等于要求「取消选中」，模型里没有这个动作。
    public func recordSelect(from: String?, to: String) {
        guard let from, from != to else { return }
        push(.select(from: from, to: to))
    }

    public func clear() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }

    private func push(_ step: Step) {
        undoSteps.append(step)
        animate { self.redoSteps.removeAll() }
    }

    // MARK: - 应用

    public func undo(judge: JudgeModel) async {
        guard !isApplying, let step = undoSteps.popLast() else { return }
        animate { self.redoSteps.append(step) }
        isApplying = true
        defer { isApplying = false }
        await apply(step, forward: false, judge: judge)
    }

    public func redo(judge: JudgeModel) async {
        guard !isApplying else { return }
        var popped: Step?
        animate { popped = self.redoSteps.popLast() }
        guard let step = popped else { return }
        undoSteps.append(step)
        isApplying = true
        defer { isApplying = false }
        await apply(step, forward: true, judge: judge)
    }

    /// 把一份草稿写回模型。撤销、重做和粘贴共用。
    public func apply(_ draft: RecipeDraft, to judge: JudgeModel) {
        judge.setStart(draft.start)
        judge.setLiftStops(draft.liftStops)
        judge.setTransition(draft.transition)
        judge.setHeadroomCap(draft.headroomCap)
    }

    private func apply(_ step: Step, forward: Bool, judge: JudgeModel) async {
        switch step {
        case .edit(let itemID, let before, let after):
            // 正常情况下栈顶动作就属于当前 item；对不上时先切回去。
            if judge.selectedItemID != itemID {
                await judge.select(itemID: itemID)
            }
            guard judge.selectedItemID == itemID else { return }
            apply(forward ? after : before, to: judge)
        case .select(let from, let to):
            let target = forward ? to : from
            guard judge.selectedItemID != target else { return }
            await judge.select(itemID: target)
        }
    }
}
