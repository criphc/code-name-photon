import Foundation
import Testing
import ClientKit
import ContractKit
@testable import ClientModel

// MARK: - 409 source_changed

@Suite("JudgeModel 409 re-judge")
@MainActor
struct JudgeModelRejudgeTests {
    /// A renamed/re-exported item: same path and name, new id (the server's id is the source hash).
    private static let itemA2 = Fixtures.item(
        id: Fixtures.idA2,
        name: Fixtures.nameA,
        path: Fixtures.pathA
    )

    private func failingPostHarness() async throws -> Harness {
        let harness = try Harness(items: [Fixtures.itemA])
        await harness.connect()
        let png = harness.png
        let itemA2 = Self.itemA2
        harness.client.listHandler = { [itemA2] }
        harness.client.prepareHandler = { id in
            if id == Fixtures.idA2 {
                return Fixtures.prepareResponse(for: itemA2, png: png)
            }
            if id == Fixtures.idA {
                return Fixtures.prepareResponse(for: Fixtures.itemA, png: png)
            }
            throw ClientError.notFound
        }
        harness.client.previewHandler = { _, _ in png }
        harness.client.postHandler = { _, _ in throw ClientError.sourceChanged }
        await harness.judge.select(itemID: Fixtures.idA)
        return harness
    }

    @Test("the first 409 refreshes the batch and judges the new incarnation")
    func automaticRejudge() async throws {
        let harness = try await failingPostHarness()
        let judge = harness.judge

        await judge.postRecipe()

        #expect(judge.phase == .judging)
        #expect(judge.notice?.message == "the source was re-exported; judge it again")
        #expect(judge.notice?.sourceChanged == true)
        #expect(judge.notice?.canDismiss == false)
        #expect(judge.review?.receipt == nil)

        await waitUntil("automatic rejudge") {
            judge.selectedItemID == Fixtures.idA2 && judge.phase == .judging
        }

        #expect(judge.selectedItem == Self.itemA2)
        #expect(judge.review?.item.id == Fixtures.idA2)
        #expect(judge.review?.receipt == nil)
        #expect(judge.notice == nil)
        #expect(harness.client.callCount(.prepare(Fixtures.idA2)) == 1)
        // The old base bytes and draft are discarded: a fresh draft from the new defaults.
        let review = try #require(judge.review)
        #expect(review.draft == RecipeDraft(defaults: review.meta.recipeDefaults))
    }

    @Test("a second 409 stops the automatic attempts and asks for a refresh")
    func secondSourceChangeStops() async throws {
        let harness = try await failingPostHarness()
        let judge = harness.judge
        let png = harness.png
        let itemA2 = Self.itemA2
        harness.client.prepareHandler = { id in
            if id == Fixtures.idA2 { throw ClientError.sourceChanged }
            return Fixtures.prepareResponse(for: Fixtures.itemA, png: png)
        }

        await judge.postRecipe()
        await waitUntil("second 409 stop") {
            judge.notice?.message == "the source keeps changing; refresh the batch and judge it again"
        }

        #expect(judge.phase == .error)
        #expect(judge.review == nil)
        #expect(judge.notice?.severity == .warning)
        #expect(judge.notice?.sourceChanged == true)
        #expect(judge.notice?.canDismiss == false)
        #expect(judge.notice?.canRetry == true)
        // One automatic re-prepare of the new id, then stop: no download loop.
        #expect(harness.client.callCount(.prepare(Fixtures.idA2)) == 1)

        harness.client.listHandler = { [itemA2] }
        await judge.retry()

        #expect(judge.phase == .idle)
        #expect(judge.notice == nil)
        #expect(judge.review == nil)
    }
}

// MARK: - 404

@Suite("JudgeModel 404")
@MainActor
struct JudgeModelNotFoundTests {
    @Test("a missing item clears the judge and refreshes the batch")
    func notFoundDuringSelect() async throws {
        let harness = try Harness()
        await harness.connect()
        harness.client.prepareHandler = { _ in throw ClientError.notFound }

        await harness.judge.select(itemID: Fixtures.idA)

        #expect(harness.judge.phase == .error)
        #expect(harness.judge.review == nil)
        #expect(harness.judge.notice?.severity == .warning)
        #expect(harness.judge.notice?.canRetry == true)
        #expect(harness.judge.notice?.message == ClientError.notFound.userMessage)

        harness.client.listHandler = { [Fixtures.itemB] }
        await waitUntil("404 refresh") {
            harness.session.items.map(\.id) == [Fixtures.idB]
        }
        await waitUntil("selection dropped") { harness.judge.selectedItemID == nil }

        #expect(harness.judge.phase == .idle)
        #expect(harness.judge.selectedItem == nil)
        #expect(harness.session.phase == .connected)
    }
}

// MARK: - 401

@Suite("JudgeModel 401")
@MainActor
struct JudgeModelUnauthorizedTests {
    @Test("a 401 during a base load returns to the settings and resets the judge")
    func unauthorizedDuringSelect() async throws {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        harness.client.prepareHandler = { _ in throw ClientError.unauthorized }

        await harness.judge.select(itemID: Fixtures.idB)

        #expect(harness.session.phase == .unconfigured)
        #expect(harness.session.client == nil)
        #expect(harness.session.items.isEmpty)
        #expect(harness.session.notice?.severity == .error)
        #expect(harness.session.notice?.message == ClientError.unauthorized.userMessage)
        #expect(harness.judge.phase == .idle)
        #expect(harness.judge.review == nil)
        #expect(harness.judge.selectedItemID == nil)
        #expect(harness.judge.notice == nil)
        #expect(!harness.judge.isShowingJudge)
    }

    @Test("a 401 during a POST keeps nothing on screen")
    func unauthorizedDuringPost() async throws {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        harness.client.postHandler = { _, _ in throw ClientError.unauthorized }

        await harness.judge.postRecipe()

        #expect(harness.session.phase == .unconfigured)
        #expect(harness.session.client == nil)
        #expect(harness.judge.phase == .idle)
        #expect(harness.judge.review == nil)
        #expect(harness.judge.selectedItemID == nil)
    }
}

// MARK: - Reset

@Suite("JudgeModel reset")
@MainActor
struct JudgeModelResetTests {
    @Test("disconnect clears the judge, its aids and the review cache")
    func disconnectResetsJudge() async throws {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        harness.judge.setStart(0.4)
        harness.judge.beginCompare()
        harness.judge.toggleOverlay()
        harness.judge.updateHeadroom(current: 2)

        harness.session.disconnect()

        #expect(harness.session.phase == .unconfigured)
        #expect(harness.session.client == nil)
        #expect(harness.session.items.isEmpty)
        #expect(harness.judge.phase == .idle)
        #expect(harness.judge.review == nil)
        #expect(harness.judge.selectedItemID == nil)
        #expect(harness.judge.selectedItem == nil)
        #expect(harness.judge.loadProgress == nil)
        #expect(!harness.judge.comparing)
        #expect(!harness.judge.overlayOn)
        #expect(harness.judge.notice == nil)
        #expect(!harness.judge.isShowingJudge)
        #expect(!harness.judge.canPost)

        // The cache is gone: a later reconnect re-downloads instead of restoring stale pixels.
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        #expect(harness.judge.phase == .judging)
        #expect(harness.client.callCount(.prepare(Fixtures.idA)) == 2)
    }

    @Test("reset is idempotent and also clears a posted receipt")
    func resetClearsReceipt() async throws {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        await harness.judge.postRecipe()
        #expect(harness.judge.phase == .posted)

        harness.judge.reset()
        harness.judge.reset()

        #expect(harness.judge.phase == .idle)
        #expect(harness.judge.review == nil)
        #expect(harness.judge.selectedItemID == nil)
        #expect(harness.judge.postedMessage == nil)
        #expect(harness.judge.lastRenderKey == nil)
        #expect(harness.judge.notice == nil)
    }
}
