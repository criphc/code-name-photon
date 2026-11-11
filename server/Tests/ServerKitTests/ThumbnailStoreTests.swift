import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import EngineKit
import ContractKit
import XCTest
@testable import ServerKit

/// `ItemStore.thumbnail` tests (ADR-0013): the filmstrip thumbnail is its own artifact.
///
/// It is rendered by `ThumbnailRenderer` (never by `prepare`), cached by file name + HEIC header
/// height, rendered once when two callers ask for the same item concurrently, and it never changes
/// the item's state — an item with only a thumbnail is still `pending`.
final class ThumbnailStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private struct Harness {
        let root: URL
        let batch: URL
        let work: URL
        let config: ServerConfig
        let store: ItemStore
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-thumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeHarness() throws -> Harness {
        let root = try makeTemporaryDirectory()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let config = try ServerConfig(
            batchDirectory: batch,
            workDirectory: work,
            token: "test-token",
            encoderVersion: "5dba4e2"
        )
        let store = try ItemStore(config: config)
        return Harness(root: root, batch: batch, work: work, config: config, store: store)
    }

    /// A 16-bit Display P3 TIFF. Must be at least 512 px tall for the thumbnail to reach 512 (the
    /// renderer never upscales), so the default is a 3:2 landscape: 768×512.
    @discardableResult
    private func writeSource(
        _ harness: Harness,
        name: String = "a.tif",
        size: PixelSize = PixelSize(width: 900, height: 600)
    ) throws -> URL {
        let url = harness.batch.appendingPathComponent(name)
        try ThumbnailFixture.writeGradientP3TIFF(size: size, to: url)
        return url
    }

    private func itemDirectory(_ harness: Harness, id: String) -> URL {
        harness.work.appendingPathComponent(id, isDirectory: true)
    }

    private func thumbnailURL(_ harness: Harness, id: String) -> URL {
        itemDirectory(harness, id: id).appendingPathComponent("thumbnail-512-v1.heic")
    }

    private func assertStoreThrows<T>(
        _ expression: @autoclosure () throws -> T,
        matching predicate: (ItemStoreError) -> Bool,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard let storeError = error as? ItemStoreError else {
                return XCTFail("expected ItemStoreError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(predicate(storeError), "unexpected ItemStoreError: \(storeError)", file: file, line: line)
        }
    }

    private func isSourceUnreadable(_ error: ItemStoreError) -> Bool {
        if case .sourceUnreadable = error { return true }
        return false
    }

    // MARK: - Rendering + state

    func testThumbnailIsRenderedWithoutPreparingThePreview() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try ThumbnailFixture.sha256(of: source)
        let directory = itemDirectory(harness, id: id)

        let data = try harness.store.thumbnail(id: id)

        // The bytes are the on-disk artifact: a 512-high Display P3 HEIC.
        XCTAssertFalse(data.isEmpty)
        let url = thumbnailURL(harness, id: id)
        XCTAssertEqual(data, try Data(contentsOf: url))
        XCTAssertEqual(try pixelHeight(of: url), 512)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(
            image.colorSpace?.name as String?,
            CGColorSpace(name: CGColorSpace.displayP3)?.name as String?
        )

        // Browsing must not render the 2560 px base, and a thumbnail is not a lifecycle event.
        for name in ["preview-base.png", "preview-meta.json", "state.json"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                "\(name) must not exist: a thumbnail is not a preview"
            )
        }
        let item = try harness.store.item(id: id)
        XCTAssertEqual(item.state, .pending, "only having a thumbnail is still pending")
        XCTAssertFalse(item.previewReady)
        XCTAssertNil(item.error)
    }

    func testSecondCallHitsTheCacheWithoutRerendering() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try ThumbnailFixture.sha256(of: source)
        let url = thumbnailURL(harness, id: id)

        let first = try harness.store.thumbnail(id: id)
        let renderedAt = try modificationDate(of: url)
        Thread.sleep(forTimeInterval: 0.02)
        let second = try harness.store.thumbnail(id: id)

        XCTAssertEqual(second, first)
        XCTAssertEqual(
            try modificationDate(of: url),
            renderedAt,
            "the second call re-rendered instead of hitting the cache"
        )
    }

    /// A source shorter than 512 px is not upscaled, so its thumbnail is shorter than 512 too. The
    /// file name is the cache key, so such a thumbnail must still hit; a `== 512` header rule
    /// re-rendered it on every request.
    func testSmallSourceThumbnailStillHitsTheCache() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness, size: PixelSize(width: 64, height: 64))
        let id = try ThumbnailFixture.sha256(of: source)
        let url = thumbnailURL(harness, id: id)

        let first = try harness.store.thumbnail(id: id)
        XCTAssertEqual(try pixelHeight(of: url), 64, "ImageIO must not upscale a small source")
        let renderedAt = try modificationDate(of: url)
        Thread.sleep(forTimeInterval: 0.02)
        let second = try harness.store.thumbnail(id: id)

        XCTAssertEqual(second, first)
        XCTAssertEqual(
            try modificationDate(of: url),
            renderedAt,
            "a thumbnail shorter than 512 must still be cached"
        )
    }

    /// The header height is a truncation/corruption guard, not the cache key: a file that is not a
    /// HEIC at all must be replaced.
    func testAnUnreadableThumbnailIsRerendered() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try ThumbnailFixture.sha256(of: source)
        let url = thumbnailURL(harness, id: id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try Data("not a thumbnail".utf8).write(to: url)
        XCTAssertEqual(try harness.store.thumbnail(id: id), try Data(contentsOf: url))
        XCTAssertEqual(try pixelHeight(of: url), 512, "an unreadable cache file must be replaced")
    }

    // MARK: - Failures

    func testAFailedThumbnailLeavesTheItemPending() throws {
        let harness = try makeHarness()
        let source = harness.batch.appendingPathComponent("broken.tif")
        try Data("this is not a TIFF".utf8).write(to: source)
        let id = try ThumbnailFixture.sha256(of: source)

        assertStoreThrows(try harness.store.thumbnail(id: id), matching: isSourceUnreadable)

        let item = try harness.store.item(id: id)
        XCTAssertEqual(item.state, .pending, "a thumbnail failure must not mark the item failed")
        XCTAssertNil(item.error)
        let directory = itemDirectory(harness, id: id)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path),
            "a thumbnail failure must not persist a state record"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL(harness, id: id).path))
    }

    // MARK: - In-flight de-duplication

    /// Concurrent callers for the same item share one render. The first call gets a head start so
    /// the second really arrives while it is in flight; if the second re-rendered, it would rewrite
    /// the file after the first returned and the mtime would move.
    func testConcurrentCallsForTheSameItemRenderOnce() throws {
        let harness = try makeHarness()
        // Big enough that one render outlasts the 20 ms head start below.
        let source = try writeSource(harness, size: PixelSize(width: 2400, height: 1600))
        let id = try ThumbnailFixture.sha256(of: source)
        let url = thumbnailURL(harness, id: id)

        let first = Box<Result<Data, Error>>()
        let second = Box<Result<Data, Error>>()
        let firstRenderedAt = Box<Date>()
        let firstStarted = DispatchSemaphore(value: 0)
        let firstDone = expectation(description: "first thumbnail")
        let secondDone = expectation(description: "second thumbnail")

        DispatchQueue.global().async {
            firstStarted.signal()
            first.set(Result { try harness.store.thumbnail(id: id) })
            if let renderedAt = try? modificationDate(of: url) { firstRenderedAt.set(renderedAt) }
            firstDone.fulfill()
        }
        firstStarted.wait()
        Thread.sleep(forTimeInterval: 0.02)
        DispatchQueue.global().async {
            second.set(Result { try harness.store.thumbnail(id: id) })
            secondDone.fulfill()
        }
        wait(for: [firstDone, secondDone], timeout: 60)

        let firstData = try XCTUnwrap(first.get()).get()
        let secondData = try XCTUnwrap(second.get()).get()
        XCTAssertEqual(firstData, secondData)
        XCTAssertEqual(try pixelHeight(of: url), 512)
        XCTAssertEqual(
            try modificationDate(of: url),
            firstRenderedAt.get(),
            "the second caller re-rendered instead of waiting for the first"
        )
    }
}

// MARK: - Helpers

/// Thread-safe slot for a value produced on a background queue.
private final class Box<Value> {
    private let lock = NSLock()
    private var value: Value?

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func modificationDate(of url: URL) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.modificationDate] as? Date, "no mtime for \(url.path)")
}

private func pixelHeight(of url: URL) throws -> Int {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
    let properties = try XCTUnwrap(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        "no image properties for \(url.path)"
    )
    return try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
}

/// Generated-at-run-time 16-bit Display P3 TIFFs — the same shape as a Capture One SDR export.
private enum ThumbnailFixture {
    static func writeGradientP3TIFF(size: PixelSize, to url: URL) throws {
        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .outputColorSpace: linearP3,
            .cacheIntermediates: false,
        ])
        let gradient = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: CGFloat(size.width), y: 0),
                "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1, colorSpace: linearP3)!,
                "inputColor1": CIColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1, colorSpace: linearP3)!,
            ]
        )!.outputImage!.cropped(
            to: CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height))
        )
        try context.writeTIFFRepresentation(
            of: gradient,
            to: url,
            format: .RGBA16,
            colorSpace: displayP3,
            options: [:]
        )
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
