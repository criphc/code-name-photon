import ContractKit
import Foundation

/// Why a `ServerConfig` could not be built. `ServeToken.resolve` checks the CLI input first; this
/// is the last guard for any other caller (tests, future tools).
public enum ServerConfigError: Swift.Error, Equatable {
    /// The token is empty, has surrounding/embedded whitespace, or is otherwise not presentable.
    case invalidToken
}

/// Everything the M2 server needs to run. The CLI builds this from flags/env; tests build it with
/// temp directories.
public struct ServerConfig: Sendable {
    /// The batch being worked on: every `.tif`/`.tiff` here becomes an item (stage 1 = one folder).
    public var batchDirectory: URL
    /// Where per-item artifacts live: `work/<source sha256>/` gets the M2.1 base set
    /// `{preview-base.png,preview-meta.json,state.json}` plus `recipe.json` once a recipe is posted.
    /// (`appctl prep`'s M1 artifacts `{sdr.tif,hdr.tif,preview.heic,meta.json}` live in the same
    /// layout but are not part of the M2 API.)
    public var workDirectory: URL
    /// Per-session bearer token. Required on every /api route except /api/health, and never empty:
    /// `init` throws `ServerConfigError.invalidToken` otherwise (`ServeToken.resolve` is the CLI
    /// path that guarantees it).
    public var token: String
    public var bindHost: String
    /// 0 = let the OS choose (tests); the CLI defaults to 8787.
    public var port: UInt16
    public var previewLongEdge: Int
    /// Encoder commit recorded in the recipe defaults for M4 provenance (e.g. "5dba4e2").
    /// M2 never runs the encoder.
    public var encoderVersion: String
    /// The encoder profile the iPad's recipe defaults start from (v2: 10-bit, half-res, ISO RGB).
    public var encoderProfile: Recipe.EncoderParams
    /// This server's build identity, part of the cache key (docs/reference/operations.md).
    public var appVersion: String

    public init(
        batchDirectory: URL,
        workDirectory: URL,
        token: String,
        bindHost: String = "0.0.0.0",
        port: UInt16 = 8787,
        previewLongEdge: Int = 2560,
        encoderVersion: String,
        encoderProfile: Recipe.EncoderParams = ServerConfig.defaultEncoderProfile,
        appVersion: String = ServerConfig.currentAppVersion
    ) throws {
        guard ServeToken.isValid(token) else { throw ServerConfigError.invalidToken }
        self.batchDirectory = batchDirectory
        self.workDirectory = workDirectory
        self.token = token
        self.bindHost = bindHost
        self.port = port
        self.previewLongEdge = previewLongEdge
        self.encoderVersion = encoderVersion
        self.encoderProfile = encoderProfile
        self.appVersion = appVersion
    }

    /// v2's default delivery profile: 10-bit base, half-resolution ISO RGB gain map.
    public static let defaultEncoderProfile = Recipe.EncoderParams(
        tool: Recipe.EncoderParams.coreImageToolName,
        quality: 0.85,
        depth: 10,
        subsample: true,
        map: Recipe.EncoderParams.isoRGBMap
    )

    /// Bumped when the preview pipeline or the API contract changes in a way that invalidates cached
    /// artifacts. Part of the cache key, so a bump forces a re-prepare (docs/reference/operations.md).
    /// M2.1: base previews are 16-bit PNG (the M2 HEIC previews are not reused).
    public static let currentAppVersion = "0.3.0-m21"
}
