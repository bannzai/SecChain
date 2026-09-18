import CloudKit
import Foundation
import Testing

@testable import SecChainCore

/// Saving the subscription needs an Apple Account and the deployed schema, so what is covered here
/// is what the saved value says: the record type the Mac writes, a visible notification, and a
/// payload that carries nothing of the request.
@Suite
struct RemoteApprovalSubscriptionTests {
    let subscription = RemoteApprovalSubscription.subscription(
        alertTitle: "SecChain",
        alertBody: "dummy-alert-for-test"
    )

    @Test
    func theSubscriptionFiresWhenAMacFilesARequest() {
        #expect(subscription.recordType == RemoteApprovalRecordType.request)
        #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
        // Neither an update nor a deletion is something the user has to be told about: a Mac writes
        // a request once, and a deleted request is one that no longer needs an answer.
        #expect(!subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
        #expect(!subscription.querySubscriptionOptions.contains(.firesOnRecordDeletion))
    }

    @Test
    func savingItAgainReplacesTheOneThisDeviceInstalled() {
        #expect(subscription.subscriptionID == RemoteApprovalSubscription.identifier)
        #expect(
            RemoteApprovalSubscription.subscription(alertTitle: "SecChain", alertBody: "another body").subscriptionID
                == subscription.subscriptionID
        )
    }

    @Test
    func theNotificationIsVisibleAndSaysNothingAboutTheRequest() throws {
        let notificationInfo = try #require(subscription.notificationInfo)
        #expect(notificationInfo.title == "SecChain")
        #expect(notificationInfo.alertBody == "dummy-alert-for-test")
        #expect(notificationInfo.shouldSendContentAvailable == false)
        // The request names the repository, the secret names, and the command; none of that travels
        // through Apple's servers in the notification.
        #expect(notificationInfo.desiredKeys == nil)
    }
}
