import Foundation
import XCTest
@testable import EngineKit

/// Contract tests for the shared atomic-replacement helpers (review P1-7).
final class AtomicFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testWriteCreatesANewFile() throws {
        let url = directory.appendingPathComponent("state.json")
        try AtomicFile.write(Data("first".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("first".utf8))
    }

    func testWriteCreatesMissingParentDirectory() throws {
        let url = directory
            .appendingPathComponent("nested/deeper")
            .appendingPathComponent("state.json")
        try AtomicFile.write(Data("x".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("x".utf8))
    }

    func testReplaceSwapsTheFileAndRemovesTheSourceName() throws {
        let destination = directory.appendingPathComponent("preview.heic")
        let staging = directory.appendingPathComponent("staged.heic")
        try Data("old".utf8).write(to: destination)
        try Data("new bytes".utf8).write(to: staging)

        try AtomicFile.replace(staging, with: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testReplaceFailsForMissingSource() throws {
        let destination = directory.appendingPathComponent("preview.heic")
        let missing = directory.appendingPathComponent("missing.heic")
        XCTAssertThrowsError(try AtomicFile.replace(missing, with: destination)) { error in
            guard case let PhotonError.writeFailed(path, _)? = error as? PhotonError else {
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertEqual(path, destination.path)
        }
    }
}
