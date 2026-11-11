import Foundation
import Testing
import ClientKit
import ContractKit
@testable import ClientModel

// MARK: - Load

@Suite("JudgeModel base load")
@MainActor
struct JudgeModelLoadTests {
    @Test("select prepares, downloads and decodes the base")
    func loadSuccess() async throws {
        let harness = try Harness()
        await harness.connect()

        await harness.judge.select(itemID: Fixtures.idA)

        #expect(harness.judge.phase == .judging)
        let review = try #require(harness.judge.review)
        #expect(review.item.id == Fixtures.idA)
        #expect(review.baseIdentity.itemID == Fixtures.idA)
        #expect(review.baseIdentity.generation == 1)
        #expect(review.image.size == PixelSize(width: 4, height: 4))
        #expect(harness.judge.baseImage?.size == PixelSize(width: 4, height: 4))
        #expect(harness.judge.baseIdentity == review.baseIdentity)
        #expect(harness.judge.draft == RecipeDraft(defaults: review.meta.recipeDefaults))
        #expect(harness.judge.loadProgress == nil)
        #expect(harness.judge.selectedItem?.id == Fixtures.idA)
        #expect(harness.judge.isShowingJudge)
        #expect(harness.judge.canPost)
        #expect(harness.judge.isEditing)
        #expect(harness.judge.notice == nil)
        #expect(harness.client.calls() == [
            .health, .listItems, .prepare(Fixtures.idA), .preview(Fixtures.idA),
        ])
    }

    @Test("download progress is published while the bytes are in flight")
    func loadProgress() async throws {
        let harness = try Harness()
        await harness.connect()
        let gate = Gate()
        let png = harness.png
        harness.client.previewHandler = { _, progress in
            progress?(0.25)
            await gate.wait()
            return png
        }

        let task = Task { await harness.judge.select(itemID: Fixtures.idA) }
        await waitUntil("download progress") { harness.judge.loadProgress == 0.25 }

        #expect(harness.judge.phase == .loading)
        #expect(harness.judge.isShowingJudge)
        #expect(harness.judge.review == nil)

        await gate.open()
        await task.value

        #expect(harness.judge.phase == .judging)
        #expect(harness.judge.loadProgress == nil)
        #expect(harness.judge.review != nil)
    }

    @Test("a failed prepare shows a retryable judge error")
    func loadErrorAndRetry() async throws {
        let harness = try Harness()
        await harness.connect()
        harness.client.prepareHandler = { _ in
            throw ClientError.prepareFailed(message: "render failed")
        }

        await harness.judge.select(itemID: Fixtures.idA)

        #expect(harness.judge.phase == .error)
        #expect(harness.judge.review == nil)
        #expect(harness.judge.loadProgress == nil)
        #expect(harness.judge.selectedItemID == Fixtures.idA)
        #expect(!harness.judge.isShowingJudge)
        #expect(harness.judge.notice?.severity == .error)
        #expect(harness.judge.notice?.canRetry == true)
        #expect(
            harness.judge.notice?.message
                == ClientError.prepareFailed(message: "render failed").userMessage
        )

        let png = harness.png
        harness.client.prepareHandler = { id in
            guard id == Fixtures.idA else { throw ClientError.notFound }
            return Fixtures.prepareResponse(for: Fixtures.itemA, png: png)
        }
        await harness.judge.retry()

        #expect(harness.judge.phase == .judging)
        #expect(harness.judge.review?.item.id == Fixtures.idA)
        #expect(harness.judge.notice == nil)
    }

    @Test("a stale download cannot overwrite a newer selection")
    func staleLoadIsDiscarded() async throws {
        let harness = try Harness()
        await harness.connect()
        let gate = Gate()
        let png = harness.png
        harness.client.previewHandler = { id, _ in
            if id == Fixtures.idA { await gate.wait() }
            return png
        }

        let slow = Task { await harness.judge.select(itemID: Fixtures.idA) }
        await waitUntil("first load in flight") { harness.judge.phase == .loading }

        await harness.judge.select(itemID: Fixtures.idB)
        #expect(harness.judge.selectedItemID == Fixtures.idB)
        #expect(harness.judge.phase == .judging)

        await gate.open()
        await slow.value

        #expect(harness.judge.selectedItemID == Fixtures.idB)
        #expect(harness.judge.review?.item.id == Fixtures.idB)
        #expect(harness.judge.phase == .judging)
    }

    @Test("reselecting a cached item restores its pixels, draft and identity")
    func cachedReviewRestore() async throws {
        let harness = try Harness()
        await harness.connect()

        await harness.judge.select(itemID: Fixtures.idA)
        harness.judge.setStart(0.4)
        let identityA = try #require(harness.judge.baseIdentity)

        await harness.judge.select(itemID: Fixtures.idB)
        let identityB = try #require(harness.judge.baseIdentity)
        #expect(identityB.itemID == Fixtures.idB)
        #expect(identityB.generation == identityA.generation + 1)

        await harness.judge.select(itemID: Fixtures.idA)

        #expect(harness.judge.phase == .judging)
        #expect(harness.judge.draft?.start == 0.4)
        #expect(harness.judge.baseIdentity == identityA)
        #expect(harness.client.callCount(.prepare(Fixtures.idA)) == 1)
    }
}

// MARK: - Draft / judging aids

@Suite("JudgeModel draft and judging aids")
@MainActor
struct JudgeModelDraftTests {
    private func loadedHarness() async throws -> Harness {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        return harness
    }

    @Test("a fresh draft is clean and copied into the cache")
    func freshDraft() async throws {
        let harness = try await loadedHarness()

        #expect(!harness.judge.isDirty)
        #expect(harness.judge.draft?.isDirty == false)
        #expect(harness.judge.canPost)
        #expect(harness.judge.isEditing)
        #expect(harness.judge.postedMessage == nil)
        #expect(harness.judge.editedMessage == nil)
    }

    @Test("control values are clamped to the recipe ranges")
    func controlClamping() async throws {
        let harness = try await loadedHarness()
        let judge = harness.judge

        judge.setStart(-5)
        #expect(judge.draft?.start == RecipeDraft.startRange.lowerBound)
        judge.setStart(5)
        #expect(judge.draft?.start == RecipeDraft.startRange.upperBound)
        judge.setStart(.nan)
        #expect(judge.draft?.start == RecipeDraft.startRange.lowerBound)

        judge.setLiftStops(-1)
        #expect(judge.draft?.liftStops == RecipeDraft.liftStopsRange.lowerBound)
        judge.setLiftStops(10)
        #expect(judge.draft?.liftStops == RecipeDraft.liftStopsRange.upperBound)
        judge.setLiftStops(.infinity)
        #expect(judge.draft?.liftStops == RecipeDraft.liftStopsRange.lowerBound)

        judge.setTransition(0)
        #expect(judge.draft?.transition == RecipeDraft.transitionRange.lowerBound)
        judge.setTransition(2)
        #expect(judge.draft?.transition == RecipeDraft.transitionRange.upperBound)

        judge.setHeadroomCap(9)
        #expect(judge.draft?.headroomCap == RecipeDraft.headroomCapRange.upperBound)
        judge.setHeadroomCap(0.5)
        #expect(judge.draft?.headroomCap == RecipeDraft.headroomCapRange.lowerBound)
        judge.setHeadroomCap(.nan)
        #expect(judge.draft?.headroomCap == RecipeDraft.headroomCapRange.lowerBound)

        judge.setStart(0.5)
        #expect(judge.isDirty)
        #expect(judge.review?.draft == judge.draft)
    }

    @Test("the cap picker moves the uniform")
    func headroomCapControl() async throws {
        let judge = try await loadedHarness().judge
        #expect(judge.draft?.headroomCap == Recipe.HDR.defaultHeadroomCap)

        judge.setHeadroomCap(2)
        #expect(judge.draft?.headroomCap == 2)
        #expect(judge.renderUniforms.headroomCap == 2)
        #expect(judge.isDirty)

        judge.updateHeadroom(current: 2.4)
    }

    @Test("drafts survive switching items")
    func perItemDrafts() async throws {
        let harness = try await loadedHarness()
        harness.judge.setStart(0.4)
        harness.judge.setLiftStops(2)

        await harness.judge.select(itemID: Fixtures.idB)
        #expect(!harness.judge.isDirty)
        #expect(harness.judge.draft?.start == RecipeDraft(defaults: Fixtures.metadata(for: Fixtures.itemB, png: harness.png).recipeDefaults).start)

        await harness.judge.select(itemID: Fixtures.idA)
        #expect(harness.judge.draft?.start == 0.4)
        #expect(harness.judge.draft?.liftStops == 2)
    }

    @Test("compare, overlay and headroom drive the uniforms")
    func judgingAids() async throws {
        let harness = try await loadedHarness()
        let judge = harness.judge

        #expect(judge.renderMode == .authored)

        judge.beginCompare()
        #expect(judge.comparing)
        #expect(judge.renderMode == .compare)

        judge.toggleOverlay()
        #expect(judge.overlayOn)
        #expect(judge.renderMode == .overlay)

        judge.endCompare()
        #expect(!judge.comparing)
        #expect(judge.renderMode == .overlay)

        judge.toggleOverlay()
        #expect(judge.renderMode == .authored)

        judge.setStart(0.5)
        #expect(judge.renderUniforms.start == 0.5)
        #expect(judge.renderUniforms.headroomCap == Float(Recipe.HDR.defaultHeadroomCap))
        #expect(judge.renderUniforms.mode == JudgeRenderMode.authored.rawValue)

        judge.updateHeadroom(current: 0.5)
        #expect(judge.displayHeadroom == 1)
        judge.updateHeadroom(current: 2.4)
        #expect(judge.displayHeadroom == 2.4)
        judge.updateHeadroom(current: .nan)
        #expect(judge.displayHeadroom == 2.4)
        #expect(judge.renderUniforms.displayHeadroom == 2.4)
    }
}

// MARK: - POST

@Suite("JudgeModel post")
@MainActor
struct JudgeModelPostTests {
    private func postedHarness() async throws -> Harness {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        return harness
    }

    @Test("a successful POST stores the server receipt and claims the look was sent")
    func postSuccess() async throws {
        let harness = try await postedHarness()
        let judge = harness.judge
        judge.setStart(0.5)

        await judge.postRecipe()

        #expect(judge.phase == .posted)
        #expect(!judge.isDirty)
        #expect(judge.postedMessage == "recipe sent to the Mac; M4 writes the HEIC")
        #expect(judge.lastRenderKey == "render-key-\(Fixtures.idA.prefix(12))")
        #expect(judge.editedMessage == nil)

        let receipt = try #require(judge.review?.receipt)
        #expect(receipt.renderKey == "render-key-\(Fixtures.idA.prefix(12))")
        #expect(receipt.draft == judge.draft)

        let recipes = harness.client.postedRecipes()
        #expect(recipes.count == 1)
        let recipe = try #require(recipes.first)
        #expect(recipe.source.sha256 == Fixtures.idA)
        #expect(recipe.hdr.start == 0.5)
        #expect(!recipe.created.isEmpty)
    }

    @Test("editing after a POST retracts the sent banner but keeps the receipt")
    func editRetractsBanner() async throws {
        let harness = try await postedHarness()
        let judge = harness.judge
        await judge.postRecipe()
        #expect(judge.phase == .posted)

        judge.setStart(0.5)

        #expect(judge.phase == .judging)
        #expect(judge.isDirty)
        #expect(judge.postedMessage == nil)
        #expect(judge.lastRenderKey == nil)
        #expect(judge.editedMessage == "edited — not sent")
        #expect(judge.review?.receipt != nil)
    }

    @Test("dismissing the posted banner only hides it")
    func dismissPosted() async throws {
        let harness = try await postedHarness()
        let judge = harness.judge

        await judge.postRecipe()
        judge.dismissPosted()

        #expect(judge.phase == .judging)
        #expect(judge.postedMessage == nil)
        #expect(judge.lastRenderKey == nil)
        #expect(judge.editedMessage == nil)
        #expect(!judge.isDirty)
        #expect(judge.review?.receipt != nil)
    }

    @Test("a failed POST keeps the draft and retry re-sends it")
    func postFailureKeepsDraft() async throws {
        let harness = try await postedHarness()
        let judge = harness.judge
        judge.setStart(0.55)
        harness.client.postHandler = { _, _ in
            throw ClientError.invalidRecipe(message: "hdr.start")
        }

        await judge.postRecipe()

        #expect(judge.phase == .judging)
        #expect(judge.draft?.start == 0.55)
        #expect(judge.review?.receipt == nil)
        #expect(judge.postedMessage == nil)
        #expect(judge.notice?.severity == .error)
        #expect(judge.notice?.canRetry == true)
        #expect(judge.notice?.message == ClientError.invalidRecipe(message: "hdr.start").userMessage)

        harness.client.postHandler = { id, recipe in
            Fixtures.postResponse(for: Fixtures.itemA, recipe: recipe, renderKey: "retry-key")
        }
        await judge.retry()

        #expect(judge.phase == .posted)
        #expect(judge.lastRenderKey == "retry-key")
        #expect(judge.review?.receipt?.draft.start == 0.55)
        #expect(judge.notice == nil)
    }

    @Test("posting without a review is a no-op")
    func postWithoutReview() async throws {
        let harness = try Harness()
        await harness.connect()

        await harness.judge.postRecipe()

        #expect(harness.judge.phase == .idle)
        #expect(harness.judge.notice == nil)
        #expect(harness.client.postedRecipes().isEmpty)
    }
}
