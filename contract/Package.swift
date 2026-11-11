// swift-tools-version: 6.0
import PackageDescription

// The shared contract: one no-I/O definition of the recipe schema, the mask/gain maths,
// Rec.709 luma, the working-buffer types and (from P1) the HTTP wire + IPC events. It is linked
// by the Mac package (`server/`, via a local path dependency) and compiled into the iPad app as a
// source folder, so the two clients cannot drift apart.
let package = Package(
    name: "contract",
    // R12: iOS 27 / macOS 27 deployment targets. The string form keeps swift-tools-version 6.0
    // (the `.v27` enums would require 6.4 and buy nothing here).
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "ContractKit", targets: ["ContractKit"]),
    ],
    targets: [
        .target(name: "ContractKit"),
        .testTarget(
            name: "ContractKitTests",
            dependencies: ["ContractKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    // Migration keeps Swift 5 language mode (R12); the Swift 6 mode switch is a separate,
    // post-migration step with its own ADR.
    swiftLanguageModes: [.v5]
)
