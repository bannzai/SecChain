// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SecChainCore",
    platforms: [
        // LocalAuthentication's companion (Apple Watch) policies and current SwiftUI APIs used by
        // the apps are available from these versions.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SecChainCore", targets: ["SecChainCore"]),
        // The product is not named `secchain`: Xcode emits `<product>.swiftmodule` into
        // BUILT_PRODUCTS_DIR, and on a case-insensitive file system that would collide with the
        // app module `SecChain`. The embed build phase renames the executable to `secchain`.
        .executable(name: "secchain-cli", targets: ["SecChainCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .target(name: "SecChainCore"),
        .executableTarget(
            name: "SecChainCLI",
            dependencies: [
                "SecChainCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SecChainCoreTests", dependencies: ["SecChainCore"]),
    ]
)
