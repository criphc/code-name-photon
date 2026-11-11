import Foundation
import SwiftUI
import Tokens
import ClientModel
import ClientKit
import ContractKit

/// 调整栏：直方图 + HDR 三个滑条 + cap stops picker（没有 cap 滑条）。
struct AdjustmentsView: View {
    let judge: JudgeModel
    let history: EditHistory
    /// 直方图高度。紧凑宽度下调整栏挤在底部，压矮它才放得下四个控件。
    var histogramHeight: CGFloat = 120

    @State private var histogram: HistogramData?
    /// 一次连续编辑开始前的草稿；结束时和当前草稿一起交给历史。
    @State private var editOrigin: RecipeDraft?

    var body: some View {
        VStack(spacing: 0) {
            HistogramView(data: histogram, hdrStops: capStops)
                .frame(height: histogramHeight)
                .background(PhotonPalette.placeholder.opacity(0.3), in: RoundedRectangle(cornerRadius: PhotonRadius.panel))
                .clipShape(RoundedRectangle(cornerRadius: PhotonRadius.panel))
                .padding(PhotonSpacing.panel)
            Divider()
            List {
                Section("HDR Adjustments") {
                    ParamRow(title: "Start",
                             identifier: "adjustments.start",
                             value: startBinding,
                             range: RecipeDraft.startRange,
                             defaultValue: defaults.start,
                             isEnabled: judge.isEditing,
                             onEditingChanged: editingChanged)
                    ParamRow(title: "Lift",
                             identifier: "adjustments.lift",
                             value: liftStopsBinding,
                             range: RecipeDraft.liftStopsRange,
                             defaultValue: defaults.liftStops,
                             isEnabled: judge.isEditing,
                             onEditingChanged: editingChanged)
                    ParamRow(title: "Transition",
                             identifier: "adjustments.transition",
                             value: transitionBinding,
                             range: RecipeDraft.transitionRange,
                             defaultValue: defaults.transition,
                             isEnabled: judge.isEditing,
                             onEditingChanged: editingChanged)
                    CapPicker(value: capBinding,
                              isEnabled: judge.isEditing,
                              onEditingChanged: editingChanged)
                }
            }
            .listStyle(.insetGrouped)
        }
        .task(id: histogramKey) {
            guard let image = judge.baseImage, let shape else {
                histogram = nil
                return
            }
            // 拖动滑条时先等一下：连续修改会取消上一个任务，避免每个 tick 都扫一遍像素。
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            histogram = await Task.detached(priority: .userInitiated) {
                HistogramData.compute(image: image, shape: shape)
            }.value
        }
    }

    /// 一次连续编辑的开始/结束。结束时有变化就记一步历史。
    private func editingChanged(_ began: Bool) {
        if began {
            editOrigin = judge.draft
            return
        }
        if let origin = editOrigin, let current = judge.draft, let id = judge.selectedItemID {
            history.recordEdit(itemID: id, before: origin, after: current)
        }
        editOrigin = nil
    }

    /// 身份 + 四个参数：任一变化就重算（`.task(id:)` 会取消上一次）。
    private var histogramKey: String {
        let identity = judge.baseIdentity.map { "\($0.itemID)-\($0.generation)" } ?? "none"
        let draft = judge.draft
        return "\(identity)|\(draft?.start ?? 0)|\(draft?.liftStops ?? 0)|\(draft?.transition ?? 0)|\(draft?.headroomCap ?? 0)"
    }

    private var shape: HighlightShape? {
        guard let draft = judge.draft else { return nil }
        return try? HighlightShape(recipe: Recipe.HDR(
            start: draft.start,
            liftStops: draft.liftStops,
            transition: draft.transition,
            headroomCap: draft.headroomCap
        ))
    }

    private var defaults: Recipe.HDR {
        judge.draft?.template.hdr ?? Recipe.HDR()
    }

    private var headroomCap: Double {
        judge.draft?.headroomCap ?? Recipe.HDR.defaultHeadroomCap
    }

    /// 直方图横轴 HDR 段的上限：跟着 cap 走，单位 stops。
    private var capStops: Float {
        Float(log2(max(headroomCap, 1)))
    }

    private var capBinding: Binding<Double> {
        Binding(get: { judge.draft?.headroomCap ?? Recipe.HDR.defaultHeadroomCap },
                set: { judge.setHeadroomCap($0) })
    }

    private var startBinding: Binding<Double> {
        Binding(get: { judge.draft?.start ?? defaults.start },
                set: { judge.setStart($0) })
    }

    private var liftStopsBinding: Binding<Double> {
        Binding(get: { judge.draft?.liftStops ?? defaults.liftStops },
                set: { judge.setLiftStops($0) })
    }

    private var transitionBinding: Binding<Double> {
        Binding(get: { judge.draft?.transition ?? defaults.transition },
                set: { judge.setTransition($0) })
    }
}

#Preview {
    AdjustmentsView(judge: JudgeModel(session: SessionModel()), history: EditHistory())
        .frame(width: 320, height: 600)
}
