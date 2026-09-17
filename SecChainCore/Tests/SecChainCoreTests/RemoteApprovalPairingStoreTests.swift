import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

@Suite
struct RemoteApprovalPairingStoreTests {
    let theIPhonesKey = P256.Signing.PrivateKey()
    let anotherIPhonesKey = P256.Signing.PrivateKey()
    let keychain = InMemoryRemoteApprovalPairingKeychain()
    let authenticator = CountingOwnerAuthenticator(failure: nil)

    var store: RemoteApprovalPairingStore {
        RemoteApprovalPairingStore(keychain: keychain, ownerAuthenticator: authenticator)
    }

    func pairing(key: P256.Signing.PrivateKey, deviceName: String = "Example iPhone") -> RemoteApprovalPairing {
        RemoteApprovalPairing(publicKeyRepresentation: key.publicKey.x963Representation, deviceName: deviceName)
    }

    @Test
    func aMacWithoutAPairingHasNothingEnrolledAndPromptsForNothing() throws {
        #expect(try store.enrolledPairing() == nil)
        #expect(try store.enrolledPublicKey() == nil)
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func theKeyWhoseNumberTheUserTypedIsEnrolledAfterAnAuthentication() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        let enrolledPairing = try await store.enroll(
            publishedPairings: [pairing(key: anotherIPhonesKey, deviceName: "Someone else's iPhone"), publishedPairing],
            number: publishedPairing.verificationNumber
        )
        #expect(enrolledPairing.pairing == publishedPairing)
        #expect(try store.enrolledPublicKey()?.x963Representation == theIPhonesKey.publicKey.x963Representation)
        #expect(authenticator.reasons.count == 1)
        #expect(authenticator.reasons.first?.contains("Example iPhone") == true)
        // Remote approval stays opt-in: pairing alone does not redirect confirm authentications.
        #expect(enrolledPairing.answersConfirmOnTheIPhone == false)
    }

    /// The groups the two screens show do not have to be typed.
    @Test
    func theNumberIsComparedByItsDigitsOnly() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        for typedNumber in [
            publishedPairing.verificationNumber,
            publishedPairing.verificationNumber.filter(\.isNumber),
            publishedPairing.verificationNumber.replacingOccurrences(of: "-", with: " "),
        ] {
            let keychain = InMemoryRemoteApprovalPairingKeychain()
            let store = RemoteApprovalPairingStore(keychain: keychain, ownerAuthenticator: CountingOwnerAuthenticator(failure: nil))
            #expect(try await store.enroll(publishedPairings: [publishedPairing], number: typedNumber).pairing == publishedPairing)
        }
    }

    @Test
    func aNumberThatMatchesNoPublishedKeyEnrollsNothingAndListsWhatIsPublished() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        await #expect(throws: RemoteApprovalPairingError.noKeyWithThatNumber(publishedNumbers: [publishedPairing.verificationNumber])) {
            try await store.enroll(publishedPairings: [publishedPairing], number: "0000-0000-0000")
        }
        #expect(try store.enrolledPairing() == nil)
        // The user is not asked to authenticate for a key that was not going to be enrolled.
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func pairingWithNoPublishedKeySaysWhatToDo() async throws {
        await #expect(throws: RemoteApprovalPairingError.noPublishedKey) {
            try await store.enroll(publishedPairings: [], number: "1234-5678-9012")
        }
        #expect(RemoteApprovalPairingError.noPublishedKey.description.contains("iPhone"))
    }

    @Test
    func aPublishedKeyThatIsNotAP256KeyIsRefusedBeforeTheAuthentication() async throws {
        let brokenPairing = RemoteApprovalPairing(publicKeyRepresentation: Data("not-a-key".utf8), deviceName: "Example iPhone")
        await #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.publicKey)) {
            try await store.enroll(publishedPairings: [brokenPairing], number: brokenPairing.verificationNumber)
        }
        #expect(try store.enrolledPairing() == nil)
        #expect(authenticator.reasons.isEmpty)
    }

    /// A refused authentication must leave the Mac trusting exactly what it trusted before.
    @Test
    func aRefusedAuthenticationEnrollsNothing() async throws {
        let store = RemoteApprovalPairingStore(
            keychain: keychain,
            ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationCancelled)
        )
        await #expect(throws: SecretStoreError.authenticationCancelled) {
            try await store.enroll(publishedPairings: [pairing(key: theIPhonesKey)], number: pairing(key: theIPhonesKey).verificationNumber)
        }
        #expect(try store.enrolledPairing() == nil)
    }

    @Test
    func enrollingTheSameKeyAgainKeepsTheSettingAndAnotherKeyResetsIt() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        try await store.enroll(publishedPairings: [publishedPairing], number: publishedPairing.verificationNumber)
        try await store.setAnswersConfirmOnTheIPhone(answersConfirmOnTheIPhone: true)
        #expect(try await store.enroll(publishedPairings: [publishedPairing], number: publishedPairing.verificationNumber).answersConfirmOnTheIPhone)
        let otherPairing = pairing(key: anotherIPhonesKey, deviceName: "Another iPhone")
        #expect(try await store.enroll(publishedPairings: [otherPairing], number: otherPairing.verificationNumber).answersConfirmOnTheIPhone == false)
    }

    @Test
    func theSettingIsChangedOnlyAfterAnAuthentication() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        try await store.enroll(publishedPairings: [publishedPairing], number: publishedPairing.verificationNumber)
        #expect(try await store.setAnswersConfirmOnTheIPhone(answersConfirmOnTheIPhone: true).answersConfirmOnTheIPhone)
        #expect(try store.enrolledPairing()?.answersConfirmOnTheIPhone == true)
        #expect(try await store.setAnswersConfirmOnTheIPhone(answersConfirmOnTheIPhone: false).answersConfirmOnTheIPhone == false)
        // One for the pairing and one for each change of the setting.
        #expect(authenticator.reasons.count == 3)
    }

    @Test
    func aRefusedAuthenticationLeavesTheSettingAsItWas() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        try await store.enroll(publishedPairings: [publishedPairing], number: publishedPairing.verificationNumber)
        let refusingStore = RemoteApprovalPairingStore(
            keychain: keychain,
            ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationFailed)
        )
        await #expect(throws: SecretStoreError.authenticationFailed) {
            try await refusingStore.setAnswersConfirmOnTheIPhone(answersConfirmOnTheIPhone: true)
        }
        #expect(try store.enrolledPairing()?.answersConfirmOnTheIPhone == false)
    }

    @Test
    func theSettingCannotBeChangedWithoutAPairing() async throws {
        await #expect(throws: RemoteApprovalPairingError.notPaired) {
            try await store.setAnswersConfirmOnTheIPhone(answersConfirmOnTheIPhone: true)
        }
        #expect(RemoteApprovalPairingError.notPaired.description.contains("secchain pair"))
    }

    @Test
    func removingThePairingNeedsAnAuthenticationAndIsIdempotent() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        try await store.enroll(publishedPairings: [publishedPairing], number: publishedPairing.verificationNumber)
        try await store.remove()
        #expect(try store.enrolledPairing() == nil)
        #expect(authenticator.reasons.count == 2)
        // Nothing to protect, so removing again succeeds without asking.
        try await store.remove()
        #expect(authenticator.reasons.count == 2)
    }

    @Test
    func aRefusedAuthenticationKeepsThePairing() async throws {
        let publishedPairing = pairing(key: theIPhonesKey)
        try await store.enroll(publishedPairings: [publishedPairing], number: publishedPairing.verificationNumber)
        let refusingStore = RemoteApprovalPairingStore(
            keychain: keychain,
            ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationCancelled)
        )
        await #expect(throws: SecretStoreError.authenticationCancelled) {
            try await refusingStore.remove()
        }
        #expect(try store.enrolledPairing()?.pairing == publishedPairing)
    }

    /// The pairing is stored as bytes, so it has to survive the round trip through them.
    @Test
    func theStoredPairingRoundTripsThroughItsEncodedForm() throws {
        let enrolledPairing = EnrolledPairing(pairing: pairing(key: theIPhonesKey), answersConfirmOnTheIPhone: true)
        #expect(
            try JSONDecoder().decode(EnrolledPairing.self, from: try JSONEncoder().encode(enrolledPairing)) == enrolledPairing
        )
    }
}
