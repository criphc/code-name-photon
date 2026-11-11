import ContractKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// Review P1-7: replacements a reader can race must be a single atomic step, not "remove, move".
///
/// These tests pin the observable guarantees of the helpers the pipeline/item-store rely on,
/// without needing the external encoder (which `DeterminismTests`/`EncoderTests` cover):
/// - `preview-base.png` is written temp-file-then-renamed, so a re-render replaces it in one step
///   and leaves no `.tmp` file behind;
/// - a failed render cleans its temp file up;
/// - a `prepare` that fails before encoding leaves no staging directory or temp file;
/// - the default recipe's `source.path` is cwd-relative provenance (review P1-6), never raw cwd.
final class PipelineAtomicityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeSource() throws -> URL {
        try TestFixtures.writeGradientP3TIFF(
            size: PixelSize(width: 240, height: 160),
            to: directory.appendingPathComponent("source.tif")
        )
    }

    private func entries(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    // MARK: - preview-base.png

    func testPreviewBaseReRenderReplacesTheFileAndLeavesNoTemporaries() throws {
        let source = try makeSource()
        let output = directory.appendingPathComponent("item", isDirectory: true)

        let first = try PreviewBaseRenderer.render(sourceURL: source, longEdge: 120, to: output)
        let firstData = try Data(contentsOf: first.base.url)
        XCTAssertEqual(first.base.size, PixelSize(width: 120, height: 80))
        XCTAssertEqual(try entries(in: output), [PreviewBaseRenderer.fileName])

        let second = try PreviewBaseRenderer.render(sourceURL: source, longEdge: 60, to: output)
        XCTAssertEqual(second.base.url, first.base.url, "a re-render must replace the same final path")
        XCTAssertEqual(second.base.size, PixelSize(width: 60, height: 40))

        let secondData = try Data(contentsOf: second.base.url)
        XCTAssertNotEqual(secondData, firstData, "the re-render must have replaced the old bytes")
        XCTAssertEqual(second.base.bytes, secondData.count)
        XCTAssertEqual(second.base.sha256, try TestFixtures.sha256(ofFileAt: second.base.url))

        let remaining = try entries(in: output)
        XCTAssertEqual(remaining, [PreviewBaseRenderer.fileName], "re-render left extra files: \(remaining)")
        XCTAssertFalse(remaining.contains { $0.hasSuffix(".tmp") }, "a temp file survived: \(remaining)")
    }

    /// Force the final rename to fail (the destination is a directory) and assert the temp PNG is
    /// cleaned up: a failed render must not litter the item directory.
    func testPreviewBaseRenderFailureRemovesItsTemporaryFile() throws {
        let source = try makeSource()
        let output = directory.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let finalURL = output.appendingPathComponent(PreviewBaseRenderer.fileName)
        // A directory where the PNG should go makes `rename(2)` fail after the temp file exists.
        try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PreviewBaseRenderer.render(sourceURL: source, longEdge: 120, to: output)) { error in
            guard case let PhotonError.writeFailed(path, _)? = error as? PhotonError else {
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertEqual(path, finalURL.path)
        }

        let remaining = try entries(in: output)
        XCTAssertEqual(remaining, [PreviewBaseRenderer.fileName], "failure left temp files: \(remaining)")
        XCTAssertFalse(remaining.contains { $0.hasSuffix(".tmp") }, "failure left a temp file: \(remaining)")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the destination failure fixture must be untouched")
    }

    // MARK: - Pipeline usage

    /// `prepare` fails at encoder resolution for an explicitly missing executable — that happens
    /// after the intermediate TIFFs are written and before the encoded HEIC is staged. Nothing
    /// half-written (staging directory, `.tmp` file, `preview.heic`, `meta.json`) may survive, and
    /// the success paths (`preview.heic` via `AtomicFile.replace`, `meta.json` via
    /// `AtomicFile.write`) are unreachable without an encoder by design.
    func testFailedPrepareLeavesNoTemporaryOrStagingArtifacts() throws {
        let source = try makeSource()
        let output = directory.appendingPathComponent("out", isDirectory: true)
        let pipeline = try Pipeline(encoderVersion: "atomicity-test", encoder: FailingEncoder())

        XCTAssertThrowsError(
            try pipeline.prepare(
                sourceURL: source,
                recipe: nil,
                options: PipelineOptions(
                    outputDirectory: output,
                    previewLongEdge: 32
                )
            )
        ) { error in
            guard case PhotonError.writeFailed? = error as? PhotonError else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }

        // The intermediate TIFFs keep their existing single-write route (out of P1-7's scope).
        let remaining = try entries(in: output)
        XCTAssertEqual(remaining, ["hdr.tif", "sdr.tif"], "unexpected leftovers after a failed prepare: \(remaining)")
        XCTAssertFalse(
            remaining.contains { $0.hasPrefix(".") || $0.hasSuffix(".tmp") },
            "a staging directory or temp file survived: \(remaining)"
        )
        for name in ["preview.heic", "meta.json"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path),
                "a failed prepare must not leave \(name)"
            )
        }
    }

    /// The `meta.json` route in `Pipeline` is "encode pretty JSON + trailing newline, then
    /// `AtomicFile.write`": replacing an existing document keeps its name and leaves no temp.
    func testAtomicWriteReplacesAnExistingDocumentWithoutTemporaries() throws {
        let url = directory.appendingPathComponent("meta.json")
        try Data("{\"old\":true}".utf8).write(to: url)
        let document = Data("{\n  \"new\": true\n}\n".utf8)

        try AtomicFile.write(document, to: url)

        XCTAssertEqual(try Data(contentsOf: url), document, "the trailing newline must survive the atomic write")
        XCTAssertEqual(try entries(in: directory), ["meta.json"], "the atomic write left a temp file behind")
    }

    // MARK: - Provenance path (P1-6)

    /// The recorded `source.path` is relative when the source is under the working directory and
    /// absolute otherwise; a sibling directory sharing a name prefix is not "under" it.
    func testProvenancePathIsRelativeOnlyUnderTheWorkingDirectory() {
        let base = URL(fileURLWithPath: "/Users/photographer/Sites/llm-photon", isDirectory: true)
        XCTAssertEqual(
            Pipeline.provenancePath(
                for: URL(fileURLWithPath: "/Users/photographer/Sites/llm-photon/samples/sources/R0003777-P3.tif"),
                relativeTo: base
            ),
            "samples/sources/R0003777-P3.tif"
        )
        XCTAssertEqual(
            Pipeline.provenancePath(
                for: URL(fileURLWithPath: "/Volumes/shoot/01_capture/R0003777-P3.tif"),
                relativeTo: base
            ),
            "/Volumes/shoot/01_capture/R0003777-P3.tif"
        )
        XCTAssertEqual(
            Pipeline.provenancePath(
                for: URL(fileURLWithPath: "/Users/photographer/Sites/llm-photon-archive/R0003777-P3.tif"),
                relativeTo: base
            ),
            "/Users/photographer/Sites/llm-photon-archive/R0003777-P3.tif",
            "a name-prefix sibling is not under the base directory"
        )
        // A source URL relative to the cwd is standardized against the real working directory.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        XCTAssertEqual(
            Pipeline.provenancePath(for: URL(fileURLWithPath: "samples/sources/x.tif"), relativeTo: cwd),
            "samples/sources/x.tif"
        )
    }
}

/// A writer that fails after the intermediate TIFFs are written, so the atomicity test can prove
/// the staging directory is removed and no partial preview/meta survives.
private struct FailingEncoder: HEICEncoder {
    var identity: EncoderIdentity {
        EncoderIdentity(tool: Recipe.EncoderParams.coreImageToolName, executable: "coreimage")
    }

    func encode(_ request: HEICEncodeRequest) throws -> HEICEncodeResult {
        throw PhotonError.writeFailed(path: request.hdrOutputURL.path, reason: "injected encode failure")
    }
}
