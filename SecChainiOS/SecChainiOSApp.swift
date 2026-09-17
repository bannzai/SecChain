import Foundation
import SecChainCore
import SecChainUI
import SwiftUI

/// Entry point of the iOS app.
@main
struct SecChainiOSApp: App {
    /// Receives the notification a filed approval request sends, which SwiftUI alone cannot.
    @UIApplicationDelegateAdaptor(RemoteApprovalAppDelegate.self) private var remoteApprovalAppDelegate
    @State private var model = AppModelFactory.make()
    @State private var remoteApprovalModel = AppModelFactory.makeRemoteApprovalModel()

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
                .environment(remoteApprovalModel)
                .task {
                    remoteApprovalAppDelegate.model = remoteApprovalModel
                    // Looked up at every launch, because a notification about the request may never
                    // have arrived (documents/PROJECT.md, design decision 5).
                    await remoteApprovalAppDelegate.presentWaitingRequest()
                }
        }
    }
}
