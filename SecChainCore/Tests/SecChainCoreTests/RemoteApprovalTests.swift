import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

@Suite
struct RemoteApprovalTests {
    /// Stands in for the Secure Enclave key of the paired iPhone.
    let pairedKey = P256.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A request as the Mac would file it: fresh identifier and nonce, expiring two minutes from `now`.
    func makeRequest(expiry: Date? = nil) -> RemoteApprovalRequest {
        RemoteApprovalRequest(
            requestIdentifier: UUID(),
            nonce: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
            // Two minutes is the expiry proposed in issue #32.
            expiry: expiry ?? now.addingTimeInterval(120),
            contentDigest: RemoteApproval.contentDigest(
                repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
                secretNames: [SecretName(rawName: "API_TOKEN")].compactMap { $0 },
                commandArguments: ["npm", "run", "deploy"],
                requestingDeviceName: "Example Mac"
            )
        )
    }

    func approval(request: RemoteApprovalRequest, key: P256.Signing.PrivateKey) throws -> Data {
        try RemoteApproval.signature(request: request) { try key.signature(for: $0) }
    }

    @Test
    func anApprovalSignedByThePairedKeyForTheRequestIsAccepted() throws {
        let request = makeRequest()
        try RemoteApproval.verify(
            signature: try approval(request: request, key: pairedKey),
            request: request,
            publicKey: pairedKey.publicKey,
            now: now
        )
    }

    @Test
    func anApprovalWithoutASignatureIsRejected() {
        let request = makeRequest()
        for signature in [nil, Data()] {
            #expect(throws: RemoteApprovalVerificationError.missingSignature) {
                try RemoteApproval.verify(signature: signature, request: request, publicKey: pairedKey.publicKey, now: now)
            }
        }
    }

    @Test
    func bytesThatAreNotASignatureAreRejected() {
        #expect(throws: RemoteApprovalVerificationError.malformedSignature) {
            try RemoteApproval.verify(signature: Data("approved".utf8), request: makeRequest(), publicKey: pairedKey.publicKey, now: now)
        }
    }

    @Test
    func anApprovalSignedByAnotherKeyIsRejected() throws {
        let request = makeRequest()
        let signatureByAnotherKey = try approval(request: request, key: P256.Signing.PrivateKey())
        #expect(throws: RemoteApprovalVerificationError.signatureMismatch) {
            try RemoteApproval.verify(signature: signatureByAnotherKey, request: request, publicKey: pairedKey.publicKey, now: now)
        }
    }

    @Test
    func anExpiredRequestIsRejectedEvenWithAValidSignature() throws {
        let request = makeRequest()
        let signature = try approval(request: request, key: pairedKey)
        for verificationTime in [request.expiry, request.expiry.addingTimeInterval(1)] {
            #expect(throws: RemoteApprovalVerificationError.expired) {
                try RemoteApproval.verify(signature: signature, request: request, publicKey: pairedKey.publicKey, now: verificationTime)
            }
        }
    }

    @Test
    func anApprovalOfAnotherRequestIsRejected() throws {
        let approvedRequest = makeRequest()
        let signature = try approval(request: approvedRequest, key: pairedKey)
        let requestsReusingTheApproval = [
            // A new request that only differs in its identifier.
            RemoteApprovalRequest(
                requestIdentifier: UUID(),
                nonce: approvedRequest.nonce,
                expiry: approvedRequest.expiry,
                contentDigest: approvedRequest.contentDigest
            ),
            // The same identifier with a new nonce.
            RemoteApprovalRequest(
                requestIdentifier: approvedRequest.requestIdentifier,
                nonce: makeRequest().nonce,
                expiry: approvedRequest.expiry,
                contentDigest: approvedRequest.contentDigest
            ),
        ]
        for request in requestsReusingTheApproval {
            #expect(throws: RemoteApprovalVerificationError.signatureMismatch) {
                try RemoteApproval.verify(signature: signature, request: request, publicKey: pairedKey.publicKey, now: now)
            }
        }
    }

    @Test
    func anApprovalDoesNotCoverALaterExpiryOrOtherContent() throws {
        let approvedRequest = makeRequest()
        let signature = try approval(request: approvedRequest, key: pairedKey)
        let alteredRequests = [
            RemoteApprovalRequest(
                requestIdentifier: approvedRequest.requestIdentifier,
                nonce: approvedRequest.nonce,
                expiry: approvedRequest.expiry.addingTimeInterval(3600),
                contentDigest: approvedRequest.contentDigest
            ),
            RemoteApprovalRequest(
                requestIdentifier: approvedRequest.requestIdentifier,
                nonce: approvedRequest.nonce,
                expiry: approvedRequest.expiry,
                contentDigest: RemoteApproval.contentDigest(
                    repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
                    secretNames: [SecretName(rawName: "API_TOKEN")].compactMap { $0 },
                    commandArguments: ["env"],
                    requestingDeviceName: "Example Mac"
                )
            ),
        ]
        for request in alteredRequests {
            #expect(throws: RemoteApprovalVerificationError.signatureMismatch) {
                try RemoteApproval.verify(signature: signature, request: request, publicKey: pairedKey.publicKey, now: now)
            }
        }
    }

    @Test
    func theContentDigestIgnoresSecretOrderButNotArgumentBoundaries() {
        func digest(secretNames: [String], commandArguments: [String]) -> Data {
            RemoteApproval.contentDigest(
                repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
                secretNames: secretNames.compactMap { SecretName(rawName: $0) },
                commandArguments: commandArguments,
                requestingDeviceName: "Example Mac"
            )
        }
        #expect(digest(secretNames: ["A", "B"], commandArguments: ["run"]) == digest(secretNames: ["B", "A"], commandArguments: ["run"]))
        #expect(digest(secretNames: ["A"], commandArguments: ["rm", "-rf"]) != digest(secretNames: ["A"], commandArguments: ["rm -rf"]))
    }

    @Test
    func theSignedExpiryIsTruncatedToWholeSeconds() {
        let request = makeRequest()
        let requestReadBackWithMillisecondPrecision = RemoteApprovalRequest(
            requestIdentifier: request.requestIdentifier,
            nonce: request.nonce,
            expiry: Date(timeIntervalSince1970: (request.expiry.timeIntervalSince1970 * 1000).rounded(.down) / 1000 + 0.0004),
            contentDigest: request.contentDigest
        )
        #expect(RemoteApproval.signedMessage(request: request) == RemoteApproval.signedMessage(request: requestReadBackWithMillisecondPrecision))
    }
}
