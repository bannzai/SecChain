import Foundation
import SecChainCore
import Testing

@testable import SecChainUI

/// Notification permission double: answers what it was built with, and prompts nobody.
struct FixedRemoteApprovalNotifying: RemoteApprovalNotifying {
    let isNotificationAuthorized: Bool

    func isAuthorized() async -> Bool {
        isNotificationAuthorized
    }

    func requestAuthorization() async throws -> Bool {
        isNotificationAuthorized
    }

    func registerForRemoteNotifications() async {}
}

@MainActor
@Suite
struct RemoteApprovalModelTests {
    let store = InMemoryRemoteApprovalStore()

    func makeModel(isNotificationAuthorized: Bool = true) -> RemoteApprovalModel {
        RemoteApprovalModel(
            makeStore: { [store] in store },
            keyStore: InMemoryRemoteApprovalKeyStore(),
            deviceName: "Example iPhone",
            notifying: FixedRemoteApprovalNotifying(isNotificationAuthorized: isNotificationAuthorized),
            installSubscription: { _, _ in }
        )
    }

    /// Files a request the way a Mac does.
    func fileRequest(secretName: String) async throws -> RemoteApprovalRequest {
        let request = RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
            secretScopes: SecretName(rawName: secretName).map { [$0: SecretScope.shared(.user)] } ?? [:],
            commandArguments: ["npm", "run", "deploy"],
            requestingDeviceName: "Example Mac",
            now: Date(),
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
        try await store.save(request: request)
        return request
    }

    @Test
    func pairingAgainWithdrawsTheKeyThatCanNoLongerSign() async throws {
        let model = makeModel()
        await model.pair()
        let firstPairing = try #require(model.pairing)
        await model.pair()
        let secondPairing = try #require(model.pairing)

        #expect(firstPairing.publicKeyRepresentation != secondPairing.publicKeyRepresentation)
        // The private key of the first pairing is gone, so a Mac that enrolled it from the database
        // would be paired with a key that can never sign again.
        #expect(try await store.pairings().map(\.publicKeyRepresentation) == [secondPairing.publicKeyRepresentation])
    }

    @Test
    func removingThePairingWithdrawsThePublishedKey() async throws {
        let model = makeModel()
        await model.pair()
        await model.unpair()

        #expect(model.pairing == nil)
        #expect(try await store.pairings().isEmpty)
        #expect(model.failureMessage == nil)
    }

    @Test
    func theOutcomeOfOneRequestIsNotShownOnAnother() async throws {
        let model = makeModel()
        await model.pair()
        let answeredRequest = try await fileRequest(secretName: "FIRST")
        let laterRequest = try await fileRequest(secretName: "SECOND")

        // What a dismissal during a pending answer looks like: the screen already shows the second
        // request when the first one's write finishes.
        model.present(request: laterRequest)
        await model.approve(request: answeredRequest)

        #expect(model.answeredOutcome == nil)
        #expect(try await store.decision(requestIdentifier: answeredRequest.requestIdentifier)?.outcome == .approved)
        #expect(try await store.decision(requestIdentifier: laterRequest.requestIdentifier) == nil)
    }

    @Test
    func answeringTheRequestOnScreenShowsItsOutcome() async throws {
        let model = makeModel()
        await model.pair()
        let request = try await fileRequest(secretName: "FIRST")
        model.present(request: request)
        await model.reject(request: request)

        #expect(model.answeredOutcome == .rejected)
        #expect(try await store.decision(requestIdentifier: request.requestIdentifier)?.signature == nil)
    }

    @Test
    func anUnpairedDeviceOffersNothingToAnswer() async throws {
        let model = makeModel()
        _ = try await fileRequest(secretName: "FIRST")
        await model.refresh()

        #expect(model.pairing == nil)
        #expect(model.openRequests.isEmpty)
    }

    @Test
    func aPairedDeviceFindsTheRequestsWaitingForItAtLaunch() async throws {
        let model = makeModel()
        await model.pair()
        let request = try await fileRequest(secretName: "FIRST")
        await model.refresh()

        #expect(model.openRequests.map(\.requestIdentifier) == [request.requestIdentifier])
        #expect(model.isPairingPublished)
        #expect(model.isNotificationAllowed)
        #expect(model.failureMessage == nil)
    }
}
