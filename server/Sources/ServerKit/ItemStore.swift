import Foundation
import ImageIO
import EngineKit
import ContractKit

/// The on-disk batch store behind the M2.1 API.
///
/// M2.1 contract: `prepare` renders **only** the SDR base preview (a 16-bit Display P3 PNG) via
/// `PreviewBaseRenderer`; there is no HDR rendition, no gain-map HEIC and no encoder in this path.
/// The iPad authors HDR from the base + a recipe (docs/reference/wire.md, M2.1 wire contract).
///
/// Layout per item (`work/<source sha256>/`):
///   `preview-base.png`  the 16-bit P3 base the iPad downloads (`PreviewBaseRenderer.fileName`)
///   `preview-meta.json` `PreviewMetadata` (source identity, base facts, recipe defaults)
///   `state.json`        item lifecycle record (this store's own record; see `StateRecord`)
///   `recipe.json`       the last validated recipe posted by the iPad (`Recipe.canonicalJSON()`)
///
/// Identity is the source file's SHA-256, never its path: a re-export produces a new id, and a
/// stored recipe whose `source.sha256` no longer matches must be refused (docs/reference/operations.md).
///
/// Both `prepare` and `storeRecipe` re-hash the source before any cache or recipe decision, so an
/// in-place re-export is detected even when the scan memo's (size, mtime, inode) key is unchanged.
/// The cost is one streaming SHA-256 per call (≈0.1–0.3 s for a 150 MB TIFF) while the store lock
/// is held. `/api/health` does not take that lock (`itemCount()` has its own — review P1-8), so the
/// M3 reachability probe stays responsive while the hash/render runs.
///
/// The store is the only place that decides cache validity; it must not invent a renderer of its
/// own — `prepare` always goes through `PreviewBaseRenderer`.
///
/// Threading: `HTTPServer` calls these methods from arbitrary background threads, so every public
/// method takes one non-recursive lock. `prepare` holds it while the base renders, which serialises
/// renders — acceptable for stage 1's single user (docs/reference/operations.md "one iPad at a time").
public final class ItemStore: ItemStoreProtocol {
    public let config: ServerConfig

    /// Standardised roots: scan results and the renderer must agree on the exact path string.
    private let batchDirectory: URL
    private let workDirectory: URL

    private let fileManager = FileManager.default

    /// One lock for all public methods. Non-recursive: private helpers assume it is held and must
    /// never be called while it is not.
    private let lock = NSLock()

    /// `itemCount()`'s own lock. Deliberately **not** `lock`: `/api/health` is the M3 reachability
    /// probe and must answer while a cold `prepare` (or a re-hash of a 150 MB source) holds the
    /// main lock, which can take seconds (review P1-8). `nil` = cold; a published value is an
    /// advisory snapshot, refreshed by every `scanLocked()`.
    private let countLock = NSLock()
    private var cachedItemCount: Int?

    /// In-flight thumbnail renders, keyed by item id, guarded by `thumbnailCondition`. Two callers
    /// for the same item must not each render it: the second waits for the first's result. This is
    /// the same path the `serve` warm-up and an HTTP request share (ADR-0013 §6), and it is
    /// deliberately **not** the main `lock` — the render runs with no store lock held.
    private final class ThumbnailFlight {
        var finished = false
        var data: Data?
        var error: ItemStoreError?
    }
    private let thumbnailCondition = NSCondition()
    private var thumbnailFlights: [String: ThumbnailFlight] = [:]

    /// File names inside `work/<id>/`. `preview-base.png` comes from the renderer so the writer and
    /// this reader can never disagree about the transport artifact's name.
    private enum Artifact {
        static let state = "state.json"
        static let previewBase = PreviewBaseRenderer.fileName
        static let previewMeta = "preview-meta.json"
        static let recipe = "recipe.json"
        /// The filmstrip thumbnail (ADR-0013). Deliberately **not** part of `artifactStateLocked`:
        /// an item that only has a thumbnail is still `pending`.
        static let thumbnail = ThumbnailRenderer.fileName()
    }

    /// Memoised source hashes, keyed by standardised source path. Re-hashing a 150 MB TIFF on every
    /// `/api/health` probe would be absurd; an entry is reused only while size, mtime **and inode**
    /// are unchanged. A re-export normally creates a new file (new inode), so it re-hashes; and
    /// `prepare` re-hashes the source anyway before serving a cache hit, which makes re-export
    /// detection authoritative even when size+mtime+inode are all preserved (docs/reference/operations.md).
    private struct CachedHash: Equatable {
        let bytes: Int64
        let modifiedAt: Date
        let inode: UInt64
        let sha256: String
    }
    private var hashCache: [String: CachedHash] = [:]

    /// `state.json`: this store's own record beside the preview artifacts.
    ///
    /// Field names are the documented M2 shape (task board): id, name, sourcePath, sourceSHA,
    /// state, width, height, recipeRenderKey, appVersion, encoderVersion, lastError, updatedAt.
    /// Optional fields are omitted when nil; `updatedAt` is RFC 3339 (`ISO8601DateFormatter`-style).
    /// `width`/`height` are the *source* pixel size (decoded), not the downscaled base size.
    struct StateRecord: Codable {
        var id: String
        var name: String
        var sourcePath: String
        var sourceSHA: String
        var state: ItemState
        var width: Int?
        var height: Int?
        var recipeRenderKey: String?
        var appVersion: String
        var encoderVersion: String
        var lastError: String?
        var updatedAt: Date
    }

    /// One source file known to the current batch. `id` is the SHA-256 of its bytes.
    private struct ScannedItem {
        let id: String
        let name: String
        let url: URL
    }

    private struct CacheHit {
        let meta: PreviewMetadata
        let record: StateRecord
    }

    // MARK: - Init

    /// Validates the batch directory and creates the work directory. Deliberately cheap: no source
    /// is hashed until the first listing/prepare, so the server starts instantly.
    public init(config: ServerConfig) throws {
        self.config = config
        self.batchDirectory = config.batchDirectory.standardizedFileURL
        self.workDirectory = config.workDirectory.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: batchDirectory.path, isDirectory: &isDirectory) else {
            throw ItemStoreError.io(message: "batch directory does not exist: \(batchDirectory.path)")
        }
        guard isDirectory.boolValue else {
            throw ItemStoreError.io(message: "batch path is not a directory: \(batchDirectory.path)")
        }

        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            throw ItemStoreError.io(
                message: "cannot create work directory '\(workDirectory.path)': \(error)"
            )
        }
    }

    // MARK: - Listing (never renders)

    /// Cheap item count for /api/health.
    ///
    /// Contract (docs/reference/wire.md, M2.1 wire contract / `ItemStoreProtocol`): counts source **files** without hashing them,
    /// so duplicate content can make the count larger than the number of distinct items reported by
    /// `listItems()`. The first (cold) probe lists the batch directory once; the value is then
    /// cached and refreshed by every `scanLocked()` (`listItems` / `prepare` / `item`). It can
    /// briefly lag a file added since the last scan — acceptable for a reachability probe, and the
    /// list is the authoritative view.
    ///
    /// Threading: uses only `countLock`, never the main `lock`, and never scans or hashes, so a
    /// cold `prepare` holding `lock` cannot block `/api/health` (review P1-8).
    public func itemCount() throws -> Int {
        countLock.lock()
        let cached = cachedItemCount
        countLock.unlock()
        if let cached { return cached }

        // Cold: this is the one directory listing the probe is allowed to do. It runs without the
        // main lock on purpose (see the doc comment above).
        let count = try countBatchFiles()
        publishItemCount(count)
        return count
    }

    /// Publishes a scan's source-file count for `itemCount()`. Called at the end of `scanLocked()`;
    /// no main lock is required for `countLock`.
    private func publishItemCount(_ count: Int) {
        countLock.lock()
        cachedItemCount = count
        countLock.unlock()
    }

    public func listItems() throws -> [ItemSummary] {
        lock.lock()
        defer { lock.unlock() }
        return try scanLocked().map { summaryLocked(for: $0) }
    }

    public func item(id: String) throws -> ItemSummary {
        lock.lock()
        defer { lock.unlock() }
        return try summaryLocked(for: resolveLocked(id: id))
    }

    // MARK: - Prepare (the only renderer path)

    /// Idempotent render of the SDR base preview (16-bit P3 PNG). No encoder, no HDR.
    ///
    /// Cache hit (returns `cached: true` and writes nothing) requires **all** of:
    ///   - `state.json`, `preview-base.png` and `preview-meta.json` exist;
    ///   - `state.sourceSHA == id` and `state.appVersion == config.appVersion`;
    ///   - `preview-meta.json` decodes to `PreviewMetadata`;
    ///   - `meta.source.sha256 == id` and `meta.base.longEdge == config.previewLongEdge`;
    ///   - the PNG on disk still has `meta.base.bytes` bytes and `meta.base.sha256` on disk
    ///     (the bytes are re-hashed: a truncated/replaced PNG must not be served as a cache hit).
    ///
    /// `state.encoderVersion` is deliberately *not* part of the cache key: M2.1 never runs the
    /// encoder, so a new encoder commit cannot invalidate the base.
    ///
    /// Anything else is a cache miss: `PreviewBaseRenderer` runs, and its facts become the new
    /// `preview-meta.json` / `state.json`.
    public func prepare(id: String) throws -> PrepareResponse {
        lock.lock()
        defer { lock.unlock() }

        let item = try resolveLocked(id: id)
        let directory = itemDirectory(for: item.id)
        try verifySourceIdentityLocked(item: item)

        if let hit = cacheHitLocked(for: item) {
            reconcileStateLocked(hit.record, for: item, meta: hit.meta, directory: directory)
            return PrepareResponse(item: summaryLocked(for: item), meta: hit.meta, cached: true)
        }

        let result: PreviewBaseResult
        do {
            result = try PreviewBaseRenderer.render(
                sourceURL: item.url,
                longEdge: config.previewLongEdge,
                to: directory
            )
        } catch {
            let mapped = Self.mapPrepareError(error)
            persistFailureLocked(item: item, directory: directory, error: mapped)
            throw mapped
        }

        // The source was re-exported between the identity check and the decode: the artifacts now
        // describe different bytes than the item id, so they must not be cached under `id`. This is
        // a race, not a normal path (one user, one Mac), but treating it as a cache entry would
        // poison it.
        guard result.sourceSHA256 == item.id else {
            refreshMemoEntryLocked(for: item.url, sha256: result.sourceSHA256)
            let mapped = ItemStoreError.sourceChanged(expected: item.id, actual: result.sourceSHA256)
            persistFailureLocked(item: item, directory: directory, error: mapped)
            throw mapped
        }

        let meta = makePreviewMetadataLocked(from: result, item: item)
        do {
            let data = try Self.makeMetadataEncoder().encode(meta) + Data("\n".utf8)
            try writeAtomically(data, to: directory.appendingPathComponent(Artifact.previewMeta))
        } catch {
            let mapped = ItemStoreError.io(
                message: "cannot write \(Artifact.previewMeta) for item \(id): \(error)"
            )
            persistFailureLocked(item: item, directory: directory, error: mapped)
            throw mapped
        }

        // A recipe posted earlier survives a cache-invalidating re-prepare: the item id (the source
        // hash) still identifies the same source, so the recipe remains valid. The record's state
        // and render key are derived from the artifacts that just landed (the same derivation the
        // API summary uses), never assumed — review P1-1.
        let artifacts = artifactStateLocked(in: directory, previous: nil)
        let record = StateRecord(
            id: item.id,
            name: item.name,
            sourcePath: item.url.path,
            sourceSHA: item.id,
            state: artifacts.state,
            width: result.sourceSize.width,
            height: result.sourceSize.height,
            recipeRenderKey: artifacts.recipe.flatMap { try? $0.renderKey() },
            appVersion: config.appVersion,
            encoderVersion: config.encoderVersion,
            lastError: nil,
            updatedAt: Date()
        )
        try writeStateLocked(record, directory: directory)

        return PrepareResponse(item: summaryLocked(for: item), meta: meta, cached: false)
    }

    // MARK: - Thumbnail (renders without the main lock)

    /// The 512-high Display P3 HEIC the filmstrip shows (ADR-0013).
    ///
    /// Deliberately **not** `prepare`: browsing must never render the 2560 px base, so this path
    /// touches `ThumbnailRenderer` only. The main `lock` is held for the resolve + cache lookup and
    /// not at all while the render runs, so a cold thumbnail cannot block `/api/health` (it has its
    /// own `countLock`) or another item's request. The renderer's write is already atomic
    /// (`AtomicFile.replace`), so no lock is needed around it either.
    ///
    /// Cache hit: `thumbnail-512-v1.heic` exists, ImageIO can open it, and its header height is in
    /// `1...512` (a truncation/corruption guard — the file name is the real key, so a source
    /// shorter than 512 px still caches). Only properties are read — never pixels. The file name
    /// carries the height and the renderer tag, so changing either invalidates the cache without
    /// putting `appVersion` into the key (ADR-0013 §5).
    ///
    /// In-flight de-duplication is per item id: a second caller waits for the first render instead
    /// of repeating it. A failure never changes the item state — there is no `persistFailureLocked`
    /// here — so the item stays `pending` and the filmstrip falls back to the file name
    /// (ADR-0013 §7).
    public func thumbnail(id: String) throws -> Data {
        lock.lock()
        let item: ScannedItem
        let directory: URL
        do {
            item = try resolveLocked(id: id)
            directory = itemDirectory(for: item.id)
            if let cached = cachedThumbnailLocked(in: directory) {
                lock.unlock()
                return cached
            }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        // Join or start the in-flight render for this item. Waiting here releases the condition
        // lock, so the owner's render is never blocked by waiters.
        thumbnailCondition.lock()
        if let flight = thumbnailFlights[item.id] {
            while !flight.finished {
                thumbnailCondition.wait()
            }
            thumbnailCondition.unlock()
            if let data = flight.data { return data }
            throw flight.error ?? ItemStoreError.prepareFailed(
                message: "thumbnail render failed for item \(item.id)"
            )
        }
        let flight = ThumbnailFlight()
        thumbnailFlights[item.id] = flight
        thumbnailCondition.unlock()

        let data: Data
        do {
            let result = try ThumbnailRenderer.render(sourceURL: item.url, to: directory)
            data = try Self.readThumbnailBytes(at: result.url)
        } catch {
            let mapped = Self.mapPrepareError(error)
            finishThumbnailFlight(flight, itemID: item.id, error: mapped)
            throw mapped
        }
        finishThumbnailFlight(flight, itemID: item.id, data: data)
        return data
    }

    /// Publishes a finished in-flight render to its waiters and removes it from the table.
    private func finishThumbnailFlight(
        _ flight: ThumbnailFlight,
        itemID: String,
        data: Data? = nil,
        error: ItemStoreError? = nil
    ) {
        thumbnailCondition.lock()
        flight.data = data
        flight.error = error
        flight.finished = true
        thumbnailFlights[itemID] = nil
        thumbnailCondition.broadcast()
        thumbnailCondition.unlock()
    }

    /// The thumbnail cache-hit rule (ADR-0013 §5); reads the HEIC header, never its pixels.
    ///
    /// The file name already encodes the target height and the renderer tag, so a file at this path
    /// was produced by this renderer for this target: the header height is only a truncation /
    /// corruption guard, not the cache key. That is why the accepted range is `1...height` rather
    /// than exactly `height` — ImageIO never upscales, so a source shorter than the target produces
    /// a shorter thumbnail, and demanding exactly 512 would re-render it on every request.
    private func cachedThumbnailLocked(in directory: URL) -> Data? {
        let url = directory.appendingPathComponent(Artifact.thumbnail)
        guard fileManager.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...ThumbnailRenderer.height).contains(height)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func readThumbnailBytes(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ItemStoreError.io(message: "cannot read '\(url.path)': \(error)")
        }
    }

    // MARK: - Artifact reads

    public func metadataJSON(id: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let item = try resolveLocked(id: id)
        return try readArtifactLocked(
            item: item,
            fileName: Artifact.previewMeta,
            missingMessage: "no \(Artifact.previewMeta) for item \(id) yet; call prepare first"
        )
    }

    public func previewPNG(id: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let item = try resolveLocked(id: id)
        return try readArtifactLocked(
            item: item,
            fileName: Artifact.previewBase,
            missingMessage: "no \(Artifact.previewBase) for item \(id) yet; call prepare first"
        )
    }

    public func recipeJSON(id: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let item = try resolveLocked(id: id)
        let url = itemDirectory(for: item.id).appendingPathComponent(Artifact.recipe)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ItemStoreError.io(message: "cannot read '\(url.path)': \(error)")
        }
    }

    // MARK: - Recipe store

    public func storeRecipe(id: String, body: Data) throws -> RecipePostResponse {
        lock.lock()
        defer { lock.unlock() }

        let item = try resolveLocked(id: id)
        // A stale id outranks recipe-body problems: after an in-place re-export that preserved
        // size/mtime/inode, this id names old bytes, so the answer is 409 `source_changed`, not a
        // 400 for whatever the body happens to contain. This re-hashes and refreshes the memo
        // exactly like `prepare` does.
        try verifySourceIdentityLocked(item: item)
        let directory = itemDirectory(for: item.id)

        let recipe: Recipe
        do {
            recipe = try JSONDecoder().decode(Recipe.self, from: body)
        } catch {
            throw ItemStoreError.invalidRecipe(message: "cannot decode recipe JSON: \(error)")
        }

        do {
            try recipe.validate()
        } catch let error as PhotonError {
            throw ItemStoreError.invalidRecipe(message: error.description)
        } catch {
            throw ItemStoreError.invalidRecipe(message: "invalid recipe: \(error)")
        }

        // Re-export detection: a recipe is only ever stored beside the source it was made for
        // (docs/reference/operations.md). The router maps this to HTTP 409 `source_changed`.
        guard recipe.source.sha256.lowercased() == item.id else {
            throw ItemStoreError.sourceChanged(expected: item.id, actual: recipe.source.sha256)
        }

        // Decoded dimensions are part of the contract (docs/reference/recipe.md, "must equal the decoded image");
        // once a prepare has decoded this source we know the truth and can enforce it here.
        let existing = readStateLocked(in: directory)
        if let existing, let width = existing.width, let height = existing.height,
           recipe.source.width != width || recipe.source.height != height {
            throw ItemStoreError.invalidRecipe(
                message: "recipe source size \(recipe.source.width)x\(recipe.source.height) "
                    + "does not match the prepared item size \(width)x\(height)"
            )
        }

        let renderKey: String
        let canonical: Data
        do {
            renderKey = try recipe.renderKey()
            canonical = try recipe.canonicalJSON()
        } catch {
            throw ItemStoreError.io(message: "cannot encode the recipe for item \(id): \(error)")
        }
        try writeAtomically(canonical, to: directory.appendingPathComponent(Artifact.recipe))

        // Persist the state the API would report *now*: with no preview artifacts the item stays
        // `.pending` (a recipe alone is not a preview — review P1-1 fix ①), with a preview it
        // becomes `.recipeReceived`. `lastError` is only kept as diagnostics when the derived state
        // is still `.failed` (no surviving preview).
        let artifacts = artifactStateLocked(in: directory, previous: existing)
        var record = existing ?? StateRecord(
            id: item.id,
            name: item.name,
            sourcePath: item.url.path,
            sourceSHA: item.id,
            state: artifacts.state,
            width: nil,
            height: nil,
            recipeRenderKey: nil,
            appVersion: config.appVersion,
            encoderVersion: config.encoderVersion,
            lastError: nil,
            updatedAt: Date()
        )
        record.id = item.id
        record.name = item.name
        record.sourcePath = item.url.path
        record.sourceSHA = item.id
        record.state = artifacts.state
        record.recipeRenderKey = renderKey
        record.appVersion = config.appVersion
        record.encoderVersion = config.encoderVersion
        if artifacts.state != .failed {
            record.lastError = nil
        }
        record.updatedAt = Date()
        try writeStateLocked(record, directory: directory)

        return RecipePostResponse(item: summaryLocked(for: item), recipe: recipe, renderKey: renderKey)
    }

    // MARK: - Batch scan (lock held)

    /// The current batch: regular, non-hidden `.tif`/`.tiff` files, sorted by file name.
    ///
    /// Duplicate content collapses to **one** item: the first file in name order is the canonical
    /// name/path for that SHA-256 (the id identifies bytes, not a location). The duplicate file is
    /// still present in the folder and will take over if the first one disappears on a later scan.
    ///
    /// A file that cannot be stat'ed or hashed is skipped rather than failing the whole batch: one
    /// unreadable source must not make `/api/items` (or `/api/health`) unusable, and the next scan
    /// retries it. Hashing is memoised on (size, mtime, inode).
    private func scanLocked() throws -> [ScannedItem] {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: batchDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ItemStoreError.io(
                message: "cannot list batch directory '\(batchDirectory.path)': \(error)"
            )
        }

        var items: [ScannedItem] = []
        var seenIDs = Set<String>()
        var freshCache: [String: CachedHash] = [:]
        // `itemCount()` counts source *files* (duplicates included), which is not the same as
        // `items.count` (duplicate content collapses to one id). Count the regular TIFFs as we walk
        // them so the scan can refresh the health cache without a second directory listing.
        var sourceFileCount = 0

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            guard Self.isTIFFName(name) else { continue }

            let url = entry.standardizedFileURL
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            sourceFileCount += 1

            let path = url.path
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: path)
            } catch {
                continue
            }
            guard let bytes = (attributes[.size] as? NSNumber)?.int64Value,
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            else { continue }

            let sha256: String
            if let cached = hashCache[path],
               cached.bytes == bytes,
               cached.modifiedAt == modifiedAt,
               cached.inode == inode {
                sha256 = cached.sha256
            } else {
                do {
                    sha256 = try SourceDecoder.sha256(ofFileAt: url)
                } catch {
                    continue
                }
            }
            freshCache[path] = CachedHash(bytes: bytes, modifiedAt: modifiedAt, inode: inode, sha256: sha256)

            guard seenIDs.insert(sha256).inserted else { continue }
            items.append(ScannedItem(id: sha256, name: name, url: url))
        }

        // Drop entries for files that left the batch, so the memo cannot grow without bound.
        hashCache = freshCache
        publishItemCount(sourceFileCount)
        return items
    }

    /// The cheap `/api/health` count: TIF(F) regular files in the batch, no hashing, no main lock.
    /// Same filter as `scanLocked()`, so the published count and a scan agree on what an item is.
    private func countBatchFiles() throws -> Int {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: batchDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ItemStoreError.io(
                message: "cannot list batch directory '\(batchDirectory.path)': \(error)"
            )
        }
        var count = 0
        for entry in entries where Self.isTIFFName(entry.lastPathComponent) {
            if (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    private static func isTIFFName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasSuffix(".tif") || lowercased.hasSuffix(".tiff")
    }

    /// Resolves an opaque client id against the current batch. The returned URL is the scanned
    /// on-disk path — a client id only ever selects an item, it never becomes a path itself.
    private func resolveLocked(id: String) throws -> ScannedItem {
        guard let item = try scanLocked().first(where: { $0.id == id }) else {
            throw ItemStoreError.unknownItem(id: id)
        }
        return item
    }

    /// Re-hashes the resolved source and refuses to serve anything under a stale id.
    ///
    /// The scan memo is only an optimisation; the item id is defined as the SHA-256 of the bytes.
    /// If the file was rewritten while size/mtime/inode stayed the same (an in-place re-export),
    /// the memo is stale — refresh it and report `.sourceChanged` so the client re-lists and picks
    /// up the new id. Called by both `prepare` and `storeRecipe` before any cache or recipe
    /// decision, so the two entry points always agree on which bytes an id names.
    ///
    /// Cost: one streaming SHA-256 per `prepare` and per recipe POST (≈0.1–0.3 s for a 150 MB
    /// TIFF), held under the store lock. `/api/health` does not take that lock (`itemCount()` has
    /// its own), so the reachability probe is not blocked by this hash (review P1-8).
    private func verifySourceIdentityLocked(item: ScannedItem) throws {
        let actual: String
        do {
            actual = try SourceDecoder.sha256(ofFileAt: item.url)
        } catch {
            throw ItemStoreError.sourceUnreadable(
                message: "cannot re-read source '\(item.url.path)' for item \(item.id): \(error)"
            )
        }
        guard actual == item.id else {
            refreshMemoEntryLocked(for: item.url, sha256: actual)
            throw ItemStoreError.sourceChanged(expected: item.id, actual: actual)
        }
    }

    /// Replace the memo entry for a path after re-hashing it out of band.
    private func refreshMemoEntryLocked(for url: URL, sha256: String) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let bytes = (attributes[.size] as? NSNumber)?.int64Value,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            hashCache[url.path] = nil
            return
        }
        hashCache[url.path] = CachedHash(bytes: bytes, modifiedAt: modifiedAt, inode: inode, sha256: sha256)
    }

    private func itemDirectory(for id: String) -> URL {
        workDirectory.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Summaries (lock held)

    /// What the artifacts on disk say about an item.
    ///
    /// `summary`, the state.json written by `prepare` / `storeRecipe` / `persistFailure` and the
    /// reconciliation of an old record all agree because they all read `artifactStateLocked`
    /// (review P1-1). The state is a *consequence* of the artifacts, never an independent variable:
    ///
    ///   - `preview-base.png` + `preview-meta.json` + a decodable `recipe.json` → `.recipeReceived`
    ///   - `preview-base.png` + `preview-meta.json` → `.previewReady`
    ///   - no usable preview, and a stored `.failed` record → `.failed`
    ///   - otherwise → `.pending`
    ///
    /// A `thumbnail-*.heic` is deliberately not consulted: only having a thumbnail is still
    /// `.pending` (ADR-0013 §7), because a filmstrip thumbnail is not a preview.
    ///
    /// A corrupt/undecodable `recipe.json` counts as **no recipe** (the API contract's `hasRecipe`
    /// means a usable stored recipe), and a failed attempt never hides a surviving preview: when
    /// the preview artifacts are there the state is derived from them and `lastError` is only
    /// diagnostics in state.json (`ItemSummary.error` is still nil unless state == .failed).
    private struct ArtifactState {
        let state: ItemState
        let hasPreview: Bool
        let hasRecipe: Bool
        /// The decoded stored recipe, or nil when absent/corrupt. Callers reuse it for render keys.
        let recipe: Recipe?
    }

    private func artifactStateLocked(in directory: URL, previous: StateRecord?) -> ArtifactState {
        // Only the preview pair counts. `thumbnail-*.heic` is intentionally absent here: a
        // thumbnail is not a preview (ADR-0013 §7).
        let hasPreview = fileManager.fileExists(
            atPath: directory.appendingPathComponent(Artifact.previewBase).path
        ) && fileManager.fileExists(
            atPath: directory.appendingPathComponent(Artifact.previewMeta).path
        )
        let recipe = storedRecipeLocked(in: directory)
        let hasRecipe = recipe != nil

        let state: ItemState
        if hasPreview && hasRecipe {
            state = .recipeReceived
        } else if hasPreview {
            state = .previewReady
        } else if previous?.state == .failed {
            state = .failed
        } else {
            state = .pending
        }
        return ArtifactState(state: state, hasPreview: hasPreview, hasRecipe: hasRecipe, recipe: recipe)
    }

    private func summaryLocked(for item: ScannedItem) -> ItemSummary {
        let directory = itemDirectory(for: item.id)
        let record = readStateLocked(in: directory)
        let artifacts = artifactStateLocked(in: directory, previous: record)

        return ItemSummary(
            id: item.id,
            name: item.name,
            path: item.url.path,
            state: artifacts.state,
            previewReady: artifacts.hasPreview,
            hasRecipe: artifacts.hasRecipe,
            width: record?.width,
            height: record?.height,
            error: artifacts.state == .failed ? record?.lastError : nil
        )
    }

    // MARK: - Preview metadata (lock held)

    /// The documented `preview-meta.json` payload: source identity + decoded source facts, the base
    /// the iPad downloads, and the recipe defaults its sliders start from.
    private func makePreviewMetadataLocked(from result: PreviewBaseResult, item: ScannedItem) -> PreviewMetadata {
        let timestamp = Recipe.currentTimestamp()
        return PreviewMetadata(
            source: PreviewMetadata.SourceInfo(
                path: item.url.path,
                sha256: item.id,
                width: result.sourceSize.width,
                height: result.sourceSize.height,
                profileName: result.profileName,
                bitsPerComponent: result.bitsPerComponent
            ),
            base: PreviewMetadata.BaseInfo(
                file: result.base.url.lastPathComponent,
                bytes: result.base.bytes,
                sha256: result.base.sha256,
                width: result.base.size.width,
                height: result.base.size.height,
                format: result.base.format,
                workingSpace: result.workingSpace,
                profileName: result.base.profileName,
                longEdge: result.longEdge
            ),
            recipeDefaults: Recipe.defaults(
                sourcePath: item.url.path,
                sourceSHA256: item.id,
                width: result.sourceSize.width,
                height: result.sourceSize.height,
                encoderVersion: config.encoderVersion,
                encoder: config.encoderProfile,
                created: timestamp
            ),
            appVersion: config.appVersion,
            createdAt: timestamp
        )
    }

    // MARK: - Cache hit (lock held)

    /// The exact M2.1 cache-hit rule; see `prepare`'s documentation. Returns `nil` on any doubt.
    private func cacheHitLocked(for item: ScannedItem) -> CacheHit? {
        let directory = itemDirectory(for: item.id)
        guard let record = readStateLocked(in: directory),
              record.sourceSHA == item.id,
              record.appVersion == config.appVersion
        else { return nil }

        let baseURL = directory.appendingPathComponent(Artifact.previewBase)
        let metadataURL = directory.appendingPathComponent(Artifact.previewMeta)
        guard fileManager.fileExists(atPath: baseURL.path),
              let metadataData = try? Data(contentsOf: metadataURL),
              let meta = try? JSONDecoder().decode(PreviewMetadata.self, from: metadataData)
        else { return nil }

        guard meta.source.sha256 == item.id,
              meta.base.longEdge == config.previewLongEdge
        else { return nil }

        // Verify the transport artifact is still the one meta describes. The PNG is small next to
        // the source (~24 MB at 2560 px), so re-hashing it on a warm request is cheap.
        guard let attributes = try? fileManager.attributesOfItem(atPath: baseURL.path),
              let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              byteCount == meta.base.bytes,
              let baseSHA = try? SourceDecoder.sha256(ofFileAt: baseURL),
              baseSHA == meta.base.sha256
        else { return nil }

        return CacheHit(meta: meta, record: record)
    }

    /// A cache hit can be served even when `state.json` is incomplete (e.g. written by an older
    /// build without width/height): fill it in then. A consistent record is left untouched, so a
    /// warm `prepare` does not rewrite anything on disk.
    ///
    /// The desired state is derived from the artifacts (`artifactStateLocked`), not assumed from
    /// the recipe alone: a deleted/corrupt `recipe.json` must heal a stale `.recipeReceived` record
    /// back to `.previewReady` (review P1-1 fix ②), and an intact preview must heal a stale
    /// `.failed` record (fix ③). `lastError` is cleared because the preview demonstrably works.
    private func reconcileStateLocked(
        _ existing: StateRecord,
        for item: ScannedItem,
        meta: PreviewMetadata,
        directory: URL
    ) {
        let artifacts = artifactStateLocked(in: directory, previous: existing)
        let desiredState = artifacts.state
        let desiredRenderKey = artifacts.recipe.flatMap { try? $0.renderKey() }

        let needsWrite = existing.state != desiredState
            || existing.width != meta.source.width
            || existing.height != meta.source.height
            || existing.lastError != nil
            || existing.recipeRenderKey != desiredRenderKey
            || existing.name != item.name
            || existing.sourcePath != item.url.path
        guard needsWrite else { return }

        var record = existing
        record.name = item.name
        record.sourcePath = item.url.path
        record.state = desiredState
        record.width = meta.source.width
        record.height = meta.source.height
        record.recipeRenderKey = desiredRenderKey
        record.lastError = nil
        record.updatedAt = Date()
        try? writeStateLocked(record, directory: directory)
    }

    // MARK: - State persistence (lock held)

    private func readStateLocked(in directory: URL) -> StateRecord? {
        let url = directory.appendingPathComponent(Artifact.state)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.makeStateDecoder().decode(StateRecord.self, from: data)
        } catch {
            // A corrupt/foreign state file is treated as "no state": `prepare` re-renders and
            // rewrites it, instead of the whole item failing over a cache sidecar.
            return nil
        }
    }

    private func writeStateLocked(_ record: StateRecord, directory: URL) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(record) + Data("\n".utf8)
        } catch {
            throw ItemStoreError.io(message: "cannot encode state for item \(record.id): \(error)")
        }
        try writeAtomically(data, to: directory.appendingPathComponent(Artifact.state))
    }

    /// Records a failed prepare attempt.
    ///
    /// state.json gets the **same artifact-derived state** the API reports: a surviving preview
    /// keeps the item `preview_ready`/`recipe_received` (a failed retry must not hide a good
    /// preview — review P1-1 fix ③) and only a genuine no-preview failure persists `.failed`.
    /// `lastError` is always stored as diagnostics; `ItemSummary.error` exposes it to the client
    /// only while the state is `.failed`.
    private func persistFailureLocked(
        item: ScannedItem,
        directory: URL,
        error: ItemStoreError
    ) {
        let previous = readStateLocked(in: directory)
        var record = StateRecord(
            id: item.id,
            name: item.name,
            sourcePath: item.url.path,
            sourceSHA: item.id,
            state: .failed,
            width: previous?.width,
            height: previous?.height,
            recipeRenderKey: previous?.recipeRenderKey,
            appVersion: config.appVersion,
            encoderVersion: config.encoderVersion,
            lastError: Self.message(for: error),
            updatedAt: Date()
        )
        // Derive with the record we are about to write, so "no preview + attempted failure" really
        // lands on `.failed`; an intact preview overrides it with its ready state.
        let artifacts = artifactStateLocked(in: directory, previous: record)
        record.state = artifacts.state
        record.recipeRenderKey = artifacts.recipe.flatMap { try? $0.renderKey() }
        // Best effort: the original error is the one worth reporting. If this write fails the next
        // prepare simply retries from a cold cache.
        try? writeStateLocked(record, directory: directory)
    }

    private func storedRecipeLocked(in directory: URL) -> Recipe? {
        let url = directory.appendingPathComponent(Artifact.recipe)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Recipe.self, from: data)
    }

    private static func makeStateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeMetadataEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: - Artifact reading (lock held)

    private func readArtifactLocked(
        item: ScannedItem,
        fileName: String,
        missingMessage: String
    ) throws -> Data {
        let url = itemDirectory(for: item.id).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ItemStoreError.prepareFailed(message: missingMessage)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ItemStoreError.io(message: "cannot read '\(url.path)': \(error)")
        }
    }

    // MARK: - Atomic writes

    /// Temp file in the destination directory, then one `rename(2)` — a reader never sees a partial
    /// `state.json`/`preview-meta.json`/`recipe.json`, and the destination never disappears in
    /// between (docs/reference/operations.md "write temp + atomic rename"). Delegates to the shared `AtomicFile`
    /// helper so the item store and the M1 pipeline use the same implementation (review P1-7).
    private func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try AtomicFile.write(data, to: url)
        } catch {
            // AtomicFile throws `PhotonError.writeFailed`; the API vocabulary is `ItemStoreError.io`
            // (the router maps it to 500 `internal_error`). Keep its message as the cause.
            throw ItemStoreError.io(message: "cannot write '\(url.path)': \(error)")
        }
    }

    // MARK: - Error mapping

    /// `PhotonError` is the engine's vocabulary; `ItemStoreError` is the API's. Keep the mapping in
    /// one place so the router never has to know about `PhotonError`.
    ///
    /// Internal (not private) so `ItemStoreTests` can assert the mapping table directly: a real
    /// `PhotonError.unsupportedSource` needs a non-P3 source, which is the colour agent's P1-4 and
    /// outside this task's fixtures. The HTTP side (`source_unreadable` → 422) is covered by
    /// `APIRouterTests`.
    static func mapPrepareError(_ error: Error) -> ItemStoreError {
        if let storeError = error as? ItemStoreError { return storeError }
        guard let photonError = error as? PhotonError else {
            return ItemStoreError.prepareFailed(message: "prepare failed: \(error)")
        }
        switch photonError {
        case let .sourceUnreadable(path, reason):
            return ItemStoreError.sourceUnreadable(
                message: "cannot read source '\(path)': \(reason)"
            )
        case let .unsupportedSource(reason):
            // The source is readable but outside what stage 1 accepts (e.g. a non-Display-P3
            // export, review P1-4). That is a client/source problem (HTTP 422 `source_unreadable`),
            // not a 500 `prepare_failed` — the iPad must be able to tell the user to re-export.
            return ItemStoreError.sourceUnreadable(message: "unsupported source: \(reason)")
        case let .invalidRecipe(field, reason):
            return ItemStoreError.invalidRecipe(message: "invalid recipe field '\(field)': \(reason)")
        default:
            return ItemStoreError.prepareFailed(message: photonError.description)
        }
    }

    private static func message(for error: ItemStoreError) -> String {
        switch error {
        case let .unknownItem(id):
            return "unknown item \(id)"
        case let .invalidRecipe(message):
            return message
        case let .sourceChanged(expected, actual):
            return "source changed: expected sha256 \(expected), found \(actual)"
        case let .sourceUnreadable(message):
            return message
        case let .prepareFailed(message):
            return message
        case let .io(message):
            return message
        }
    }
}
