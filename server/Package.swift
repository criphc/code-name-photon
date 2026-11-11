// swift-tools-version: 6.0
import PackageDescription

// The server package: the rendering/encoding/verification engine, the LAN server, the
// GUI↔CLI process contract and the thin `appctl` entry point. The `contract` package is the
// single shared definition (recipe, maths, wire, IPC); this package never depends on an app.
let package = Package(
    name: "PhotonServer",
    // macOS 27+ : R12 deployment target; ImageIO HDR decode / content headroom and the encoder
    // tool's OS floor are all satisfied here.
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "EngineKit", targets: ["EngineKit"]),
        .library(name: "ServerKit", targets: ["ServerKit"]),
        .library(name: "ServerControl", targets: ["ServerControl"]),
        .executable(name: "appctl", targets: ["appctl"]),
    ],
    dependencies: [
        // The shared contract (repo root `contract/`): recipe + maths + wire + IPC, no I/O.
        .package(path: "../contract"),
    ],
    targets: [
        .target(
            name: "EngineKit",
            dependencies: [.product(name: "ContractKit", package: "contract")],
            // A tiny ISO 21496-1 HEIC used only as the gain-map metadata template (the pixels are
            // ignored); the writer clones it and sets the headroom/gain values per delivery.
            resources: [.copy("Resources/iso-gainmap-template.heic")]
        ),
        .target(
            name: "ServerKit",
            dependencies: [
                "EngineKit",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        // GUI↔CLI process contract only: no EngineKit/ServerKit dependency (R1/ADR-0003).
        .target(
            name: "ServerControl",
            dependencies: [.product(name: "ContractKit", package: "contract")]
        ),
        // Test-only helpers for ServerControl/Integration tests; never linked by appctl.
        .target(
            name: "ServerTestSupport",
            dependencies: [
                "ServerControl",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        .executableTarget(
            name: "appctl",
            dependencies: [
                "EngineKit",
                "ServerKit",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        .testTarget(
            name: "EngineKitTests",
            dependencies: [
                "EngineKit",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        .testTarget(
            name: "ServerKitTests",
            dependencies: [
                "ServerKit",
                "EngineKit",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        .testTarget(
            name: "ServerControlTests",
            dependencies: [
                "ServerControl",
                "ServerTestSupport",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [.product(name: "ContractKit", package: "contract")]
        ),
    ],
    // Migration keeps Swift 5 language mode (R12); Swift 6 is a separate, post-migration step.
    swiftLanguageModes: [.v5]
)
