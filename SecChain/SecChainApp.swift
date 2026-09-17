import Foundation
import SecChainCore
import SecChainUI
import SwiftUI

/// Entry point of the macOS app.
@main
struct SecChainApp: App {
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
        // Tall enough for the sync explanation sheet to fit without scrolling; the size SwiftUI
        // derives from the minimum content size (900 × 492 on a 1024 × 768 screen) cut off its end.
        .defaultSize(width: 960, height: 680)
    }
}
