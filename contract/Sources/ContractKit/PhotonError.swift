import Foundation

/// Everything that can go wrong in the Stage-1 Mac pipeline.
///
/// Every case carries enough context to be shown to a user as-is: M2/M3 will surface
/// these strings over HTTP, so do not wrap them in generic IO errors.
public enum PhotonError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// A recipe field is out of contract. docs/reference/recipe.md (recipe schema 0) is the authority.
    case invalidRecipe(field: String, reason: String)
    /// The source file cannot be opened / is not a recognised image.
    case sourceUnreadable(path: String, reason: String)
    /// The source is readable but outside what Stage 1 supports.
    case unsupportedSource(reason: String)
    /// Stage 1 only accepts orientation 1; a rotated source must be fixed at export.
    case unsupportedOrientation(Int)
    /// Decoded geometry disagrees with the recipe / expected geometry.
    case dimensionMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    /// Re-export detection: the file on disk is not the file the recipe was made for.
    case sourceHashMismatch(expected: String, actual: String)
    /// The encoder executable is missing or not executable.
    case encoderMissing(path: String)
    /// The encoder exited non-zero.
    case encoderFailed(exitCode: Int32, stderr: String)
    /// The encoder exited 0 but the expected HEIC is not there.
    case encoderOutputMissing(path: String)
    /// The encoder exited 0 but the HEIC is not the gain-map deliverable that was asked for:
    /// the read-back found no ISO gain map, an unexpected alpha channel / size, or a failed HDR
    /// decode (review P0-1 — `exit 0` is not proof). The 5 % headroom match is the delivery
    /// report's own gate (ADR-0012), not part of this structural check.
    case encoderOutputInvalid(path: String, reason: String)
    /// The authored HDR peak is too low for the encoder to write a gain map: below
    /// `EncodedHEICValidator.minimumAuthoredPeak` it silently writes a plain SDR HEIC.
    case hdrTooDim(peak: Float, minimum: Float)
    /// The M4 delivery report failed at least one named check, so **nothing** was installed into
    /// the delivery folder (docs/reference/deliver.md, report schema 1: the report is the gate). The report and the rejected
    /// staging artifacts are kept for diagnosis; `failures` names the failed checks in report order.
    case deliveryVerificationFailed(reportPath: String, failures: [String])
    /// A TIFF / metadata write failed.
    case writeFailed(path: String, reason: String)
    /// A generated buffer is malformed (wrong length, NaN, non-finite).
    case invalidImage(reason: String)

    public var description: String {
        switch self {
        case let .invalidRecipe(field, reason):
            return "invalid recipe field '\(field)': \(reason)"
        case let .sourceUnreadable(path, reason):
            return "cannot read source '\(path)': \(reason)"
        case let .unsupportedSource(reason):
            return "unsupported source: \(reason)"
        case let .unsupportedOrientation(value):
            return "unsupported orientation \(value): stage 1 requires orientation 1 (export without rotation)"
        case let .dimensionMismatch(ew, eh, aw, ah):
            return "dimension mismatch: expected \(ew)x\(eh), got \(aw)x\(ah)"
        case let .sourceHashMismatch(expected, actual):
            return "source changed: recipe expects sha256 \(expected), file is \(actual) (re-exported — make a new recipe)"
        case let .encoderMissing(path):
            return "encoder not found or not executable at '\(path)' (pass --encoder with the oracle's path)"
        case let .encoderFailed(code, stderr):
            return "encoder failed with exit code \(code): \(stderr)"
        case let .encoderOutputMissing(path):
            return "encoder exited 0 but wrote no file at '\(path)'"
        case let .encoderOutputInvalid(path, reason):
            return "encoder output '\(path)' is not a valid gain-map HEIC: \(reason)"
        case let .hdrTooDim(peak, minimum):
            return "HDR peak \(peak) is below the \(minimum) floor: the encoder would silently write a plain SDR HEIC (raise hdr.lift_stops, lower hdr.start, or export a source with real highlights)"
        case let .deliveryVerificationFailed(reportPath, failures):
            return "delivery verification failed (\(failures.joined(separator: ", "))); nothing was installed, diagnosis kept at '\(reportPath)'"
        case let .writeFailed(path, reason):
            return "cannot write '\(path)': \(reason)"
        case let .invalidImage(reason):
            return "invalid image buffer: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
