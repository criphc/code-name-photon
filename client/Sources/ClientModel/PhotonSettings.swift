import Foundation

/// The three connection settings the M3 client keeps between launches.
///
/// The port stays a `String` because it is a text field value: `SessionModel.isConfigured` trims
/// and parses it rather than the settings layer silently repairing it.
public struct PhotonConnectionSettings: Equatable, Sendable {
    public var host: String
    public var port: String
    public var token: String

    public init(host: String = "", port: String = SessionModel.defaultPort, token: String = "") {
        self.host = host
        self.port = port
        self.token = token
    }
}

/// Persistence seam for `SessionModel`, so the state machine is testable without `UserDefaults`.
public protocol PhotonSettingsStore {
    /// The last saved settings, or `nil` when nothing has been saved yet.
    func load() -> PhotonConnectionSettings?
    func save(_ settings: PhotonConnectionSettings)
}

/// The production store: the M3 `UserDefaults` keys, unchanged so an existing install keeps its
/// host/port/token. M3 accepts plaintext token storage for a trusted LAN (docs/reference/client.md, scope).
public struct UserDefaultsSettingsStore: PhotonSettingsStore {
    public static let hostKey = "photon.host"
    public static let portKey = "photon.port"
    public static let tokenKey = "photon.token"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PhotonConnectionSettings? {
        let host = defaults.string(forKey: Self.hostKey)
        let port = defaults.string(forKey: Self.portKey)
        let token = defaults.string(forKey: Self.tokenKey)
        guard host != nil || port != nil || token != nil else { return nil }
        return PhotonConnectionSettings(
            host: host ?? "",
            port: port ?? SessionModel.defaultPort,
            token: token ?? ""
        )
    }

    public func save(_ settings: PhotonConnectionSettings) {
        defaults.set(settings.host, forKey: Self.hostKey)
        defaults.set(settings.port, forKey: Self.portKey)
        defaults.set(settings.token, forKey: Self.tokenKey)
    }
}
