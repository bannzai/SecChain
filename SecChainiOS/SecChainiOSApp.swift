import Foundation
import SecChainCore
import SecChainUI
import SwiftUI

/// Entry point of the iOS app.
@main
struct SecChainiOSApp: App {
    @State private var model = AppModelFactory.make()

    // A custom initializer is needed to answer the doctor launch arguments before any window
    // appears (see `KeychainDoctor.exitCodeForLaunchArguments`).
    init() {
        if let exitCode = KeychainDoctor.exitCodeForLaunchArguments(arguments: CommandLine.arguments) {
            exit(exitCode)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
