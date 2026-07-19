// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "GlasSecretStore",
    platforms: [
        .visionOS(.v26),
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "GlasSecretStore", targets: ["GlasSecretStore"]),
    ],
    targets: [
        .target(name: "GlasSecretStore"),
        .testTarget(name: "GlasSecretStoreTests", dependencies: ["GlasSecretStore"]),
    ]
)
