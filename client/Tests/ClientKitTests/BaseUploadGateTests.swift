@testable import ClientKit
import ContractKit
import XCTest

/// Pins the base-upload gating that P0-1 exposed: the session cache restores a decoded image
/// without decoding it again, so a counter that is only bumped after a successful decode cannot
/// tell the canvas that another item's pixels are on the GPU. The A → B → A reselect must upload
/// A's pixels again even though no new decode happened.
///
/// Scope boundary: this locks the gate *mechanism* only. The wiring that matters just as much —
/// `JudgeModel` storing `BaseIdentity` in the cached `Review` and `EDRCanvas.Coordinator` calling the
/// gate — lives in the app target, which the macOS test bundle does not compile (P2-10, out of
/// scope for the P0/P1 fix). Swapping the gate back for a version counter inside `updateUIView`
/// would keep these tests green.
final class BaseUploadGateTests: XCTestCase {
    private let baseA = BaseIdentity(itemID: "item-a", generation: 1)
    private let baseB = BaseIdentity(itemID: "item-b", generation: 2)

    func testCachedReselectUploadsTheOtherItemAgain() {
        // Decode A (generation 1) → decode B (generation 2) → reselect A from the session cache
        // (generation 1, no decode). The identity changes back, so A's pixels must be uploaded;
        // a version-only gate would compare 2 with 2 and keep B's texture (P0-1).
        var gate = BaseUploadGate()
        XCTAssertTrue(gate.needsUpload(for: baseA))
        gate.commitUpload(baseA)

        XCTAssertTrue(gate.needsUpload(for: baseB))
        gate.commitUpload(baseB)

        XCTAssertTrue(gate.needsUpload(for: baseA))
        gate.commitUpload(baseA)
        XCTAssertFalse(gate.needsUpload(for: baseA))
    }

    func testReDecodingTheSameItemIsANewBase() {
        // The 409 re-prepare re-decodes the same item: the generation must make it a new base.
        var gate = BaseUploadGate()
        gate.commitUpload(baseA)
        let redecode = BaseIdentity(itemID: "item-a", generation: 3)
        XCTAssertTrue(gate.needsUpload(for: redecode))
    }

    func testNilClearsTheTextureAndBackUploadsAgain() {
        // `review = nil` must clear the texture instead of leaving the last item's pixels behind a
        // loading card; reselecting then needs an upload again.
        var gate = BaseUploadGate()
        gate.commitUpload(baseA)

        XCTAssertTrue(gate.needsUpload(for: nil))
        gate.commitUpload(nil)
        XCTAssertFalse(gate.needsUpload(for: nil))

        XCTAssertTrue(gate.needsUpload(for: baseA))
    }
}
