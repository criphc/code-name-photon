import Foundation

/// The single loader for `HighlightShape.msl`.
///
/// The MSL ships as a `ClientKit` package resource (`.copy("Shaders")`), and both the app and the
/// shader parity test read it through this type. Runtime compilation with
/// `device.makeLibrary(source:)` is deliberate: no Metal toolchain, no `.metallib`, and the test
/// compiles exactly the bytes the app compiles (ADR-0008).
public enum ShaderResource {
    public static let fileName = "HighlightShape"
    public static let fileExtension = "msl"

    /// The packaged MSL URL. Checks the `Shaders/` subdirectory first (`.copy` preserves it), then
    /// the bundle root as a defensive fallback.
    public static func url() -> URL? {
        Bundle.module.url(forResource: fileName, withExtension: fileExtension, subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: fileName, withExtension: fileExtension)
    }

    /// The MSL text the app and the parity test must both compile.
    public static func source() throws -> String {
        guard let url = url() else {
            throw ShaderResourceError.missing
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

public enum ShaderResourceError: Error, CustomStringConvertible {
    case missing

    public var description: String {
        switch self {
        case .missing: return "HighlightShape.msl is missing from the ClientKit resource bundle"
        }
    }
}
