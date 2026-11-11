import Foundation

/// Atomic file replacement shared by the M1 pipeline and the M2.1 item store.
///
/// A reader must never observe a half-written `preview.heic`, `state.json` or `preview-base.png`
/// (docs/reference/operations.md: "write temp + atomic rename"). Writing the bytes into a temp file beside the
/// destination and then `rename(2)`-ing it over the destination gives exactly that: on one volume
/// `rename` replaces the old directory entry in a single step, so a reader sees either the old
/// bytes or the new bytes — never a prefix.
///
/// Both helpers require `source` and `destination` to be on the same volume. That always holds
/// here: the temp file is created in the destination's own directory, and the pipeline stages the
/// encoded HEIC in a subdirectory of its output directory.
///
/// (Review P1-7: the previous "atomic" helpers removed the destination and then moved the temp file
/// into place — two steps during which the destination did not exist.)
public enum AtomicFile {
    /// Writes `data` to `url`, replacing any existing file atomically.
    ///
    /// Creates the parent directory when missing (the item store writes `state.json` into an item
    /// directory it may have just created).
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PhotonError.writeFailed(
                path: url.path,
                reason: "cannot create directory '\(directory.path)': \(error)"
            )
        }

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            // A plain write: `replace` below is the atomic step. `Data.write(options: .atomic)`
            // would add a second temp-and-rename layer of its own, which is redundant and opaque.
            try data.write(to: temporary)
            try replace(temporary, with: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let photonError = error as? PhotonError { throw photonError }
            throw PhotonError.writeFailed(
                path: url.path,
                reason: "cannot write '\(url.lastPathComponent)': \(error)"
            )
        }
    }

    /// Moves `source` onto `destination` atomically, replacing an existing destination.
    ///
    /// POSIX `rename(2)`, not `FileManager.moveItem` (which fails on an existing destination) and
    /// not remove-then-move (two steps, destination missing in between). Same volume required.
    public static func replace(_ source: URL, with destination: URL) throws {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard rename(sourcePath, destinationPath) == 0 else {
            let code = errno
            let detail = String(cString: strerror(code))
            throw PhotonError.writeFailed(
                path: destinationPath,
                reason: "atomic rename from '\(source.lastPathComponent)' failed "
                    + "(errno \(code): \(detail))"
            )
        }
    }
}
