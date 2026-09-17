import Foundation
import SecChainCore
import SwiftUI

/// Entry point of the iOS app.
@main
struct SecChainiOSApp: App {
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
