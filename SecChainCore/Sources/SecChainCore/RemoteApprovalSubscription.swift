import CloudKit
import Foundation

/// The subscription the approving device installs on `ApprovalRequest`, so that a request a Mac
/// files arrives as a notification the user can see (documents/PROJECT.md, design decision 5).
///
/// The notification says only that an approval was asked for. What is being approved is read from
/// the request itself when the app opens, because a notification travels through Apple's servers and
/// a request names the repository, the secret names, and the command.
public enum RemoteApprovalSubscription {
    /// Identifier of the subscription. Fixed, so that saving it again replaces the one this device
    /// installed earlier instead of adding a second one (idempotent).
    public static let identifier = "remote-approval-requests"

    /// The subscription as it is saved. `firesOnRecordCreation` alone: a Mac writes a request once
    /// and never updates it, and a deleted request is one the iPhone no longer has to answer.
    public static func subscription(alertTitle: String, alertBody: String) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: RemoteApprovalRecordType.request,
            // Every request, filtered on a field of every record: the system `recordName` is not
            // indexed unless someone marks it in the CloudKit Console
            // (`RemoteApprovalCloudKitRecords.everyRecordPredicate`).
            predicate: RemoteApprovalCloudKitRecords.everyRecordPredicate(),
            subscriptionID: identifier,
            options: [.firesOnRecordCreation]
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.title = alertTitle
        notificationInfo.alertBody = alertBody
        // The app fetches the open requests itself when the notification arrives, so the payload
        // carries no field of the request.
        notificationInfo.shouldSendContentAvailable = false
        subscription.notificationInfo = notificationInfo
        return subscription
    }

    /// Installs the subscription in the private database of the container both front ends share.
    /// Saving it again replaces it (idempotent), which is how the notification text follows the
    /// language the app runs in.
    ///
    /// Throws what CloudKit throws: there is no Apple Account on the iOS Simulator, and the
    /// production schema has the record type only after it has been deployed, so a caller shows the
    /// failure instead of treating notifications as working.
    public static func install(alertTitle: String, alertBody: String) async throws {
        _ = try await CKContainer(identifier: SecChainSharedConfig.cloudKitContainerIdentifier)
            .privateCloudDatabase
            .save(subscription(alertTitle: alertTitle, alertBody: alertBody))
    }
}
