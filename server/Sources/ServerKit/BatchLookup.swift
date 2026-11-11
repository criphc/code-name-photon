import Foundation
import EngineKit

/// One source in a flat batch folder: the file and the SHA-256 that names it everywhere else
/// (`/api/items`, `work/<sha>/`, the delivery report).
public struct BatchItem: Sendable, Equatable {
    public let url: URL
    public let sha256: String

    public init(url: URL, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }
}

/// Resolves an M2.1 item id (the source's SHA-256) to its file inside the batch folder, and
/// enumerates the folder for a batch delivery.
///
/// `appctl deliver` names its input by identity, exactly like the API does (docs/reference/deliver.md,
/// "Identity and state": the item id is the SHA-256 of the bytes, never a path). The scan keeps the
/// same filter `ItemStore` uses — regular, non-hidden `.tif`/`.tiff` files, duplicate content
/// collapsing to the first name in sort order — so an id the iPad saw in `/api/items` resolves to
/// the same file here. Nothing is cached: a delivery happens once per image, and re-hashing the
/// batch is the honest re-export check.
public enum BatchLookup {
    /// Every source in `batchDirectory`, in file-name order, one entry per content hash.
    ///
    /// This is the single definition of "the items of a batch": `sourceURL(forID:in:)` and the
    /// batch delivery both go through it, so an id and a batch run can never disagree about which
    /// files exist. Duplicate content collapses to the first name in sort order — the same image
    /// exported twice is one item, not two deliveries.
    ///
    /// - Throws: `PhotonError.sourceUnreadable` when the batch folder cannot be listed. A file that
    ///   cannot be hashed is skipped: one unreadable source must not make the whole scan fail.
    public static func items(in batchDirectory: URL) throws -> [BatchItem] {
        let directory = batchDirectory.standardizedFileURL
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw PhotonError.sourceUnreadable(
                path: directory.path,
                reason: "cannot list the batch folder: \(error)"
            )
        }

        var items: [BatchItem] = []
        var seenHashes = Set<String>()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent.lowercased()
            guard name.hasSuffix(".tif") || name.hasSuffix(".tiff") else { continue }
            let url = entry.standardizedFileURL
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let hash = try? SourceDecoder.sha256(ofFileAt: url) else { continue }
            guard seenHashes.insert(hash.lowercased()).inserted else { continue }
            items.append(BatchItem(url: url, sha256: hash))
        }
        return items
    }

    /// Finds the source whose bytes hash to `id`.
    ///
    /// - Throws: `PhotonError.sourceUnreadable` when the batch folder cannot be listed, or when no
    ///   file in it matches `id` (the message names `--batch` / `--source` as the fix).
    public static func sourceURL(forID id: String, in batchDirectory: URL) throws -> URL {
        let items = try items(in: batchDirectory)
        if let match = items.first(where: { $0.sha256.lowercased() == id.lowercased() }) {
            return match.url
        }

        throw PhotonError.sourceUnreadable(
            path: batchDirectory.standardizedFileURL.path,
            reason: "no item with id '\(id)' in the batch folder; pass --batch <dir> or --source <path>"
        )
    }
}
