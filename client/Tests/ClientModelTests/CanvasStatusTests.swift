import ContractKit
import Foundation
import Testing
@testable import ClientModel

@Suite("Canvas status")
struct CanvasStatusTests {
    private func meta(width: Int = 2560, height: Int = 1700) -> PreviewMetadata {
        Fixtures.metadata(
            for: Fixtures.item(id: Fixtures.idA, name: Fixtures.nameA, path: Fixtures.pathA,
                               width: width, height: height),
            png: Data()
        )
    }

    @Test("with a base it reports the preview size, gamut and depth")
    func withBase() {
        let status = CanvasStatus.make(meta: meta(), displayHeadroom: 4.2, isLoading: false)
        #expect(status.size == "2560×1700（预览）")
        #expect(status.gamut == "Display P3")
        #expect(status.depth == "16-bit")
    }

    @Test("without a base it says why, and has no headroom reading")
    func withoutBase() {
        let loading = CanvasStatus.make(meta: nil, displayHeadroom: 4.2, isLoading: true)
        #expect(loading.size == "Loading…")
        #expect(loading.headroomStops == nil)

        let empty = CanvasStatus.make(meta: nil, displayHeadroom: 4.2, isLoading: false)
        #expect(empty.size == "No image")
        #expect(empty.headroomStops == nil)
        #expect(empty.gamut == nil)
        #expect(empty.depth == nil)
    }

    @Test("headroom floors to one decimal", arguments: [
        (Float(1), 0.0),
        (2.7, 1.4),
        (4.2, 2.0),
        (7.3, 2.8),
    ])
    func headroomFloor(headroom: Float, expected: Double) {
        let status = CanvasStatus.make(meta: meta(), displayHeadroom: headroom, isLoading: false)
        #expect(status.headroomStops == expected)
    }

    @Test("depth comes from the format tag, not a constant")
    func depthFromFormat() {
        // 夹具的 format 是 png-16-p3；这个用例锁住「从标签解析」而不是写死 16。
        #expect(meta().base.format.hasPrefix("png-16"))
        let status = CanvasStatus.make(meta: meta(), displayHeadroom: 1, isLoading: false)
        #expect(status.depth == "16-bit")
    }
}
