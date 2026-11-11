import ClientKit
import ContractKit
import Foundation
import Testing
@testable import ClientModel

@MainActor
@Suite("Edit history")
struct EditHistoryTests {
    private var recipe: Recipe {
        Recipe(
            source: Recipe.Source(path: "/b/x.tif",
                                  sha256: String(repeating: "a", count: 64),
                                  width: 4, height: 4),
            versions: Recipe.Versions(encoder: "test"),
            created: "2026-11-08T00:00:00Z"
        )
    }

    /// 一次连续编辑：先取 before，写值，再取 after 记一步。
    private func edit(_ judge: JudgeModel, _ history: EditHistory, start: Double) {
        guard let before = judge.draft, let id = judge.selectedItemID else { return }
        judge.setStart(start)
        guard let after = judge.draft else { return }
        history.recordEdit(itemID: id, before: before, after: after)
    }

    private func select(_ id: String, _ judge: JudgeModel, _ history: EditHistory) async {
        history.recordSelect(from: judge.selectedItemID, to: id)
        await judge.select(itemID: id)
    }

    @Test("only a real change is a step")
    func recordsOnlyChanges() {
        let history = EditHistory()
        let base = RecipeDraft(defaults: recipe)
        var edited = base
        edited.start = 0.5

        history.recordEdit(itemID: "a", before: base, after: base)
        #expect(!history.canUndo)

        history.recordEdit(itemID: "a", before: base, after: edited)
        #expect(history.undoSteps.count == 1)

        // 选同一张不是一步。
        history.recordSelect(from: "a", to: "a")
        #expect(history.undoSteps.count == 1)
    }

    @Test("undo walks back across images")
    func undoAcrossImages() async throws {
        let harness = try Harness()
        await harness.connect()
        let judge = harness.judge
        let history = EditHistory()

        await select(Fixtures.idA, judge, history)
        let a0 = try #require(judge.draft)
        edit(judge, history, start: 0.5)

        await select(Fixtures.idB, judge, history)
        let b0 = try #require(judge.draft)
        edit(judge, history, start: 0.4)

        #expect(history.undoSteps.count == 3)

        // 1. 撤销 B 的编辑，还停在 B。
        await history.undo(judge: judge)
        #expect(judge.selectedItemID == Fixtures.idB)
        #expect(judge.draft?.start == b0.start)

        // 2. 切回 A。
        await history.undo(judge: judge)
        #expect(judge.selectedItemID == Fixtures.idA)

        // 3. 撤销 A 的编辑。
        await history.undo(judge: judge)
        #expect(judge.draft?.start == a0.start)
        #expect(!history.canUndo)
        #expect(history.canRedo)
    }

    @Test("switching back then undoing returns to the previous image")
    func strictTimeline() async throws {
        let harness = try Harness()
        await harness.connect()
        let judge = harness.judge
        let history = EditHistory()

        await select(Fixtures.idA, judge, history)
        edit(judge, history, start: 0.5)
        await select(Fixtures.idB, judge, history)
        edit(judge, history, start: 0.4)

        // 手动切回 A：这本身也是一步。
        await select(Fixtures.idA, judge, history)
        #expect(judge.selectedItemID == Fixtures.idA)

        // 严格时间线：撤销先切回 B，A 的编辑还在。
        await history.undo(judge: judge)
        #expect(judge.selectedItemID == Fixtures.idB)
        #expect(judge.draft?.start == 0.4)
    }

    @Test("a new edit drops the redo stack")
    func newEditDropsRedo() async throws {
        let harness = try Harness()
        await harness.connect()
        let judge = harness.judge
        let history = EditHistory()

        await select(Fixtures.idA, judge, history)
        edit(judge, history, start: 0.5)
        await history.undo(judge: judge)
        #expect(history.canRedo)

        edit(judge, history, start: 0.3)
        #expect(!history.canRedo)
    }

    @Test("redo replays the edit it undid")
    func redoReplays() async throws {
        let harness = try Harness()
        await harness.connect()
        let judge = harness.judge
        let history = EditHistory()

        await select(Fixtures.idA, judge, history)
        edit(judge, history, start: 0.5)
        await history.undo(judge: judge)
        #expect(judge.draft?.start != 0.5)

        await history.redo(judge: judge)
        #expect(judge.draft?.start == 0.5)
        #expect(!history.canRedo)
    }

    @Test("clear empties both stacks")
    func clearEmpties() async throws {
        let harness = try Harness()
        await harness.connect()
        let judge = harness.judge
        let history = EditHistory()

        await select(Fixtures.idA, judge, history)
        edit(judge, history, start: 0.5)
        await history.undo(judge: judge)
        #expect(history.canUndo || history.canRedo)

        history.clear()
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }
}
