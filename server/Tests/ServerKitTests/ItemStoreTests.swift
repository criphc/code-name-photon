import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import EngineKit
import ContractKit
import XCTest
@testable import ServerKit

/// `ItemStore` tests against the **M2.1** contract: `prepare` renders only the SDR base preview
/// (16-bit Display P3 PNG) via the real `PreviewBaseRenderer`; there is no encoder, no HDR rendition
/// and no gain-map HEIC anywhere in the path, so none of these tests need `tools/toGainMapHDR`.
///
/// No `samples/` and no `work/` dependency: every source TIFF is generated here (16-bit Display P3,
/// tiny 96×64 gradient) into a unique temporary directory, so the suite runs anywhere.
final class ItemStoreTests: XCTestCase {
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
            .appendingPathComponent("photon-itemstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeHarness(
        appVersion: String = "0.2.0-test",
        encoderVersion: String = "5dba4e2",
        previewLongEdge: Int = 2560
    ) throws -> Harness {
        let root = try makeTemporaryDirectory()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let config = try ServerConfig(
            batchDirectory: batch,
            workDirectory: work,
            token: "test-token",
            previewLongEdge: previewLongEdge,
            encoderVersion: encoderVersion,
            appVersion: appVersion
        )
        let store = try ItemStore(config: config)
        return Harness(root: root, batch: batch, work: work, config: config, store: store)
    }

    @discardableResult
    private func writeSource(
        _ harness: Harness,
        name: String = "a.tif",
        size: PixelSize = PixelSize(width: 96, height: 64)
    ) throws -> URL {
        let url = harness.batch.appendingPathComponent(name)
        try Fixture.writeGradientP3TIFF(size: size, to: url)
        return url
    }

    private func itemDirectory(_ harness: Harness, id: String) -> URL {
        harness.work.appendingPathComponent(id, isDirectory: true)
    }

    private func readStateJSON(work: URL, id: String) throws -> [String: Any] {
        let url = work.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("state.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "state.json is not a JSON object")
    }

    private func readMetadata(_ harness: Harness, id: String) throws -> PreviewMetadata {
        let url = itemDirectory(harness, id: id).appendingPathComponent("preview-meta.json")
        return try JSONDecoder().decode(PreviewMetadata.self, from: Data(contentsOf: url))
    }

    /// Mutates `state.json` in place, so a test can plant a stale record (e.g. `failed`) while the
    /// preview artifacts are untouched.
    private func rewriteStateJSON(
        work: URL,
        id: String,
        _ mutate: (inout [String: Any]) -> Void
    ) throws {
        let url = work.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("state.json")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutate(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// A valid posted recipe for the given source. Callers must not need a prepare: the recipe
    /// carries the source identity itself (that is exactly the recipe-before-prepare case).
    private func makeRecipe(
        _ harness: Harness,
        source: URL,
        id: String,
        width: Int = 96,
        height: Int = 64
    ) -> Recipe {
        Recipe.defaults(
            sourcePath: source.standardizedFileURL.path,
            sourceSHA256: id,
            width: width,
            height: height,
            encoderVersion: harness.config.encoderVersion,
            created: "2026-11-02T22:00:00+08:00"
        )
    }

    // MARK: - Assertion helpers

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
            XCTAssertTrue(
                predicate(storeError),
                "unexpected ItemStoreError: \(storeError)",
                file: file,
                line: line
            )
        }
    }

    private func isUnknownItem(_ error: ItemStoreError) -> Bool {
        if case .unknownItem = error { return true }
        return false
    }

    private func isInvalidRecipe(_ error: ItemStoreError) -> Bool {
        if case .invalidRecipe = error { return true }
        return false
    }

    private func isSourceChanged(_ error: ItemStoreError) -> Bool {
        if case .sourceChanged = error { return true }
        return false
    }

    private func isPrepareFailed(_ error: ItemStoreError) -> Bool {
        if case .prepareFailed = error { return true }
        return false
    }

    private func isSourceUnreadable(_ error: ItemStoreError) -> Bool {
        if case .sourceUnreadable = error { return true }
        return false
    }

    private func isIO(_ error: ItemStoreError) -> Bool {
        if case .io = error { return true }
        return false
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date, "no mtime for \(url.path)")
    }

    /// ImageIO's view of the PNG base: what M3 would actually decode.
    private func pngProperties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            "no image properties for \(url.path)"
        )
    }

    // MARK: - Listing, identity, state (no rendering)

    func testEmptyBatchIsAnEmptyList() throws {
        let harness = try makeHarness()
        XCTAssertEqual(try harness.store.itemCount(), 0)
        XCTAssertEqual(try harness.store.listItems(), [])
    }

    func testOneFileBecomesAPendingItemIdentifiedByItsBytes() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let expectedID = try Fixture.sha256(of: source)

        let items = try harness.store.listItems()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, expectedID)
        XCTAssertEqual(item.id.count, 64)
        XCTAssertEqual(item.id, item.id.lowercased())
        XCTAssertEqual(item.name, "a.tif")
        XCTAssertEqual(item.path, source.standardizedFileURL.path)
        XCTAssertEqual(item.state, .pending)
        XCTAssertFalse(item.previewReady)
        XCTAssertFalse(item.hasRecipe)
        XCTAssertNil(item.width)
        XCTAssertNil(item.height)
        XCTAssertNil(item.error)

        XCTAssertEqual(try harness.store.item(id: expectedID), item)
        XCTAssertEqual(try harness.store.itemCount(), 1)
    }

    func testListingSkipsNonSourcesAndSortsByName() throws {
        let harness = try makeHarness()
        let size = PixelSize(width: 96, height: 64)
        // Distinct pixels per file: identical bytes would (correctly) collapse into one item.
        try Fixture.writeUniformP3TIFF(size: size, linearValue: 0.2, to: harness.batch.appendingPathComponent("b.tif"))
        try Fixture.writeUniformP3TIFF(size: size, linearValue: 0.4, to: harness.batch.appendingPathComponent("a.tiff"))
        try Fixture.writeUniformP3TIFF(size: size, linearValue: 0.6, to: harness.batch.appendingPathComponent("C.TIF"))
        // Not sources: a hidden file, a wrong extension and a directory that merely looks like a TIFF.
        try Fixture.writeUniformP3TIFF(size: size, linearValue: 0.8, to: harness.batch.appendingPathComponent(".hidden.tif"))
        try Data("not an image".utf8).write(to: harness.batch.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: harness.batch.appendingPathComponent("folder.tif"),
            withIntermediateDirectories: true
        )

        let items = try harness.store.listItems()
        XCTAssertEqual(items.map(\.name), ["C.TIF", "a.tiff", "b.tif"])
        XCTAssertEqual(try harness.store.itemCount(), 3)
    }

    func testDuplicateContentCollapsesToOneItem() throws {
        let harness = try makeHarness()
        let first = try writeSource(harness, name: "a.tif")
        let second = harness.batch.appendingPathComponent("b.tif")
        try FileManager.default.copyItem(at: first, to: second)

        let items = try harness.store.listItems()
        XCTAssertEqual(items.count, 1, "the id is the bytes, so two identical files are one item")
        XCTAssertEqual(items.first?.name, "a.tif", "the first name in sort order is canonical")
        XCTAssertEqual(items.first?.id, try Fixture.sha256(of: first))
        // itemCount is the cheap /api/health probe: it counts source *files* without hashing, so
        // duplicate content can make it exceed the number of distinct items.
        XCTAssertEqual(try harness.store.itemCount(), 2)
        XCTAssertEqual(try harness.store.itemCount(), 2, "cheap count does not collapse duplicates")
    }

    /// P1-8: `/api/health` must be a cheap, non-blocking probe.
    ///
    /// The count is a *file* count (duplicates included, `listItems` is the authoritative view) and
    /// must come from a cold directory listing without hashing sources or taking the store's main
    /// lock. The unreadable `.tif` proves the no-hash part: a scan cannot hash it (and skips it),
    /// yet the count still includes it, because `itemCount()` never reads file contents. There is
    /// deliberately no timing assertion for "non-blocking": the design property is that
    /// `itemCount()` only uses `countLock`/`cachedItemCount` and never `scanLocked()`/`lock`, which
    /// the implementation notes on `ItemStore.itemCount()` spell out.
    func testItemCountIsAColdFileCountThatDoesNotScanOrHash() throws {
        if geteuid() == 0 {
            throw XCTSkip("permission bits are not enforced for root; the unreadable fixture needs them")
        }
        let harness = try makeHarness()
        let size = PixelSize(width: 96, height: 64)
        _ = try writeSource(harness, name: "a.tif")
        let unreadable = harness.batch.appendingPathComponent("b.tif")
        try Fixture.writeUniformP3TIFF(size: size, linearValue: 0.4, to: unreadable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: unreadable.path
            )
        }

        // Cold: nothing has listed/prepared yet. A directory listing is enough (and must be enough:
        // hashing b.tif would fail).
        XCTAssertEqual(try harness.store.itemCount(), 2)

        // A scan is the authoritative view and must skip the file it cannot hash.
        let listed = try harness.store.listItems()
        XCTAssertEqual(listed.map(\.name), ["a.tif"])
        // The scan republishes the same file-count semantics: unhashable files still count.
        XCTAssertEqual(try harness.store.itemCount(), 2)
    }

    func testReExportChangesIdentity() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let firstID = try Fixture.sha256(of: source)
        XCTAssertEqual(try harness.store.listItems().first?.id, firstID)

        // Re-export: same path, different pixels, different bytes. Force a different mtime so the
        // (size, mtime, inode) memo cannot mask it — the id must follow the bytes, not the path.
        try Fixture.writeUniformP3TIFF(
            size: PixelSize(width: 96, height: 64),
            linearValue: 0.4,
            to: source
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: source.path
        )
        let secondID = try Fixture.sha256(of: source)
        XCTAssertNotEqual(firstID, secondID)

        let items = try harness.store.listItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, secondID)
        XCTAssertEqual(try harness.store.itemCount(), 1)

        assertStoreThrows(try harness.store.item(id: firstID), matching: isUnknownItem)
        assertStoreThrows(try harness.store.prepare(id: firstID), matching: isUnknownItem)
        XCTAssertEqual(try harness.store.item(id: secondID).state, .pending)
    }

    func testUnknownItemForEveryEntryPoint() throws {
        let harness = try makeHarness()
        let unknownID = String(repeating: "0", count: 64)

        assertStoreThrows(try harness.store.item(id: unknownID), matching: isUnknownItem)
        assertStoreThrows(try harness.store.prepare(id: unknownID), matching: isUnknownItem)
        assertStoreThrows(try harness.store.metadataJSON(id: unknownID), matching: isUnknownItem)
        assertStoreThrows(try harness.store.previewPNG(id: unknownID), matching: isUnknownItem)
        assertStoreThrows(try harness.store.thumbnail(id: unknownID), matching: isUnknownItem)
        assertStoreThrows(try harness.store.recipeJSON(id: unknownID), matching: isUnknownItem)
        assertStoreThrows(
            try harness.store.storeRecipe(id: unknownID, body: Data("{}".utf8)),
            matching: isUnknownItem
        )
    }

    func testInitValidatesTheBatchDirectoryAndCreatesTheWorkDirectory() throws {
        let root = try makeTemporaryDirectory()

        // Missing batch directory.
        assertStoreThrows(
            try ItemStore(config: ServerConfig(
                batchDirectory: root.appendingPathComponent("missing"),
                workDirectory: root.appendingPathComponent("work"),
                token: "t",
                encoderVersion: "v"
            )),
            matching: isIO
        )

        // A batch path that is a file, not a directory.
        let batchFile = root.appendingPathComponent("batch-file")
        try Data("x".utf8).write(to: batchFile)
        assertStoreThrows(
            try ItemStore(config: ServerConfig(
                batchDirectory: batchFile,
                workDirectory: root.appendingPathComponent("work"),
                token: "t",
                encoderVersion: "v"
            )),
            matching: isIO
        )

        // Valid batch: init creates the (nested) work directory, without hashing anything.
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let work = root.appendingPathComponent("nested/artifacts", isDirectory: true)
        _ = try ItemStore(config: ServerConfig(
            batchDirectory: batch,
            workDirectory: work,
            token: "t",
            encoderVersion: "v"
        ))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPrepareFailurePersistsFailedState() throws {
        // A corrupt `.tif` is listed by hash (the scan never decodes) but cannot be prepared.
        let harness = try makeHarness()
        let source = harness.batch.appendingPathComponent("broken.tif")
        try Data("this is not a TIFF".utf8).write(to: source)
        let id = try Fixture.sha256(of: source)

        assertStoreThrows(try harness.store.prepare(id: id), matching: isSourceUnreadable)

        let item = try harness.store.item(id: id)
        XCTAssertEqual(item.state, .failed)
        XCTAssertFalse(item.previewReady)
        XCTAssertFalse(item.hasRecipe)
        XCTAssertNotNil(item.error)

        let state = try readStateJSON(work: harness.work, id: id)
        XCTAssertEqual(state["state"] as? String, "failed")
        XCTAssertNotNil(state["lastError"] as? String)
        XCTAssertEqual(state["sourceSHA"] as? String, id)
        XCTAssertNil(state["width"], "nothing was decoded into a state dimension before the failure")
        XCTAssertNil(state["height"])

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: itemDirectory(harness, id: id).appendingPathComponent("preview-base.png").path
            ),
            "a failed prepare must not leave a base PNG behind"
        )
    }

    func testRenderWriteFailureMapsToPrepareFailed() throws {
        // A regular file where the item directory must go makes the renderer's mkdir fail. That is
        // a `PhotonError.writeFailed`, not a source problem: it must surface as `.prepareFailed`.
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        try Data("blocker".utf8).write(to: itemDirectory(harness, id: id))

        assertStoreThrows(try harness.store.prepare(id: id), matching: isPrepareFailed)
    }

    // MARK: - Prepare: cold + warm (no encoder)

    func testPrepareColdThenWarmCache() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        let directory = itemDirectory(harness, id: id)

        XCTAssertEqual(try harness.store.item(id: id).state, .pending)

        let coldStart = Date()
        let cold = try harness.store.prepare(id: id)
        let coldSeconds = Date().timeIntervalSince(coldStart)

        XCTAssertFalse(cold.cached)
        XCTAssertEqual(cold.item.id, id)
        XCTAssertEqual(cold.item.state, .previewReady)
        XCTAssertTrue(cold.item.previewReady)
        XCTAssertFalse(cold.item.hasRecipe)
        XCTAssertEqual(cold.item.width, 96)
        XCTAssertEqual(cold.item.height, 64)
        XCTAssertNil(cold.item.error)

        // PreviewMetadata: source identity + decoded facts + base transport facts.
        let meta = cold.meta
        XCTAssertEqual(meta.schema, PreviewMetadata.currentSchema)
        XCTAssertEqual(meta.source.sha256, id)
        XCTAssertEqual(meta.source.path, source.standardizedFileURL.path)
        XCTAssertEqual(meta.source.width, 96)
        XCTAssertEqual(meta.source.height, 64)
        XCTAssertEqual(meta.source.bitsPerComponent, 16)
        XCTAssertEqual(meta.source.profileName, "Display P3")
        XCTAssertEqual(meta.base.file, "preview-base.png")
        XCTAssertEqual(meta.base.format, "png-16-p3")
        XCTAssertEqual(meta.base.workingSpace, "linear-extended-DisplayP3-float32")
        XCTAssertEqual(meta.base.profileName, "Display P3")
        XCTAssertEqual(meta.base.longEdge, harness.config.previewLongEdge)
        XCTAssertEqual(meta.base.width, 96)
        XCTAssertEqual(meta.base.height, 64)
        XCTAssertGreaterThan(meta.base.bytes, 0)
        XCTAssertEqual(meta.base.sha256.count, 64)
        XCTAssertEqual(meta.appVersion, harness.config.appVersion)
        XCTAssertEqual(meta.recipeDefaults.source.sha256, id)
        XCTAssertEqual(meta.recipeDefaults.source.width, 96)
        XCTAssertEqual(meta.recipeDefaults.source.height, 64)
        XCTAssertEqual(meta.recipeDefaults.versions.encoder, harness.config.encoderVersion)
        XCTAssertEqual(meta.recipeDefaults.hdr, Recipe.HDR(), "prepare uses the documented defaults")
        XCTAssertFalse(meta.createdAt.isEmpty)

        // Artifacts on disk.
        for name in ["preview-base.png", "preview-meta.json", "state.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                "missing \(name)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("recipe.json").path)
        )
        let baseURL = directory.appendingPathComponent("preview-base.png")
        let metadataURL = directory.appendingPathComponent("preview-meta.json")
        let stateURL = directory.appendingPathComponent("state.json")

        // The transport artifact is a PNG (magic 89 50 4E 47) whose bytes meta describes.
        let png = try Data(contentsOf: baseURL)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "preview-base.png is not a PNG")
        XCTAssertEqual(png.count, meta.base.bytes)
        XCTAssertEqual(try Fixture.sha256(of: baseURL), meta.base.sha256)

        // ImageIO sees the M3 contract: 16-bit, no alpha, Display P3, base dimensions.
        let properties = try pngProperties(of: baseURL)
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 16, "the base must be 16 bits per component")
        XCTAssertNotEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true, "the base must have no alpha")
        XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "Display P3")
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, meta.base.width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, meta.base.height)

        // state.json: the documented M2 shape.
        let state = try readStateJSON(work: harness.work, id: id)
        XCTAssertEqual(state["id"] as? String, id)
        XCTAssertEqual(state["name"] as? String, "a.tif")
        XCTAssertEqual(state["sourcePath"] as? String, source.standardizedFileURL.path)
        XCTAssertEqual(state["sourceSHA"] as? String, id)
        XCTAssertEqual(state["state"] as? String, "preview_ready")
        XCTAssertEqual(state["width"] as? Int, 96)
        XCTAssertEqual(state["height"] as? Int, 64)
        XCTAssertEqual(state["appVersion"] as? String, harness.config.appVersion)
        XCTAssertEqual(state["encoderVersion"] as? String, harness.config.encoderVersion)
        XCTAssertNil(state["lastError"])
        XCTAssertNil(state["recipeRenderKey"])
        let updatedAt = try XCTUnwrap(state["updatedAt"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: updatedAt), "updatedAt must be ISO 8601: \(updatedAt)")

        // Reading the artifacts back matches the files byte for byte.
        XCTAssertEqual(try harness.store.previewPNG(id: id), png)
        let metaBytes = try harness.store.metadataJSON(id: id)
        XCTAssertEqual(metaBytes, try Data(contentsOf: metadataURL))
        XCTAssertEqual(try JSONDecoder().decode(PreviewMetadata.self, from: metaBytes), meta)

        // Warm prepare: no re-render, nothing rewritten on disk.
        let metadataSHA = try Fixture.sha256(of: metadataURL)
        let baseSHA = try Fixture.sha256(of: baseURL)
        let metadataMTime = try modificationDate(of: metadataURL)
        let baseMTime = try modificationDate(of: baseURL)
        let stateMTime = try modificationDate(of: stateURL)

        let warmStart = Date()
        let warm = try harness.store.prepare(id: id)
        let warmSeconds = Date().timeIntervalSince(warmStart)

        XCTAssertTrue(warm.cached)
        XCTAssertEqual(warm.item.state, .previewReady)
        XCTAssertEqual(warm.meta, meta)
        XCTAssertEqual(try Fixture.sha256(of: metadataURL), metadataSHA, "preview-meta.json was rewritten on a cache hit")
        XCTAssertEqual(try Fixture.sha256(of: baseURL), baseSHA)
        XCTAssertEqual(try modificationDate(of: metadataURL), metadataMTime)
        XCTAssertEqual(try modificationDate(of: baseURL), baseMTime)
        XCTAssertEqual(try modificationDate(of: stateURL), stateMTime, "state.json was rewritten on a cache hit")

        print(
            String(
                format: "ItemStore.prepare 96x64 fixture: cold %.1f ms, warm %.1f ms",
                coldSeconds * 1000,
                warmSeconds * 1000
            )
        )

        // A vanished artifact makes the item pending again and forces a re-render.
        try FileManager.default.removeItem(at: baseURL)
        let evicted = try harness.store.item(id: id)
        XCTAssertEqual(evicted.state, .pending)
        XCTAssertFalse(evicted.previewReady)
        let restored = try harness.store.prepare(id: id)
        XCTAssertFalse(restored.cached, "a missing preview-base.png must not be served from cache")
        XCTAssertEqual(try harness.store.item(id: id).state, .previewReady)

        // Changing the app build invalidates the cache without changing the source or the config.
        var bumpedConfig = harness.config
        bumpedConfig.appVersion = "0.2.1-test"
        let rebuilt = try ItemStore(config: bumpedConfig)
        let afterBump = try rebuilt.prepare(id: id)
        XCTAssertFalse(afterBump.cached, "appVersion is part of the cache key")
        XCTAssertEqual(afterBump.meta.appVersion, "0.2.1-test")
        XCTAssertEqual(try rebuilt.item(id: id).state, .previewReady)
    }

    func testPrepareLongEdgeIsRespected() throws {
        let harness = try makeHarness(previewLongEdge: 120)
        let source = try writeSource(harness, size: PixelSize(width: 240, height: 160))
        let id = try Fixture.sha256(of: source)

        let cold = try harness.store.prepare(id: id)
        XCTAssertFalse(cold.cached)
        // Source facts are the decoded source, not the downscaled base.
        XCTAssertEqual(cold.meta.source.width, 240)
        XCTAssertEqual(cold.meta.source.height, 160)
        XCTAssertEqual(cold.item.width, 240)
        XCTAssertEqual(cold.item.height, 160)
        // The base is Lanczos-downscaled to the configured long edge, aspect ratio preserved.
        XCTAssertEqual(cold.meta.base.longEdge, 120)
        XCTAssertEqual(cold.meta.base.width, 120)
        XCTAssertEqual(cold.meta.base.height, 80)

        let baseURL = itemDirectory(harness, id: id).appendingPathComponent("preview-base.png")
        let properties = try pngProperties(of: baseURL)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 120)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 80)

        XCTAssertTrue(try harness.store.prepare(id: id).cached)
    }

    func testTamperedBaseFileForcesARender() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)

        let cold = try harness.store.prepare(id: id)
        let baseURL = itemDirectory(harness, id: id).appendingPathComponent("preview-base.png")
        var bytes = try Data(contentsOf: baseURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: baseURL)
        let tamperedSHA = try Fixture.sha256(of: baseURL)
        XCTAssertNotEqual(tamperedSHA, cold.meta.base.sha256)

        // meta.base.sha256 no longer describes the bytes on disk: not a cache hit.
        let again = try harness.store.prepare(id: id)
        XCTAssertFalse(again.cached)
        XCTAssertEqual(try Fixture.sha256(of: baseURL), again.meta.base.sha256)
        XCTAssertNotEqual(try Fixture.sha256(of: baseURL), tamperedSHA)
    }

    // MARK: - Artifact reads

    func testArtifactReadsRequireAPrepare() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)

        assertStoreThrows(try harness.store.previewPNG(id: id), matching: isPrepareFailed)
        assertStoreThrows(try harness.store.metadataJSON(id: id), matching: isPrepareFailed)
        XCTAssertNil(try harness.store.recipeJSON(id: id))

        _ = try harness.store.prepare(id: id)
        let directory = itemDirectory(harness, id: id)
        XCTAssertEqual(
            try harness.store.previewPNG(id: id),
            try Data(contentsOf: directory.appendingPathComponent("preview-base.png"))
        )
        let metaData = try harness.store.metadataJSON(id: id)
        XCTAssertEqual(metaData, try Data(contentsOf: directory.appendingPathComponent("preview-meta.json")))
        let meta = try JSONDecoder().decode(PreviewMetadata.self, from: metaData)
        XCTAssertEqual(meta.source.sha256, id)
        XCTAssertEqual(meta.base.file, "preview-base.png")
    }

    // MARK: - Recipes

    func testPostedRecipeRoundTripsAndDoesNotInvalidateThePreview() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        let cold = try harness.store.prepare(id: id)

        let item = try harness.store.item(id: id)
        let recipe = Recipe.defaults(
            sourcePath: item.path,
            sourceSHA256: id,
            width: 96,
            height: 64,
            encoderVersion: harness.config.encoderVersion,
            created: "2026-11-02T22:00:00+08:00"
        )
        let body = try JSONEncoder().encode(recipe)

        let response = try harness.store.storeRecipe(id: id, body: body)
        XCTAssertEqual(response.item.id, id)
        XCTAssertEqual(response.item.state, .recipeReceived)
        XCTAssertTrue(response.item.hasRecipe)
        XCTAssertTrue(response.item.previewReady)
        XCTAssertEqual(response.recipe, recipe)
        XCTAssertEqual(response.renderKey, try recipe.renderKey())
        XCTAssertEqual(response.renderKey.count, 64)
        XCTAssertTrue(response.renderKey.allSatisfy(\.isHexDigit), "renderKey must be lowercase hex")
        XCTAssertEqual(response.renderKey, response.renderKey.lowercased())

        let stored = try XCTUnwrap(try harness.store.recipeJSON(id: id))
        XCTAssertEqual(stored, try recipe.canonicalJSON(), "recipe.json must be the canonical form")

        let state = try readStateJSON(work: harness.work, id: id)
        XCTAssertEqual(state["state"] as? String, "recipe_received")
        XCTAssertEqual(state["recipeRenderKey"] as? String, response.renderKey)
        XCTAssertEqual(state["width"] as? Int, 96)
        XCTAssertEqual(state["height"] as? Int, 64)
        XCTAssertEqual(try harness.store.item(id: id).state, .recipeReceived)

        // A stored recipe is not a render request: prepare still serves the base from cache, and
        // `preview-meta.json` (documented defaults) is untouched.
        let baseURL = itemDirectory(harness, id: id).appendingPathComponent("preview-base.png")
        let metadataURL = itemDirectory(harness, id: id).appendingPathComponent("preview-meta.json")
        let baseSHA = try Fixture.sha256(of: baseURL)
        let metadataSHA = try Fixture.sha256(of: metadataURL)
        let again = try harness.store.prepare(id: id)
        XCTAssertTrue(again.cached)
        XCTAssertEqual(again.item.state, .recipeReceived)
        XCTAssertEqual(again.meta.recipeDefaults.hdr, Recipe.HDR())
        XCTAssertEqual(again.meta.recipeDefaults.source.sha256, id)
        XCTAssertEqual(again.meta.recipeDefaults, cold.meta.recipeDefaults)
        XCTAssertEqual(try Fixture.sha256(of: baseURL), baseSHA)
        XCTAssertEqual(try Fixture.sha256(of: metadataURL), metadataSHA)
    }

    func testInvalidPostedRecipesAreRejected() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: id)

        let sourceInfo = Recipe.Source(
            path: source.standardizedFileURL.path,
            sha256: id,
            width: 96,
            height: 64
        )
        let versions = Recipe.Versions(encoder: harness.config.encoderVersion)
        let created = "2026-11-02T22:00:00+08:00"

        // Unknown schema is refused, never reinterpreted (docs/reference/recipe.md, recipe schema 0).
        let schema7 = Recipe(
            schema: 7,
            source: sourceInfo,
            versions: Recipe.Versions(recipe: 7, encoder: harness.config.encoderVersion),
            created: created
        )
        assertStoreThrows(
            try harness.store.storeRecipe(id: id, body: JSONEncoder().encode(schema7)),
            matching: isInvalidRecipe,
            "schema 7"
        )

        // An unknown map dialect is still invalid.
        let invalidMap = Recipe(
            source: sourceInfo,
            encoder: Recipe.EncoderParams(map: "apple-mono"),
            versions: versions,
            created: created
        )
        assertStoreThrows(
            try harness.store.storeRecipe(id: id, body: JSONEncoder().encode(invalidMap)),
            matching: isInvalidRecipe,
            "encoder.map = apple-mono"
        )

        // Garbage JSON.
        assertStoreThrows(
            try harness.store.storeRecipe(id: id, body: Data("{ this is not a recipe".utf8)),
            matching: isInvalidRecipe,
            "malformed JSON"
        )

        // Dimensions must equal the decoded image (docs/reference/recipe.md, "must equal the decoded image").
        let wrongDimensions = Recipe(
            source: Recipe.Source(
                path: sourceInfo.path,
                sha256: id,
                width: 95,
                height: 64
            ),
            versions: versions,
            created: created
        )
        assertStoreThrows(
            try harness.store.storeRecipe(id: id, body: JSONEncoder().encode(wrongDimensions)),
            matching: isInvalidRecipe,
            "dimension mismatch"
        )

        XCTAssertNil(try harness.store.recipeJSON(id: id), "a refused recipe must not be stored")
        XCTAssertEqual(try harness.store.item(id: id).state, .previewReady, "a refused recipe must not change state")

        // A valid v2 profile still goes through afterwards (10-bit, half-res, ISO mono).
        let valid = Recipe(
            source: sourceInfo,
            encoder: Recipe.EncoderParams(
                tool: Recipe.EncoderParams.coreImageToolName,
                quality: 0.85,
                depth: 10,
                subsample: true,
                map: Recipe.EncoderParams.isoMonoMap
            ),
            versions: versions,
            created: created
        )
        let accepted = try harness.store.storeRecipe(id: id, body: JSONEncoder().encode(valid))
        XCTAssertEqual(accepted.item.state, .recipeReceived)
        XCTAssertNotNil(try harness.store.recipeJSON(id: id))
    }

    // MARK: - P1-1: one artifact-derived state for every observer

    /// P1-1 ①: a recipe posted **before** prepare is stored, but it is not a preview. The POST
    /// response, `GET /status` (`item(id:)`) and state.json must all say `pending` + hasRecipe.
    /// The old code wrote `recipe_received` to state.json while the API reported `pending`.
    func testPostingARecipeBeforePrepareKeepsTheThreeObserversConsistent() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        let recipe = makeRecipe(harness, source: source, id: id)

        let posted = try harness.store.storeRecipe(id: id, body: JSONEncoder().encode(recipe))

        // The three observers, compared as one value.
        let status = try harness.store.item(id: id)
        let state = try readStateJSON(work: harness.work, id: id)

        XCTAssertEqual(posted.item.state, .pending, "a recipe alone is not a preview")
        XCTAssertTrue(posted.item.hasRecipe)
        XCTAssertFalse(posted.item.previewReady)
        XCTAssertEqual(status, posted.item, "GET /status must agree with the POST response")
        XCTAssertEqual(state["state"] as? String, "pending", "state.json must agree with the API")
        XCTAssertEqual(state["state"] as? String, posted.item.state.rawValue)

        // The recipe is really on disk, the preview is really not.
        XCTAssertNotNil(try harness.store.recipeJSON(id: id))
        let directory = itemDirectory(harness, id: id)
        for name in ["preview-base.png", "preview-meta.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }

        // A prepare now completes the lifecycle: all three agree on recipe_received.
        let prepared = try harness.store.prepare(id: id)
        XCTAssertFalse(prepared.cached)
        XCTAssertEqual(prepared.item.state, .recipeReceived)
        XCTAssertEqual(try harness.store.item(id: id).state, .recipeReceived)
        XCTAssertEqual(
            try readStateJSON(work: harness.work, id: id)["state"] as? String,
            "recipe_received"
        )
    }

    /// P1-1 ②: deleting `recipe.json` must not keep reporting `recipe_received` with
    /// `hasRecipe: false`; the state follows the artifacts, and the next prepare heals state.json.
    func testDeletingTheStoredRecipeRevertsToPreviewReady() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: id)
        let recipe = makeRecipe(harness, source: source, id: id)
        let posted = try harness.store.storeRecipe(id: id, body: JSONEncoder().encode(recipe))
        XCTAssertEqual(posted.item.state, .recipeReceived)

        let directory = itemDirectory(harness, id: id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("recipe.json"))

        // Summary (GET /items, GET /status) derives from the artifacts: preview only.
        let item = try harness.store.item(id: id)
        XCTAssertEqual(item.state, .previewReady)
        XCTAssertTrue(item.previewReady)
        XCTAssertFalse(item.hasRecipe)
        XCTAssertEqual(try harness.store.listItems().first, item)

        // A warm prepare (the preview is untouched) rewrites state.json to the same derived state.
        let baseURL = directory.appendingPathComponent("preview-base.png")
        let baseSHA = try Fixture.sha256(of: baseURL)
        let warm = try harness.store.prepare(id: id)
        XCTAssertTrue(warm.cached)
        XCTAssertEqual(warm.item.state, .previewReady)
        XCTAssertFalse(warm.item.hasRecipe)
        let state = try readStateJSON(work: harness.work, id: id)
        XCTAssertEqual(state["state"] as? String, "preview_ready")
        XCTAssertNil(state["recipeRenderKey"])
        // The preview itself was not re-rendered.
        XCTAssertEqual(try Fixture.sha256(of: baseURL), baseSHA)
    }

    /// P1-1 ③: an intact preview outranks a failed attempt. This plants the record a failed
    /// prepare would leave (`failed` + lastError) while both preview artifacts are healthy: the API
    /// must report `preview_ready` (not `failed`) and hide `error`; the next prepare heals state.json.
    func testAStaleFailedRecordDoesNotHideAnIntactPreview() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: id)

        try rewriteStateJSON(work: harness.work, id: id) { state in
            state["state"] = "failed"
            state["lastError"] = "an older prepare attempt failed"
        }

        let item = try harness.store.item(id: id)
        XCTAssertEqual(item.state, .previewReady, "the artifacts are the truth, not the old failed record")
        XCTAssertTrue(item.previewReady)
        XCTAssertFalse(item.hasRecipe)
        XCTAssertNil(item.error, "ItemSummary.error is only exposed while state == failed")

        let warm = try harness.store.prepare(id: id)
        XCTAssertTrue(warm.cached)
        let state = try readStateJSON(work: harness.work, id: id)
        XCTAssertEqual(state["state"] as? String, "preview_ready", "a warm prepare heals state.json")
        XCTAssertNil(state["lastError"])
    }

    /// P1-1 ③ (persistFailure path): a prepare that fails while a good preview exists must persist
    /// the derived `preview_ready` state (with `lastError` kept as diagnostics), not `failed`.
    ///
    /// The failure is deterministic and touches no artifact: a second store configured with an
    /// invalid `previewLongEdge` (0) misses the cache (the base's recorded long edge no longer
    /// matches) and `PreviewBaseRenderer` rejects the request before writing anything. The old
    /// base/meta stay valid, which is exactly the "failed attempt must not hide the preview" case.
    func testAFailedPreparePersistsTheDerivedStateWhenThePreviewSurvives() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: id)
        let directory = itemDirectory(harness, id: id)
        let baseURL = directory.appendingPathComponent("preview-base.png")
        let metaURL = directory.appendingPathComponent("preview-meta.json")
        let baseSHA = try Fixture.sha256(of: baseURL)
        let metaSHA = try Fixture.sha256(of: metaURL)

        var broken = harness.config
        broken.previewLongEdge = 0
        let store = try ItemStore(config: broken)
        assertStoreThrows(try store.prepare(id: id), matching: isPrepareFailed)

        // A failed attempt writes nothing over the intact preview.
        XCTAssertEqual(try Fixture.sha256(of: baseURL), baseSHA)
        XCTAssertEqual(try Fixture.sha256(of: metaURL), metaSHA)

        // The API reports the preview that is actually on disk, with no error.
        let item = try store.item(id: id)
        XCTAssertEqual(item.state, .previewReady)
        XCTAssertTrue(item.previewReady)
        XCTAssertNil(item.error, "ItemSummary.error is only exposed while state == failed")

        // state.json mirrors that derived state; lastError is retained for diagnostics only.
        let state = try readStateJSON(work: harness.work, id: id)
        XCTAssertEqual(state["state"] as? String, "preview_ready", "state.json must not say failed")
        XCTAssertNotNil(state["lastError"] as? String, "lastError stays as a diagnostic")
    }

    /// P1-1 (review §6.7): a missing or corrupt state.json is a cache sidecar problem, not an item
    /// state. With both preview artifacts intact the item must still read `preview_ready`.
    func testCorruptOrMissingStateJSONDoesNotHideAnIntactPreview() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: id)
        let stateURL = itemDirectory(harness, id: id).appendingPathComponent("state.json")
        let baseURL = itemDirectory(harness, id: id).appendingPathComponent("preview-base.png")

        // Missing state.json.
        try FileManager.default.removeItem(at: stateURL)
        let missing = try harness.store.item(id: id)
        XCTAssertEqual(missing.state, .previewReady)
        XCTAssertTrue(missing.previewReady)
        XCTAssertFalse(missing.hasRecipe)
        XCTAssertNil(missing.error)

        // A prepare rebuilds state.json (state.json is part of today's cache key) and keeps serving.
        let rebuilt = try harness.store.prepare(id: id)
        XCTAssertEqual(rebuilt.item.state, .previewReady)
        XCTAssertEqual(
            try readStateJSON(work: harness.work, id: id)["state"] as? String,
            "preview_ready"
        )
        let baseSHA = try Fixture.sha256(of: baseURL)

        // Corrupt state.json.
        try Data("{ this is not a state record".utf8).write(to: stateURL)
        let corrupt = try harness.store.item(id: id)
        XCTAssertEqual(corrupt.state, .previewReady)
        XCTAssertTrue(corrupt.previewReady)
        XCTAssertFalse(corrupt.hasRecipe)
        XCTAssertNil(corrupt.error)
        XCTAssertEqual(try harness.store.prepare(id: id).item.state, .previewReady)
        XCTAssertEqual(try Fixture.sha256(of: baseURL), baseSHA)
    }

    /// P1-1: `hasRecipe` means a *decodable* stored recipe. A corrupt recipe.json is no recipe, both
    /// in the summary and in state.json written by the next prepare.
    func testCorruptRecipeJSONCountsAsNoRecipe() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let id = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: id)
        let recipe = makeRecipe(harness, source: source, id: id)
        XCTAssertEqual(
            try harness.store.storeRecipe(id: id, body: JSONEncoder().encode(recipe)).item.state,
            .recipeReceived
        )
        let recipeURL = itemDirectory(harness, id: id).appendingPathComponent("recipe.json")
        try Data("{ not a recipe".utf8).write(to: recipeURL)

        let item = try harness.store.item(id: id)
        XCTAssertEqual(item.state, .previewReady)
        XCTAssertEqual(item.previewReady, true)
        XCTAssertFalse(item.hasRecipe, "an undecodable recipe.json must not count as a stored recipe")

        let warm = try harness.store.prepare(id: id)
        XCTAssertTrue(warm.cached)
        XCTAssertEqual(warm.item.state, .previewReady)
        XCTAssertFalse(warm.item.hasRecipe)
        let state = try readStateJSON(work: harness.work, id: id)
        XCTAssertEqual(state["state"] as? String, "preview_ready")
        XCTAssertNil(state["recipeRenderKey"])
    }

    // MARK: - P1-4 hand-off: unsupported sources map to 422, not 500

    /// The colour agent (P1-4) makes a non-Display-P3 source fail decoding with
    /// `PhotonError.unsupportedSource`. The store must map that to `.sourceUnreadable` (HTTP 422),
    /// not the generic `.prepareFailed` (500), so the iPad can tell the user to re-export.
    func testUnsupportedSourceMapsToSourceUnreadable() {
        XCTAssertEqual(
            ItemStore.mapPrepareError(PhotonError.unsupportedSource(reason: "not Display P3")),
            .sourceUnreadable(message: "unsupported source: not Display P3")
        )
        // Anything else still maps to prepare_failed / source_unreadable as before.
        XCTAssertEqual(
            ItemStore.mapPrepareError(PhotonError.unsupportedOrientation(6)),
            .prepareFailed(message: PhotonError.unsupportedOrientation(6).description)
        )
    }

    // MARK: - Re-export hardening

    /// Rewrites `source` **in place** with different bytes while preserving its inode, byte count
    /// and atime/mtime exactly, so the store's (size, mtime, inode) scan memo cannot see the
    /// change. Returns the SHA-256 of the new bytes.
    ///
    /// The replacement bytes are built in a scratch file outside the batch, then written through a
    /// file handle on the original path (same inode). `FileManager.setAttributes([.modificationDate:])`
    /// round-trips through `Date` and loses a few hundred nanoseconds, and the store compares
    /// `Date`s exactly, so the raw `timespec` is restored with `futimens` instead.
    @discardableResult
    private func rewriteInPlacePreservingStat(
        _ harness: Harness,
        source: URL,
        linearValue: Float = 0.4
    ) throws -> String {
        let original = try FileManager.default.attributesOfItem(atPath: source.path)
        let originalSize = try XCTUnwrap((original[.size] as? NSNumber)?.intValue)
        let originalMTime = try XCTUnwrap(original[.modificationDate] as? Date)
        let originalInode = try XCTUnwrap((original[.systemFileNumber] as? NSNumber)?.uint64Value)
        var originalStat = stat()
        XCTAssertEqual(stat(source.path, &originalStat), 0)

        // Build different bytes for the same source elsewhere, then rewrite the file **in place**
        // (same inode, same byte count) and restore its mtime: the (size, mtime, inode) scan memo
        // cannot see the change, which is exactly the case the store's re-hash exists for.
        let replacementURL = harness.root.appendingPathComponent("replacement.tif")
        try Fixture.writeUniformP3TIFF(
            size: PixelSize(width: 96, height: 64),
            linearValue: linearValue,
            to: replacementURL
        )
        var replacement = try Data(contentsOf: replacementURL)
        if replacement.count < originalSize {
            replacement.append(contentsOf: repeatElement(UInt8(0), count: originalSize - replacement.count))
        } else {
            XCTAssertEqual(replacement.count, originalSize, "fixtures must fit the original byte length")
        }
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: replacement)
        let times = [
            timespec(tv_sec: originalStat.st_atimespec.tv_sec, tv_nsec: originalStat.st_atimespec.tv_nsec),
            timespec(tv_sec: originalStat.st_mtimespec.tv_sec, tv_nsec: originalStat.st_mtimespec.tv_nsec),
        ]
        let futimensResult = times.withUnsafeBufferPointer {
            futimens(handle.fileDescriptor, $0.baseAddress)
        }
        try handle.close()
        XCTAssertEqual(futimensResult, 0, "cannot restore the source mtime")

        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        XCTAssertEqual((after[.size] as? NSNumber)?.intValue, originalSize)
        XCTAssertEqual((after[.systemFileNumber] as? NSNumber)?.uint64Value, originalInode)
        XCTAssertEqual(after[.modificationDate] as? Date, originalMTime, "the test must preserve mtime exactly")
        return try Fixture.sha256(of: source)
    }

    func testInPlaceReExportIsDetectedEvenWhenSizeAndMTimeArePreserved() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let firstID = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: firstID)

        let secondID = try rewriteInPlacePreservingStat(harness, source: source)
        XCTAssertNotEqual(firstID, secondID)

        // The scan memo still maps the path to the old id: size, mtime and inode are unchanged.
        XCTAssertEqual(try harness.store.listItems().map(\.id), [firstID])

        // prepare re-hashes and refuses the stale id, refreshing the memo.
        assertStoreThrows(try harness.store.prepare(id: firstID), matching: isSourceChanged)

        let items = try harness.store.listItems()
        XCTAssertEqual(items.map(\.id), [secondID], "the memo must have been refreshed after the mismatch")
        XCTAssertEqual(items.count, 1)
        assertStoreThrows(try harness.store.item(id: firstID), matching: isUnknownItem)
        XCTAssertEqual(try harness.store.item(id: secondID).state, .pending)
    }

    func testPostedRecipeAfterAnInPlaceReExportIsSourceChanged() throws {
        let harness = try makeHarness()
        let source = try writeSource(harness)
        let firstID = try Fixture.sha256(of: source)
        _ = try harness.store.prepare(id: firstID)

        let secondID = try rewriteInPlacePreservingStat(harness, source: source)
        XCTAssertNotEqual(firstID, secondID)

        // The scan memo still maps the path to the old id: size, mtime and inode are unchanged.
        XCTAssertEqual(try harness.store.listItems().map(\.id), [firstID])

        // A valid recipe for the old bytes must be refused as source_changed (409), not accepted
        // into the old id directory (docs/reference/wire.md, M2.1 wire contract); the refusal must also refresh the memo.
        let sourceInfo = Recipe.Source(
            path: source.standardizedFileURL.path,
            sha256: firstID,
            width: 96,
            height: 64
        )
        let versions = Recipe.Versions(encoder: harness.config.encoderVersion)
        let valid = Recipe(
            source: sourceInfo,
            versions: versions,
            created: "2026-11-02T22:00:00+08:00"
        )
        assertStoreThrows(
            try harness.store.storeRecipe(id: firstID, body: JSONEncoder().encode(valid)),
            matching: isSourceChanged
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: itemDirectory(harness, id: firstID).appendingPathComponent("recipe.json").path
            ),
            "a refused recipe must not be stored"
        )

        let items = try harness.store.listItems()
        XCTAssertEqual(items.map(\.id), [secondID], "the memo must have been refreshed by the refused post")
        XCTAssertEqual(items.count, 1)
        assertStoreThrows(try harness.store.recipeJSON(id: firstID), matching: isUnknownItem)
        XCTAssertEqual(try harness.store.item(id: secondID).state, .pending)
    }
}

// MARK: - Fixtures

/// Generated-at-run-time 16-bit Display P3 TIFFs — the same shape as a Capture One SDR export.
private enum Fixture {
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

    static func writeUniformP3TIFF(size: PixelSize, linearValue: Float, to url: URL) throws {
        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .outputColorSpace: linearP3,
            .cacheIntermediates: false,
        ])
        let image = CIImage(
            color: CIColor(
                red: CGFloat(linearValue),
                green: CGFloat(linearValue),
                blue: CGFloat(linearValue),
                alpha: 1,
                colorSpace: linearP3
            )!
        ).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)))
        try context.writeTIFFRepresentation(
            of: image,
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
