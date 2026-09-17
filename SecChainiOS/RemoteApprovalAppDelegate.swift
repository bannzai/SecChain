import SecChainUI
import UIKit
import UserNotifications

/// Connects the system's notification machinery to the remote approval screens.
///
/// A request a Mac files arrives as a push from the `CKQuerySubscription`, and the app then asks the
/// private database itself what is waiting: a notification can be coalesced or dropped, so it is
/// only ever a hint that something is there (documents/PROJECT.md, design decision 5).
final class RemoteApprovalAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app once the model exists. SwiftUI creates the delegate before the scene, so the
    /// model cannot be an initializer argument.
    var model: RemoteApprovalModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await presentWaitingRequest()
        return .newData
    }

    /// Shows the notification while SecChain is in front too, so that a request arriving while the
    /// user is in the app is not swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await presentWaitingRequest()
        return [.banner, .sound]
    }

    /// Opens the request the user tapped the notification for.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await presentWaitingRequest()
    }

    /// Reads what is waiting and opens the approval screen on it. Safe to call for every
    /// notification, including one about a request that has already been answered (idempotent).
    func presentWaitingRequest() async {
        guard let model else {
            return
        }
        await model.refresh()
        model.presentFirstOpenRequest()
    }
}
