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
    func makeRequest(commandArguments: [String] = ["npm", "run", "deploy"], expiry: Date? = nil) -> RemoteApprovalRequest {
        let filed = RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
            secretScopes: SecretName(rawName: "API_TOKEN").map { [$0: SecretScope.shared(.user)] } ?? [:],
            commandArguments: commandArguments,
            requestingDeviceName: "Example Mac",
            now: now,
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
        guard let expiry else {
            return filed
        }
        return RemoteApprovalRequest(
            requestIdentifier: filed.requestIdentifier,
            nonce: filed.nonce,
            expiry: expiry,
            repositoryIdentity: filed.repositoryIdentity,
            secretScopes: filed.secretScopes,
            commandArguments: filed.commandArguments,
            requestingDeviceName: filed.requestingDeviceName
        )
    }

    func approval(request: RemoteApprovalRequest, key: P256.Signing.PrivateKey) throws -> Data {
        try RemoteApproval.signature(request: request) { try key.signature(for: $0) }
    }

    @Test
    func aFiledRequestExpiresAfterTheDecidedIntervalOnWholeSeconds() {
        let request = makeRequest()
        #expect(request.expiry == now.addingTimeInterval(RemoteApprovalSession.expiryInterval))
        #expect(request.expiry.timeIntervalSince1970 == request.expiry.timeIntervalSince1970.rounded(.down))
        #expect(request.nonce.count == RemoteApprovalRequest.nonceByteCount)
        #expect(makeRequest().requestIdentifier != request.requestIdentifier)
        #expect(makeRequest().nonce != request.nonce)
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
                repositoryIdentity: approvedRequest.repositoryIdentity,
                secretScopes: approvedRequest.secretScopes,
                commandArguments: approvedRequest.commandArguments,
                requestingDeviceName: approvedRequest.requestingDeviceName
            ),
            // The same identifier with a new nonce.
            RemoteApprovalRequest(
                requestIdentifier: approvedRequest.requestIdentifier,
                nonce: makeRequest().nonce,
                expiry: approvedRequest.expiry,
                repositoryIdentity: approvedRequest.repositoryIdentity,
                secretScopes: approvedRequest.secretScopes,
                commandArguments: approvedRequest.commandArguments,
                requestingDeviceName: approvedRequest.requestingDeviceName
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
                repositoryIdentity: approvedRequest.repositoryIdentity,
                secretScopes: approvedRequest.secretScopes,
                commandArguments: approvedRequest.commandArguments,
                requestingDeviceName: approvedRequest.requestingDeviceName
            ),
            // The same request with another command: what the user saw is part of the signature.
            RemoteApprovalRequest(
                requestIdentifier: approvedRequest.requestIdentifier,
                nonce: approvedRequest.nonce,
                expiry: approvedRequest.expiry,
                repositoryIdentity: approvedRequest.repositoryIdentity,
                secretScopes: approvedRequest.secretScopes,
                commandArguments: ["env"],
                requestingDeviceName: approvedRequest.requestingDeviceName
            ),
            // Another repository, and another secret, with everything else unchanged.
            RemoteApprovalRequest(
                requestIdentifier: approvedRequest.requestIdentifier,
                nonce: approvedRequest.nonce,
                expiry: approvedRequest.expiry,
                repositoryIdentity: RepositoryIdentity(value: "github.com/example/another-repository"),
                secretScopes: approvedRequest.secretScopes,
                commandArguments: approvedRequest.commandArguments,
                requestingDeviceName: approvedRequest.requestingDeviceName
            ),
            RemoteApprovalRequest(
                requestIdentifier: approvedRequest.requestIdentifier,
                nonce: approvedRequest.nonce,
                expiry: approvedRequest.expiry,
                repositoryIdentity: approvedRequest.repositoryIdentity,
                secretScopes: SecretName(rawName: "ANOTHER_TOKEN").map { [$0: SecretScope.shared(.user)] } ?? [:],
                commandArguments: approvedRequest.commandArguments,
                requestingDeviceName: approvedRequest.requestingDeviceName
            ),
        ]
        for request in alteredRequests {
            #expect(throws: RemoteApprovalVerificationError.signatureMismatch) {
                try RemoteApproval.verify(signature: signature, request: request, publicKey: pairedKey.publicKey, now: now)
            }
        }
    }

    /// A request whose secrets are the keys of `secretScopeNames`, each in the scope its value
    /// names (`repository`, `user`, or a custom scope). The identifier, nonce, and expiry are fixed,
    /// so that two requests built here differ only in what the arguments change and a signature of
    /// one can be checked against the other. The default command is short because no test of the
    /// scopes depends on it.
    func makeRequest(secretScopeNames: KeyValuePairs<String, String>, commandArguments: [String] = ["run"]) -> RemoteApprovalRequest {
        let repositoryIdentity = RepositoryIdentity(value: "github.com/example/repository")
        return RemoteApprovalRequest(
            requestIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            nonce: Data(),
            expiry: now,
            repositoryIdentity: repositoryIdentity,
            secretScopes: Dictionary(
                uniqueKeysWithValues: secretScopeNames.compactMap { rawName, rawScopeName in
                    SecretName(rawName: rawName).map { secretName in
                        (
                            secretName,
                            rawScopeName == SecretScope.repositoryScopeName
                                ? SecretScope.repository(repositoryIdentity)
                                : SecretScope.shared(SharedScope(name: rawScopeName)!)
                        )
                    }
                }
            ),
            commandArguments: commandArguments,
            requestingDeviceName: "Example Mac"
        )
    }

    @Test
    func theContentDigestIgnoresSecretOrderButNotArgumentBoundaries() {
        #expect(
            RemoteApproval.contentDigest(request: makeRequest(secretScopeNames: ["A": "user", "B": "repository"]))
                == RemoteApproval.contentDigest(request: makeRequest(secretScopeNames: ["B": "repository", "A": "user"]))
        )
        #expect(
            RemoteApproval.contentDigest(request: makeRequest(secretScopeNames: ["A": "user"], commandArguments: ["rm", "-rf"]))
                != RemoteApproval.contentDigest(request: makeRequest(secretScopeNames: ["A": "user"], commandArguments: ["rm -rf"]))
        )
    }

    /// The scope a secret comes from is part of what the user approves: an approval of a
    /// repository's own `API_TOKEN` must not pass the one of a shared scope, which reaches the
    /// repository through `~/.secchain` (https://github.com/bannzai/SecChain/issues/57).
    @Test
    func anApprovalDoesNotCoverTheSameNamesFromOtherScopes() throws {
        let approvedRequest = makeRequest(secretScopeNames: ["API_TOKEN": "repository", "OPENAI_API_KEY": "user"])
        let signature = try approval(request: approvedRequest, key: pairedKey)
        try RemoteApproval.verify(signature: signature, request: approvedRequest, publicKey: pairedKey.publicKey, now: now.addingTimeInterval(-1))
        let requestsWithOtherScopes = [
            makeRequest(secretScopeNames: ["API_TOKEN": "user", "OPENAI_API_KEY": "user"]),
            makeRequest(secretScopeNames: ["API_TOKEN": "repository", "OPENAI_API_KEY": "youtube"]),
            // The same two scopes, each given to the other name.
            makeRequest(secretScopeNames: ["API_TOKEN": "user", "OPENAI_API_KEY": "repository"]),
        ]
        for request in requestsWithOtherScopes {
            #expect(request.secretNames == approvedRequest.secretNames)
            #expect(throws: RemoteApprovalVerificationError.signatureMismatch) {
                try RemoteApproval.verify(signature: signature, request: request, publicKey: pairedKey.publicKey, now: now.addingTimeInterval(-1))
            }
        }
    }

    /// Each name and its scope are length-prefixed on their own, so that bytes cannot move between
    /// a name and the scope next to it.
    @Test
    func theContentDigestKeepsTheBoundaryBetweenANameAndItsScope() {
        #expect(
            RemoteApproval.contentDigest(request: makeRequest(secretScopeNames: ["A": "user"]))
                != RemoteApproval.contentDigest(request: makeRequest(secretScopeNames: ["Au": "ser"]))
        )
    }

    @Test
    func theSignedExpiryIsTruncatedToWholeSeconds() {
        let request = makeRequest()
        let requestReadBackWithMillisecondPrecision = RemoteApprovalRequest(
            requestIdentifier: request.requestIdentifier,
            nonce: request.nonce,
            expiry: Date(timeIntervalSince1970: (request.expiry.timeIntervalSince1970 * 1000).rounded(.down) / 1000 + 0.0004),
            repositoryIdentity: request.repositoryIdentity,
            secretScopes: request.secretScopes,
            commandArguments: request.commandArguments,
            requestingDeviceName: request.requestingDeviceName
        )
        #expect(RemoteApproval.signedMessage(request: request) == RemoteApproval.signedMessage(request: requestReadBackWithMillisecondPrecision))
    }

    /// The layout is what the iOS app signs, so a change to it has to be deliberate: it makes
    /// every Mac's enrolled key reject every approval until both sides ship the new version.
    @Test
    func theSignedMessageIsThePrefixTheIdentifierTheNonceTheExpiryAndTheContentDigest() {
        let request = makeRequest()
        #expect(
            RemoteApproval.signedMessage(request: request) == RemoteApproval.signedMessagePrefix
                + withUnsafeBytes(of: request.requestIdentifier.uuid) { Data($0) }
                + RemoteApproval.lengthPrefixed(field: request.nonce)
                + withUnsafeBytes(of: Int64(request.expiry.timeIntervalSince1970).bigEndian) { Data($0) }
                + RemoteApproval.lengthPrefixed(field: RemoteApproval.contentDigest(request: request))
        )
        #expect(RemoteApproval.signedMessagePrefix == Data("SecChain remote approval v2\n".utf8))
    }
}
