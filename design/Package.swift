// swift-tools-version: 6.0
import PackageDescription

// The design package: visual tokens and the specimen that renders them.
// It depends on nothing — the app links `Tokens`, `Specimen` is for looking at.
let package = Package(
    name: "design",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "Tokens", targets: ["Tokens"]),
        .library(name: "Specimen", targets: ["Specimen"]),
    ],
    targets: [
        .target(name: "Tokens"),
        .target(name: "Specimen", dependencies: ["Tokens"]),
    ],
    // Same Swift 5 language mode as the rest of the repo (R12).
    swiftLanguageModes: [.v5]
)
