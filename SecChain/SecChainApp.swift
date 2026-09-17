import Foundation
import SecChainCore
import SwiftUI

/// Entry point of the macOS app.
@main
struct SecChainApp: App {
    // A custom initializer is needed to answer the doctor launch arguments before any window
    // appears (see `KeychainDoctor.exitCodeForLaunchArguments`).
    init() {
        if let exitCode = KeychainDoctor.exitCodeForLaunchArguments(arguments: CommandLine.arguments) {
            exit(exitCode)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
