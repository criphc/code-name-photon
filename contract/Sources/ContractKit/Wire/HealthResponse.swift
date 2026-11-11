import Foundation

/// `GET /api/health` — the unauthenticated reachability probe (`ok`, app version, batch count,
/// and whether the server is checking a token).
public struct HealthResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let name: String
    public let version: String
    public let itemCount: Int
    public let authRequired: Bool

    public init(
        ok: Bool = true,
        name: String = "photon",
        version: String,
        itemCount: Int,
        authRequired: Bool = true
    ) {
        self.ok = ok
        self.name = name
        self.version = version
        self.itemCount = itemCount
        self.authRequired = authRequired
    }
}
