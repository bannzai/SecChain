// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SecChainCore",
    // The strings in the source code are English; other languages are translations of them.
    defaultLocalization: "en",
    platforms: [
        // LocalAuthentication's companion (Apple Watch) policies and current SwiftUI APIs used by
        // the apps are available from these versions.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // One product for both apps: the shared SwiftUI screens (`SecChainUI`) ship with the core.
        // The command-line tool depends on the `SecChainCore` target directly and does not link
        // the user interface.
        .library(name: "SecChainCore", targets: ["SecChainCore", "SecChainUI"]),
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
        .target(
            name: "SecChainUI",
            dependencies: ["SecChainCore"],
            // The String Catalog translates the texts of both apps, including the messages and
            // authentication reasons that SecChainCore builds. SecChainCore itself has no resources,
            // so the command-line tool needs no resource bundle and its output stays English.
            resources: [.process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "SecChainCLI",
            dependencies: [
                "SecChainCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SecChainCoreTests", dependencies: ["SecChainCore"]),
        .testTarget(name: "SecChainUITests", dependencies: ["SecChainUI"]),
    ]
)
