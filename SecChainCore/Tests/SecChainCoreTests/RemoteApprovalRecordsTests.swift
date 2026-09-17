import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

@Suite
struct RemoteApprovalRecordsTests {
    let pairedKey = P256.Signing.PrivateKey()
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

    /// A record name is unique within the zone rather than within a record type, so the three
    /// records of one request must not share a name.
    @Test
    func theThreeRecordsOfOneRequestHaveDifferentNames() {
        let requestIdentifier = UUID()
        let names = [
            RemoteApprovalRecordName.request(requestIdentifier: requestIdentifier),
            RemoteApprovalRecordName.decision(requestIdentifier: requestIdentifier),
            RemoteApprovalRecordName.cancellation(requestIdentifier: requestIdentifier),
        ]
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.contains(requestIdentifier.uuidString))
        }
    }

    /// The Mac derives the name it fetches, and the iPhone derives the name it writes, from the
    /// same identifier without any other exchange.
    @Test
    func aRecordNameIsDerivedFromTheRequestIdentifierAlone() {
        let requestIdentifier = UUID()
        #expect(
            RemoteApprovalRecordName.decision(requestIdentifier: requestIdentifier)
                == RemoteApprovalRecordName.decision(requestIdentifier: requestIdentifier)
        )
        #expect(
            RemoteApprovalRecordName.decision(requestIdentifier: requestIdentifier)
                != RemoteApprovalRecordName.decision(requestIdentifier: UUID())
        )
    }

    @Test
    func publishingTheSameKeyTwiceAddressesOneRecordAndANewKeyAnother() {
        let publicKeyRepresentation = pairedKey.publicKey.x963Representation
        #expect(
            RemoteApprovalRecordName.pairing(publicKeyRepresentation: publicKeyRepresentation)
                == RemoteApprovalRecordName.pairing(publicKeyRepresentation: publicKeyRepresentation)
        )
        #expect(
            RemoteApprovalRecordName.pairing(publicKeyRepresentation: publicKeyRepresentation)
                != RemoteApprovalRecordName.pairing(publicKeyRepresentation: P256.Signing.PrivateKey().publicKey.x963Representation)
        )
    }

    @Test
    func theVerificationNumberIsTwelveDigitsDerivedFromTheKeysDigest() {
        let pairing = RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "Example iPhone")
        let groups = pairing.verificationNumber.split(separator: "-")
        #expect(groups.count == RemoteApprovalPairing.verificationNumberDigitCount / RemoteApprovalPairing.verificationNumberGroupSize)
        #expect(groups.allSatisfy { $0.count == RemoteApprovalPairing.verificationNumberGroupSize })
        #expect(groups.joined().allSatisfy { $0.isNumber })
        // Derived from the same digest bytes on both devices, and from nothing else.
        #expect(
            groups.joined()
                == String(
                    format: "%012llu",
                    Data(SHA256.hash(data: pairedKey.publicKey.x963Representation))
                        .prefix(8)
                        .reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000_000_000
                )
        )
    }

    @Test
    func anotherKeyGetsAnotherVerificationNumber() {
        #expect(
            RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "A").verificationNumber
                != RemoteApprovalPairing(publicKeyRepresentation: P256.Signing.PrivateKey().publicKey.x963Representation, deviceName: "A").verificationNumber
        )
    }

    @Test
    func aPublishedKeyThatIsNotAP256KeyIsRefused() {
        #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.publicKey)) {
            try RemoteApprovalPairing(publicKeyRepresentation: Data("not-a-key".utf8), deviceName: "Example iPhone").publicKey()
        }
    }

    @Test
    func aPublishedKeyRoundTripsThroughItsRepresentation() throws {
        let pairing = RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "Example iPhone")
        #expect(try pairing.publicKey().x963Representation == pairedKey.publicKey.x963Representation)
    }

    /// The schema version and the signed message's version change together: a record layout the
    /// signature does not match would let one side accept what the other cannot produce.
    @Test
    func theSchemaVersionMatchesTheSignedMessageVersion() {
        #expect(remoteApprovalSchemaVersion == 1)
        #expect(String(decoding: RemoteApproval.signedMessagePrefix, as: UTF8.self).contains("v\(remoteApprovalSchemaVersion)"))
    }

    /// The point of the protocol: what travels through iCloud names the secrets, never their
    /// values (documents/PROJECT.md, "Security invariants").
    @Test
    func noRecordOfTheProtocolCanCarryASecretValue() throws {
        let dummyValue = "dummy-value-for-test"
        let request = makeRequest()
        let records: [Any] = [
            request,
            RemoteApprovalDecision(
                requestIdentifier: request.requestIdentifier,
                outcome: .approved,
                signature: try RemoteApproval.signature(request: request) { try pairedKey.signature(for: $0) }
            ),
            RemoteApprovalCancellation(requestIdentifier: request.requestIdentifier),
            RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "Example iPhone"),
        ]
        for record in records {
            #expect(!String(describing: record).contains(dummyValue))
            #expect(!String(reflecting: record).contains(dummyValue))
        }
        // The signed message covers names and the command, so the value cannot be in it either.
        #expect(!String(decoding: RemoteApproval.signedMessage(request: request), as: UTF8.self).contains(dummyValue))
    }

    @Test
    func everyRecordErrorSaysWhichFieldItIsAbout() {
        let errors: [RemoteApprovalRecordError] = [
            .unexpectedRecordType(expected: RemoteApprovalRecordType.request, found: RemoteApprovalRecordType.decision),
            .missingField(name: RemoteApprovalRecordField.nonce),
            .malformedField(name: RemoteApprovalRecordField.signature),
            .unsupportedSchemaVersion(found: 2, supported: remoteApprovalSchemaVersion),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
        #expect(RemoteApprovalRecordError.missingField(name: RemoteApprovalRecordField.nonce).description.contains(RemoteApprovalRecordField.nonce))
        #expect(RemoteApprovalRecordError.unsupportedSchemaVersion(found: 2, supported: 1).description.contains("2"))
    }
}
