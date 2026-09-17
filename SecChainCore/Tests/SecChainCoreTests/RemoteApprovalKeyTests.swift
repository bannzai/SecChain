import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

/// What the Secure Enclave key has to do is verified on a device (the key cannot be created on the
/// Simulator), so these tests cover the part that is the same for both keys: the signature a Mac
/// accepts, and the pairing a Mac enrolls.
@Suite
struct RemoteApprovalKeyTests {
    let key = SoftwareRemoteApprovalKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeRequest() -> RemoteApprovalRequest {
        RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
            secretNames: [SecretName(rawName: "API_TOKEN")].compactMap { $0 },
            commandArguments: ["npm", "run", "deploy"],
            requestingDeviceName: "Example Mac",
            now: now,
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
    }

    @Test
    func theSignatureOfAKeyIsAcceptedByTheMacThatEnrolledItsPublicKey() throws {
        let request = makeRequest()
        try RemoteApproval.verify(
            signature: try key.approvalSignature(request: request),
            request: request,
            publicKey: try key.pairing(deviceName: "Example iPhone").publicKey(),
            now: now
        )
    }

    @Test
    func aSignatureOfOneRequestIsRefusedForAnother() throws {
        let signature = try key.approvalSignature(request: makeRequest())
        #expect(throws: RemoteApprovalVerificationError.signatureMismatch) {
            try RemoteApproval.verify(
                signature: signature,
                request: makeRequest(),
                publicKey: try key.pairing(deviceName: "Example iPhone").publicKey(),
                now: now
            )
        }
    }

    @Test
    func theSignatureOfAnotherKeyIsRefused() throws {
        let request = makeRequest()
        #expect(throws: RemoteApprovalVerificationError.signatureMismatch) {
            try RemoteApproval.verify(
                signature: try SoftwareRemoteApprovalKey().approvalSignature(request: request),
                request: request,
                publicKey: try key.pairing(deviceName: "Example iPhone").publicKey(),
                now: now
            )
        }
    }

    @Test
    func thePairingPublishesTheKeyAndTheNumberBothScreensCompare() throws {
        let pairing = key.pairing(deviceName: "Example iPhone")
        #expect(pairing.publicKeyRepresentation == key.publicKeyRepresentation)
        #expect(pairing.deviceName == "Example iPhone")
        // The Mac derives the number from the published bytes alone, so both screens show the same
        // one only when they are looking at the same key.
        #expect(pairing.verificationNumber == RemoteApprovalPairing.verificationNumber(publicKeyRepresentation: key.publicKeyRepresentation))
        #expect(pairing.verificationNumber != SoftwareRemoteApprovalKey().pairing(deviceName: "Example iPhone").verificationNumber)
    }
}
