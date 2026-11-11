// swift-tools-version: 6.0
import PackageDescription

// The client package: transport/decode/draft + the single MSL source in ClientKit, and the
// state machines in ClientModel. It never links the server package.
let package = Package(
    name: "client",
    // R12: iOS 27 / macOS 27; the tests run on the Mac host, the app targets iOS.
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "ClientKit", targets: ["ClientKit"]),
        .library(name: "ClientModel", targets: ["ClientModel"]),
    ],
    dependencies: [
        .package(path: "../contract"),
    ],
    targets: [
        .target(
            name: "ClientKit",
            dependencies: [.product(name: "ContractKit", package: "contract")],
            // The one and only MSL source; runtime-compiled by the app and the parity test (ADR-0008).
            resources: [.copy("Shaders")]
        ),
        .target(
            name: "ClientModel",
            dependencies: [
                "ClientKit",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        .testTarget(
            name: "ClientKitTests",
            dependencies: [
                "ClientKit",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
        .testTarget(
            name: "ClientModelTests",
            dependencies: [
                "ClientModel",
                "ClientKit",
                .product(name: "ContractKit", package: "contract"),
            ]
        ),
    ],
    // Migration keeps Swift 5 language mode (R12); Swift 6 is a separate, later step.
    swiftLanguageModes: [.v5]
)
