import SwiftUI
import ClientModel

/// Compare 的三段：A 不生效 / B SDR 底板 / C 假色。
private enum CompareStage: Equatable {
    case authored
    case sdr
    case falseColour

    var icon: String {
        switch self {
        case .authored: "square.2.layers.3d"
        case .sdr: "square.2.layers.3d.bottom.filled"
        case .falseColour: "square.2.layers.3d.top.filled"
        }
    }

    /// 按住期间预览的落点：松手会到的状态，所以松手不跳变。
    var landing: CompareStage {
        switch self {
        case .authored: .sdr
        case .sdr: .authored
        case .falseColour: .authored
        }
    }

    /// VoiceOver 读到的当前段。
    var name: String {
        switch self {
        case .authored: "HDR"
        case .sdr: "SDR base"
        case .falseColour: "False colour"
        }
    }

    /// 双击目标按第一下之前的状态查表；C 只能从 A 进入，所以 C 的目标到不了。
    var doubleTapTarget: CompareStage {
        switch self {
        case .authored: .falseColour
        case .sdr: .authored
        case .falseColour: .authored
        }
    }
}

/// 三段式 Compare 按钮。
///
/// - 轻点：A ↔ B；从 A 双击进 C；C 里轻点、长按、双击都回到 A，随后冷却 0.3s。
/// - 按住：预览松手会落到的另一段；长按松手不提交。
/// - 拖出按钮：取消。
///
/// 判定层用两个手势：长按手势只在按下时给信号（工具栏里它是唯一准时的），拖拽手势只在
/// 释放时给信号（带释放点，用来判断拖出）。`Button` 留空，只借它的系统外观、按压高亮和
/// disabled。按住期间模型里放的是预览，真正的持久状态暂存在 `staged`。
struct CompareControl: View {
    let judge: JudgeModel
    let isEnabled: Bool

    @State private var pressing = false
    @State private var pressedAt: Date?
    @State private var staged: CompareStage?
    /// 这一串连击第一下之前的状态：双击目标按它查表，不按第二下时的状态。
    @State private var tapOrigin: CompareStage?
    @State private var lastTapEndedAt: Date?
    /// 离开 C 之后的冷却：这期间的释放只取消预览，不提交。
    @State private var ignoresCommitsUntil: Date?
    @State private var size: CGSize = .zero

    private static let holdDuration: TimeInterval = 0.35
    private static let doubleTapWindow: TimeInterval = 0.30
    private static let cooldown: TimeInterval = 0.30

    var body: some View {
        Button {} label: {
            Image(systemName: shown.icon)
        }
        .disabled(!isEnabled)
        .help("Compare")
        .accessibilityLabel("Compare")
        .accessibilityValue(committed.name)
        .accessibilityHint("Switches between HDR and the SDR base")
        .accessibilityIdentifier("judge.compare")
        .accessibilityAction(.default, activate)
        // 假色在 VoiceOver 里没有"连点两下"的入口，单独给一个命名动作。
        .accessibilityAction(named: "False colour") {
            guard isEnabled else { return }
            apply(committed == .falseColour ? .authored : .falseColour)
        }
        // 按下用长按手势的 pressing：它在触摸落下的那一拍就翻转（实测 +13ms）；
        // 工具栏里的 DragGesture 要等手指移动才识别，按下不动就没有回调（实测 +0.8s）。
        .onLongPressGesture(minimumDuration: 0,
                            maximumDistance: .infinity,
                            perform: {},
                            onPressingChanged: { pressing in
            if pressing { beginPress() }
        })
        // 释放用拖拽手势的 onEnded：它在松手时准时回调，且带释放点（用来判断拖出）。
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { endPress(at: $0.location) },
            isEnabled: isEnabled
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { abandonPress() }
        }
    }

    // MARK: - 状态

    /// 持久状态：不在按住期间就直接读模型，按住期间读按下前的快照。
    private var committed: CompareStage {
        if let staged { return staged }
        if judge.overlayOn { return .falseColour }
        if judge.comparing { return .sdr }
        return .authored
    }

    private var shown: CompareStage {
        pressing ? committed.landing : committed
    }

    // MARK: - 按下 / 释放

    private func beginPress() {
        guard isEnabled else { return }
        // 上一次按下没等到释放（手势被系统取消）：先把预览撤回，再开始这一下。
        if pressing {
            let current = staged ?? committed
            clearPress()
            apply(current)
        }
        let now = Date.now
        let current = committed
        pressing = true
        pressedAt = now
        staged = current
        // 距上一次短按释放够近 = 这一下是双击的第二下，起点沿用第一下的。
        if lastTapEndedAt.map({ now.timeIntervalSince($0) < Self.doubleTapWindow }) != true {
            tapOrigin = current
        }
        apply(current.landing)
    }

    private func endPress(at location: CGPoint) {
        guard pressing else { return }
        let now = Date.now
        let current = staged ?? committed
        let held = now.timeIntervalSince(pressedAt ?? now)
        clearPress()

        // 按住中途被禁用：丢掉这一下，模型自己已经回到确定状态。
        guard isEnabled else {
            tapOrigin = nil
            lastTapEndedAt = nil
            return
        }

        // C 优先：轻点、长按、双击、拖出都一样，都落回 A，并冷却，免得同一串点击又滑进 B。
        if current == .falseColour {
            tapOrigin = nil
            lastTapEndedAt = nil
            ignoresCommitsUntil = now.addingTimeInterval(Self.cooldown)
            apply(.authored)
            return
        }

        // 拖出按钮：取消，回到按下前的状态，并打断这一串连击。
        guard isInside(location) else {
            tapOrigin = nil
            lastTapEndedAt = nil
            apply(current)
            return
        }

        // 冷却期内只取消预览。
        if isCoolingDown(now) {
            tapOrigin = nil
            lastTapEndedAt = nil
            apply(current)
            return
        }

        // 长按：只取消预览。
        if held >= Self.holdDuration {
            tapOrigin = nil
            lastTapEndedAt = nil
            apply(current)
            return
        }

        // 短按：距上一次短按释放够近就是双击，目标按这一串起点的状态查表。
        if let lastTapEndedAt, let origin = tapOrigin,
           now.timeIntervalSince(lastTapEndedAt) < Self.doubleTapWindow {
            self.tapOrigin = nil
            self.lastTapEndedAt = nil
            apply(origin.doubleTapTarget)
        } else {
            lastTapEndedAt = now
            apply(current.landing)
        }
    }

    /// 无障碍激活：等价于一次单点，没有按住的预览阶段。
    private func activate() {
        let now = Date.now
        guard isEnabled, !pressing, !isCoolingDown(now) else { return }
        tapOrigin = nil
        lastTapEndedAt = nil
        if committed == .falseColour {
            ignoresCommitsUntil = now.addingTimeInterval(Self.cooldown)
            apply(.authored)
        } else {
            apply(committed.landing)
        }
    }

    /// 按钮在按住中途被禁用：丢掉这一下，模型自己已经回到确定状态。
    private func abandonPress() {
        guard pressing else { return }
        clearPress()
        tapOrigin = nil
        lastTapEndedAt = nil
    }

    private func clearPress() {
        pressing = false
        pressedAt = nil
        staged = nil
    }

    private func isCoolingDown(_ now: Date) -> Bool {
        guard let ignoresCommitsUntil else { return false }
        return now < ignoresCommitsUntil
    }

    /// 尺寸还没量到时按「在按钮内」处理。
    private func isInside(_ point: CGPoint) -> Bool {
        guard size != .zero else { return true }
        return CGRect(origin: .zero, size: size).contains(point)
    }

    // MARK: - 写回模型

    private func apply(_ stage: CompareStage) {
        switch stage {
        case .authored:
            judge.endCompare()
            if judge.overlayOn { judge.toggleOverlay() }
        case .sdr:
            if judge.overlayOn { judge.toggleOverlay() }
            judge.beginCompare()
        case .falseColour:
            judge.endCompare()
            if !judge.overlayOn { judge.toggleOverlay() }
        }
    }
}

#Preview("Compare control") {
    @Previewable @State var judge = JudgeModel(session: SessionModel())
    NavigationStack {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    CompareControl(judge: judge, isEnabled: true)
                }
            }
    }
}
