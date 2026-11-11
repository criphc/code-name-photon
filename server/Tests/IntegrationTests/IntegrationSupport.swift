import ContractKit
import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import XCTest

/// Shared plumbing for the P2 integration tests: locate the real built binary, make isolated temp
/// directories, allocate a fixed free port, run `appctl` with both pipes drained, and speak just
/// enough HTTP for the health probe.
///
/// Everything here fails the test instead of skipping: these tests exist to prove the real
/// `appctl` process contract (ADR-0010), so a missing `APPCTL_BIN` or encoder is a broken gate.
enum IntegrationSupport {
    /// A precondition failure with a message meant for the test log.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Locating inputs

    /// `APPCTL_BIN` must point at the built `appctl` executable (`make integration` sets it).
    static func appctlBinary() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["APPCTL_BIN"], !raw.isEmpty else {
            throw Failure(description: """
            APPCTL_BIN is not set. These tests spawn the real built binary: build it with \
            `swift build --product appctl` and run the tests with APPCTL_BIN=<path to appctl> \
            (the repository Makefile's `integration` target does both).
            """)
        }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        try requireExecutable(url, description: "APPCTL_BIN ('\(raw)')")
        return url
    }

    /// The repository root, derived from this source file's location:
    /// `<repo>/server/Tests/IntegrationTests/IntegrationSupport.swift`.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // IntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // server
            .deletingLastPathComponent() // repository root
    }

    private static func requireExecutable(_ url: URL, description: String) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Failure(description: "\(description) is not an executable file at \(url.path)")
        }
    }

    // MARK: - Temporary directories

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fixed free port

    /// Binds a TCP socket to 127.0.0.1:0, reads the kernel-assigned port, then closes the socket.
    ///
    /// `appctl serve --port 0` is deliberately not supported in P2, so the tests pick a concrete
    /// port this way and hand it to `--port`. The bind also proves the port is free at that moment.
    static func findFreePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure(description: "socket(AF_INET, SOCK_STREAM, 0) failed: \(posixMessage())")
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw Failure(description: "bind(127.0.0.1:0) failed: \(posixMessage())")
        }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            throw Failure(description: "getsockname failed: \(posixMessage())")
        }

        let port = UInt16(bigEndian: local.sin_port)
        guard port > 0 else {
            throw Failure(description: "the kernel assigned port 0 to a 127.0.0.1:0 bind")
        }
        return port
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }

    // MARK: - Child process

    /// Polls `isRunning`; bounded, never blocks the test thread indefinitely.
    static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    /// SIGTERM, a bounded grace period, then SIGKILL. Safe to call on an already-exited process.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if !waitForExit(process, timeout: 3) {
            kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(process, timeout: 3)
        }
    }

    // MARK: - HTTP

    struct HTTPResult {
        let statusCode: Int
        let body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }
    }

    /// A synchronous GET with a hard timeout; the server is one-request-per-connection, so a fresh
    /// ephemeral session per call keeps the client out of the way.
    static func httpGet(
        _ url: URL,
        bearerToken: String? = nil,
        timeout: TimeInterval = 5
    ) throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        final class Box {
            var result: Result<HTTPResult, Error>?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                box.result = .failure(Failure(description: "no HTTP response for \(url.absoluteString)"))
                return
            }
            box.result = .success(HTTPResult(statusCode: http.statusCode, body: data))
        }.resume()

        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            throw Failure(description: "GET \(url.absoluteString) did not answer within \(timeout) s")
        }
        guard let result = box.result else {
            throw Failure(description: "GET \(url.absoluteString) finished without a result")
        }
        return try result.get()
    }

    // MARK: - Fixtures

    /// A 16-bit Display P3 TIFF with a horizontal linear-light gradient, generated at run time so
    /// the tests never depend on `samples/` or `work/` (M4 delivery harness shape).
    static func writeGradientP3TIFF(width: Int, height: Int, to url: URL) throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .outputColorSpace: linearP3,
            .cacheIntermediates: false,
        ])
        guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: CGFloat(width), y: 0),
            "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1, colorSpace: linearP3)!,
            "inputColor1": CIColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1, colorSpace: linearP3)!,
        ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw Failure(description: "cannot build the CILinearGradient source fixture")
        }
        try context.writeTIFFRepresentation(
            of: gradient,
            to: url,
            format: .RGBA16,
            colorSpace: p3,
            options: [:]
        )
    }

    /// Lowercase hex SHA-256 of the file bytes — the source identity a stored recipe must match.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Drains a child's stdout/stderr on background queues while the test polls a bounded buffer.
///
/// A pipe must be drained continuously: if the child filled a pipe buffer during a test wait it
/// would block (ADR-0010's 1 MB+1 MB gotcha). Callers close the parent's write handles after
/// `Process.run()` so the reader sees EOF when the child exits.
final class ProcessOutputCollector {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutFinished = false
    private var stderrFinished = false
    private let stdoutDone = DispatchSemaphore(value: 0)
    private let stderrDone = DispatchSemaphore(value: 0)

    func drain(stdout: Pipe, stderr: Pipe) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            readAvailable(stdout.fileHandleForReading, into: { chunk in
                lock.lock()
                stdoutBuffer.append(chunk)
                lock.unlock()
            })
            lock.lock()
            stdoutFinished = true
            lock.unlock()
            stdoutDone.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            readAvailable(stderr.fileHandleForReading, into: { chunk in
                lock.lock()
                stderrBuffer.append(chunk)
                lock.unlock()
            })
            lock.lock()
            stderrFinished = true
            lock.unlock()
            stderrDone.signal()
        }
    }

    /// Streams `availableData` instead of `readDataToEndOfFile`: the ready line must become visible
    /// while the child is still serving, not only once it exits at EOF.
    private func readAvailable(_ handle: FileHandle, into append: (Data) -> Void) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            append(chunk)
        }
    }

    private var isStdoutFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdoutFinished
    }

    private var isStderrFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stderrFinished
    }

    var stdoutData: Data {
        lock.lock()
        defer { lock.unlock() }
        return stdoutBuffer
    }

    var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    var stdoutText: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    /// The first complete stdout line, or `nil` when none has arrived yet.
    private var firstStdoutLine: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let newline = stdoutBuffer.firstIndex(of: 0x0A) else { return nil }
        return String(decoding: stdoutBuffer[..<newline], as: UTF8.self)
    }

    /// Waits for the first newline-terminated stdout line; at EOF returns whatever is buffered.
    func waitForFirstStdoutLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = firstStdoutLine {
                return line
            }
            if isStdoutFinished {
                return firstStdoutLine
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return firstStdoutLine
    }

    /// Bounded wait for the stdout pipe to reach EOF (the child and its pipe writers are gone).
    func waitForStdoutEOF(timeout: TimeInterval) -> Bool {
        if isStdoutFinished { return true }
        return stdoutDone.wait(timeout: .now() + timeout) == .success
    }

    /// Bounded wait for the stderr pipe to reach EOF.
    func waitForStderrEOF(timeout: TimeInterval) -> Bool {
        if isStderrFinished { return true }
        return stderrDone.wait(timeout: .now() + timeout) == .success
    }
}
