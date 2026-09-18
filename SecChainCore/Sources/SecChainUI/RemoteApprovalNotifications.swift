import SecChainCore

#if os(iOS)
import UIKit
import UserNotifications
#endif

/// The system's side of the notifications a filed approval request turns into: whether the user
/// allowed them, and the registration that lets a push reach this app at all.
///
/// A protocol for the same reason as `OwnerAuthenticating`: the policy in `RemoteApprovalModel` is
/// unit-tested without a permission prompt and without a device that can receive pushes.
public protocol RemoteApprovalNotifying: Sendable {
    /// Whether notifications may be shown, as the user last answered.
    func isAuthorized() async -> Bool

    /// Asks for permission, and registers for pushes once it is given. The prompt appears once;
    /// afterwards the system answers with what the user chose then, so calling this again is safe
    /// (idempotent).
    func requestAuthorization() async throws -> Bool

    /// Registers for pushes, for a launch where permission was already given.
    func registerForRemoteNotifications() async
}

#if os(iOS)
/// The real one, backed by UserNotifications and UIKit.
public struct SystemRemoteApprovalNotifying: RemoteApprovalNotifying {
    public init() {}

    public func isAuthorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    public func requestAuthorization() async throws -> Bool {
        // Sound as well as an alert: an approval is answered within two minutes, so the user has to
        // notice the request while the Mac is still waiting.
        let isAuthorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        if isAuthorized {
            await registerForRemoteNotifications()
        }
        return isAuthorized
    }

    @MainActor
    public func registerForRemoteNotifications() async {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
#endif
