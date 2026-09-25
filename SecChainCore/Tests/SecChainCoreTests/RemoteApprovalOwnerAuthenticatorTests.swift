import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

@Suite
struct OwnerAuthenticationRoutingTests {
    /// The three cases of design decision 5, and the case where nothing is paired.
    @Test
    func aPairedMacAsksTheIPhoneOnlyWhenItWasToldTo() {
        #expect(
            OwnerAuthenticationRouting.route(
                isPaired: true,
                answersConfirmOnTheIPhone: false,
                approveRemotelyRequested: true,
                includesDeviceBoundSecret: false
            ) == .pairedIPhone
        )
        #expect(
            OwnerAuthenticationRouting.route(
                isPaired: true,
                answersConfirmOnTheIPhone: true,
                approveRemotelyRequested: false,
                includesDeviceBoundSecret: false
            ) == .pairedIPhone
        )
        #expect(
            OwnerAuthenticationRouting.route(
                isPaired: true,
                answersConfirmOnTheIPhone: false,
                approveRemotelyRequested: false,
                includesDeviceBoundSecret: false
            ) == .localPromptThenPairedIPhone
        )
    }

    /// Without a pairing every combination behaves as it did before remote approval existed.
    @Test
    func anUnpairedMacAlwaysAsksHere() {
        for answersConfirmOnTheIPhone in [true, false] {
            for approveRemotelyRequested in [true, false] {
                #expect(
                    OwnerAuthenticationRouting.route(
                        isPaired: false,
                        answersConfirmOnTheIPhone: answersConfirmOnTheIPhone,
                        approveRemotelyRequested: approveRemotelyRequested,
                        includesDeviceBoundSecret: false
                    ) == .localPrompt
                )
            }
        }
    }

    /// The Keychain itself demands user presence on the device that holds a device-bound value, and
    /// an approval from the iPhone cannot satisfy that.
    @Test
    func aDeviceBoundSecretIsAlwaysConfirmedOnThisMac() {
        for answersConfirmOnTheIPhone in [true, false] {
            for approveRemotelyRequested in [true, false] {
                #expect(
                    OwnerAuthenticationRouting.route(
                        isPaired: true,
                        answersConfirmOnTheIPhone: answersConfirmOnTheIPhone,
                        approveRemotelyRequested: approveRemotelyRequested,
                        includesDeviceBoundSecret: true
                    ) == .localPrompt
                )
            }
        }
    }
}

@Suite
struct RemoteApprovalOwnerAuthenticatorTests {
    let pairedKey = P256.Signing.PrivateKey()
    let startOfWaiting = Date(timeIntervalSince1970: 1_800_000_000)

    func makeRequest() -> RemoteApprovalRequest {
        RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
            secretScopes: SecretName(rawName: "API_TOKEN").map { [$0: SecretScope.shared(.user)] } ?? [:],
            commandArguments: ["npm", "run", "deploy"],
            requestingDeviceName: "Example Mac",
            now: startOfWaiting,
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
    }

    func makeAuthenticator(store: InMemoryRemoteApprovalStore, request: RemoteApprovalRequest) -> RemoteOwnerAuthenticator {
        RemoteOwnerAuthenticator(
            session: RemoteApprovalSession(
                store: store,
                enrolledPublicKey: pairedKey.publicKey,
                now: { self.startOfWaiting },
                sleep: { _ in },
                report: { _ in }
            ),
            request: request
        )
    }

    /// A *confirm* item carries no access control, so the Keychain needs no `LAContext` to return
    /// its value; that is what lets an approval from the iPhone stand in for a local prompt.
    @Test
    func averifiedApprovalAuthenticatesWithoutALocalAuthenticationContext() async throws {
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest()
        try await store.save(
            decision: RemoteApprovalDecision(
                requestIdentifier: request.requestIdentifier,
                outcome: .approved,
                signature: try RemoteApproval.signature(request: request) { try pairedKey.signature(for: $0) }
            )
        )
        #expect(try await makeAuthenticator(store: store, request: request).authenticate(reason: "read a secret").context == nil)
    }

    @Test
    func aRefusedApprovalIsNotAnAuthentication() async throws {
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest()
        try await store.save(
            decision: RemoteApprovalDecision(requestIdentifier: request.requestIdentifier, outcome: .rejected, signature: nil)
        )
        await #expect(throws: RemoteApprovalError.rejected) {
            try await makeAuthenticator(store: store, request: request).authenticate(reason: "read a secret")
        }
    }

    /// Only "no prompt can be shown here" moves the question to the iPhone. A failed or cancelled
    /// authentication is the user's answer and must not be asked again somewhere else.
    @Test
    func theQuestionMovesToTheIPhoneOnlyWhenNoPromptCanBeShown() async throws {
        let remoteAuthenticator = CountingOwnerAuthenticator(failure: nil)
        let reported = ReportedLines()
        let authenticator = LocalOrRemoteOwnerAuthenticator(
            localAuthenticator: CountingOwnerAuthenticator(failure: .authenticationNotPossible),
            remoteAuthenticator: remoteAuthenticator,
            report: { reported.append(line: $0) }
        )
        _ = try await authenticator.authenticate(reason: "read a secret")
        #expect(remoteAuthenticator.reasons == ["read a secret"])
        #expect(reported.all.count == 1)
        #expect(reported.all.first?.contains("iPhone") == true)
    }

    @Test
    func aFailedOrCancelledAuthenticationIsNotRetriedOnTheIPhone() async throws {
        for localFailure in [SecretStoreError.authenticationFailed, .authenticationCancelled, .authenticationUnavailable(reason: "no passcode")] {
            let remoteAuthenticator = CountingOwnerAuthenticator(failure: nil)
            let authenticator = LocalOrRemoteOwnerAuthenticator(
                localAuthenticator: CountingOwnerAuthenticator(failure: localFailure),
                remoteAuthenticator: remoteAuthenticator,
                report: { _ in }
            )
            await #expect(throws: localFailure) {
                try await authenticator.authenticate(reason: "read a secret")
            }
            #expect(remoteAuthenticator.reasons.isEmpty)
        }
    }

    /// The completion condition of issue #38, on the whole path a `secchain run` takes: a forged
    /// approval must not get a value out of the Keychain. The same store with a working approval
    /// does return it, so the refusal is the reason the value stayed in.
    @Test
    func aForgedApprovalGetsNoValueOutOfTheKeychain() async throws {
        let keychain = InMemorySecretKeychain()
        let repositoryIdentity = RepositoryIdentity(value: "github.com/example/repository")
        let secretName = try #require(SecretName(rawName: "API_TOKEN"))
        try await SecretStore(keychain: keychain, ownerAuthenticator: CountingOwnerAuthenticator(failure: nil))
            .set(
                name: secretName,
                value: SecretValue(exposingString: "dummy-value-for-test"),
                scope: .repository(repositoryIdentity),
                environment: nil,
                protectionLevel: .confirm,
                isSynchronized: true
            )

        let forgedStore = InMemoryRemoteApprovalStore()
        let request = makeRequest()
        try await forgedStore.save(
            decision: RemoteApprovalDecision(
                requestIdentifier: request.requestIdentifier,
                outcome: .approved,
                // A process running as the user can write an answer, but not one the enrolled key
                // would verify.
                signature: try RemoteApproval.signature(request: request) { try P256.Signing.PrivateKey().signature(for: $0) }
            )
        )
        await #expect(throws: RemoteApprovalError.unverifiableApproval(.signatureMismatch)) {
            try await SecretStore(keychain: keychain, ownerAuthenticator: makeAuthenticator(store: forgedStore, request: request))
                .values(names: [secretName], scopes: [.repository(repositoryIdentity)], environment: nil, authenticationReason: "run true")
        }

        let approvedStore = InMemoryRemoteApprovalStore()
        try await approvedStore.save(
            decision: RemoteApprovalDecision(
                requestIdentifier: request.requestIdentifier,
                outcome: .approved,
                signature: try RemoteApproval.signature(request: request) { try pairedKey.signature(for: $0) }
            )
        )
        #expect(
            try await SecretStore(keychain: keychain, ownerAuthenticator: makeAuthenticator(store: approvedStore, request: request))
                .values(names: [secretName], scopes: [.repository(repositoryIdentity)], environment: nil, authenticationReason: "run true")[secretName]?
                .exposedString == "dummy-value-for-test"
        )
    }

    @Test
    func anAnsweredLocalPromptNeverReachesTheIPhone() async throws {
        let remoteAuthenticator = CountingOwnerAuthenticator(failure: nil)
        let localAuthenticator = CountingOwnerAuthenticator(failure: nil)
        let authenticator = LocalOrRemoteOwnerAuthenticator(
            localAuthenticator: localAuthenticator,
            remoteAuthenticator: remoteAuthenticator,
            report: { _ in }
        )
        _ = try await authenticator.authenticate(reason: "read a secret")
        #expect(localAuthenticator.reasons == ["read a secret"])
        #expect(remoteAuthenticator.reasons.isEmpty)
    }
}
