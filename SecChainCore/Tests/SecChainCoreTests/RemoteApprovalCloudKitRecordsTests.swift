import CloudKit
import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

@Suite
struct RemoteApprovalCloudKitRecordsTests {
    let pairedKey = P256.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A request with a secret of the repository, one of the user scope, and one of a custom scope.
    func makeRequest() -> RemoteApprovalRequest {
        let repositoryIdentity = RepositoryIdentity(value: "github.com/example/repository")
        return RemoteApprovalRequest.filed(
            repositoryIdentity: repositoryIdentity,
            secretScopes: Dictionary(
                uniqueKeysWithValues: [
                    ("DEPLOY_KEY", SecretScope.repository(repositoryIdentity)),
                    ("API_TOKEN", SecretScope.shared(.user)),
                    ("YOUTUBE_API_KEY", SecretScope.shared(SharedScope(name: "youtube")!)),
                ].compactMap { rawName, secretScope in
                    SecretName(rawName: rawName).map { ($0, secretScope) }
                }
            ),
            commandArguments: ["npm", "run", "deploy"],
            requestingDeviceName: "Example Mac",
            now: now,
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
    }

    @Test
    func aRequestRoundTripsThroughItsRecord() throws {
        let request = makeRequest()
        let record = RemoteApprovalCloudKitRecords.record(request: request)
        #expect(record.recordType == RemoteApprovalRecordType.request)
        #expect(record.recordID.recordName == RemoteApprovalRecordName.request(requestIdentifier: request.requestIdentifier))
        #expect(try RemoteApprovalCloudKitRecords.request(record: record) == request)
    }

    /// The two lists are read pairwise, so each name has to sit next to its own scope.
    @Test
    func aRequestStoresEachNameAtTheIndexOfItsScope() {
        let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
        #expect(record[RemoteApprovalRecordField.secretNames] as? [String] == ["API_TOKEN", "DEPLOY_KEY", "YOUTUBE_API_KEY"])
        #expect(record[RemoteApprovalRecordField.secretScopes] as? [String] == ["user", "repository", "youtube"])
    }

    /// What the iPhone signs is the request it read back, so the scopes it read have to produce
    /// the message the Mac verifies against its own copy.
    @Test
    func anApprovalOfTheRequestReadBackVerifiesAgainstTheMacsCopy() throws {
        let request = makeRequest()
        let requestReadBack = try RemoteApprovalCloudKitRecords.request(record: RemoteApprovalCloudKitRecords.record(request: request))
        try RemoteApproval.verify(
            signature: try RemoteApproval.signature(request: requestReadBack) { try pairedKey.signature(for: $0) },
            request: request,
            publicKey: pairedKey.publicKey,
            now: now
        )
    }

    @Test
    func aRequestWhoseScopesDoNotMatchItsNamesIsRefused() {
        let malformedSecretScopes: [[String]] = [
            // One scope fewer than names.
            ["user", "repository"],
            // Not a scope name.
            ["user", "repository", "Not A Scope"],
        ]
        for secretScopes in malformedSecretScopes {
            let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
            record[RemoteApprovalRecordField.secretScopes] = secretScopes
            #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.secretScopes)) {
                try RemoteApprovalCloudKitRecords.request(record: record)
            }
        }
    }

    /// A name listed twice could be shown with one scope and signed with the other.
    @Test
    func aRequestThatListsANameTwiceIsRefused() {
        let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
        record[RemoteApprovalRecordField.secretNames] = ["API_TOKEN", "API_TOKEN", "YOUTUBE_API_KEY"]
        #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.secretNames)) {
            try RemoteApprovalCloudKitRecords.request(record: record)
        }
    }

    /// A request filed by a Mac of version 1 carries no scopes, and an approval of it would be
    /// signed over another message: it is refused as a whole rather than shown without them.
    @Test
    func aRequestOfSchemaVersion1IsRefused() {
        let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
        record[RemoteApprovalRecordField.schemaVersion] = 1
        record[RemoteApprovalRecordField.secretScopes] = nil
        #expect(throws: RemoteApprovalRecordError.unsupportedSchemaVersion(found: 1, supported: 2)) {
            try RemoteApprovalCloudKitRecords.request(record: record)
        }
    }

    /// Every record type is refused in version 1, the pairing too, although its fields did not
    /// change: the version is one number for the whole protocol (documents/remote-approval-records.md).
    @Test
    func everyRecordOfSchemaVersion1IsRefused() {
        let request = makeRequest()
        let decisionRecord = RemoteApprovalCloudKitRecords.record(
            decision: RemoteApprovalDecision(requestIdentifier: request.requestIdentifier, outcome: .rejected, signature: nil)
        )
        let cancellationRecord = RemoteApprovalCloudKitRecords.record(cancellation: RemoteApprovalCancellation(requestIdentifier: request.requestIdentifier))
        let pairingRecord = RemoteApprovalCloudKitRecords.record(
            pairing: RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "Example iPhone")
        )
        for record in [decisionRecord, cancellationRecord, pairingRecord] {
            record[RemoteApprovalRecordField.schemaVersion] = 1
        }
        let unsupportedSchemaVersion = RemoteApprovalRecordError.unsupportedSchemaVersion(found: 1, supported: 2)
        #expect(throws: unsupportedSchemaVersion) {
            try RemoteApprovalCloudKitRecords.decision(record: decisionRecord)
        }
        #expect(throws: unsupportedSchemaVersion) {
            try RemoteApprovalCloudKitRecords.cancellation(record: cancellationRecord)
        }
        #expect(throws: unsupportedSchemaVersion) {
            try RemoteApprovalCloudKitRecords.pairing(record: pairingRecord)
        }
    }

    @Test
    func anApprovalRoundTripsThroughItsRecord() throws {
        let request = makeRequest()
        let decision = RemoteApprovalDecision(
            requestIdentifier: request.requestIdentifier,
            outcome: .approved,
            signature: try RemoteApproval.signature(request: request) { try pairedKey.signature(for: $0) }
        )
        let record = RemoteApprovalCloudKitRecords.record(decision: decision)
        #expect(record.recordType == RemoteApprovalRecordType.decision)
        #expect(record.recordID.recordName == RemoteApprovalRecordName.decision(requestIdentifier: request.requestIdentifier))
        #expect(try RemoteApprovalCloudKitRecords.decision(record: record) == decision)
    }

    /// An answer claiming an approval without a signature has to reach the verification, which is
    /// what refuses it. Failing to decode it would hide the forgery behind a schema error.
    @Test
    func anApprovalWithoutASignatureStillDecodes() throws {
        let decision = RemoteApprovalDecision(requestIdentifier: UUID(), outcome: .approved, signature: nil)
        #expect(try RemoteApprovalCloudKitRecords.decision(record: RemoteApprovalCloudKitRecords.record(decision: decision)) == decision)
    }

    @Test
    func aRejectionRoundTripsThroughItsRecord() throws {
        let decision = RemoteApprovalDecision(requestIdentifier: UUID(), outcome: .rejected, signature: nil)
        #expect(try RemoteApprovalCloudKitRecords.decision(record: RemoteApprovalCloudKitRecords.record(decision: decision)) == decision)
    }

    @Test
    func aCancellationRoundTripsThroughItsRecord() throws {
        let cancellation = RemoteApprovalCancellation(requestIdentifier: UUID())
        let record = RemoteApprovalCloudKitRecords.record(cancellation: cancellation)
        #expect(record.recordType == RemoteApprovalRecordType.cancellation)
        #expect(record.recordID.recordName == RemoteApprovalRecordName.cancellation(requestIdentifier: cancellation.requestIdentifier))
        #expect(try RemoteApprovalCloudKitRecords.cancellation(record: record) == cancellation)
    }

    @Test
    func aPairingRoundTripsThroughItsRecord() throws {
        let pairing = RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "Example iPhone")
        let record = RemoteApprovalCloudKitRecords.record(pairing: pairing)
        #expect(record.recordType == RemoteApprovalRecordType.pairing)
        #expect(record.recordID.recordName == RemoteApprovalRecordName.pairing(publicKeyRepresentation: pairing.publicKeyRepresentation))
        #expect(try RemoteApprovalCloudKitRecords.pairing(record: record) == pairing)
    }

    @Test
    func aRecordOfAnotherTypeIsRefused() {
        let record = RemoteApprovalCloudKitRecords.record(cancellation: RemoteApprovalCancellation(requestIdentifier: UUID()))
        #expect(
            throws: RemoteApprovalRecordError.unexpectedRecordType(
                expected: RemoteApprovalRecordType.request,
                found: RemoteApprovalRecordType.cancellation
            )
        ) {
            try RemoteApprovalCloudKitRecords.request(record: record)
        }
    }

    @Test
    func aRecordOfAnotherSchemaVersionIsRefusedBeforeAnyFieldIsRead() {
        let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
        record[RemoteApprovalRecordField.schemaVersion] = remoteApprovalSchemaVersion + 1
        record[RemoteApprovalRecordField.nonce] = nil
        #expect(
            throws: RemoteApprovalRecordError.unsupportedSchemaVersion(
                found: remoteApprovalSchemaVersion + 1,
                supported: remoteApprovalSchemaVersion
            )
        ) {
            try RemoteApprovalCloudKitRecords.request(record: record)
        }
    }

    @Test
    func aMissingFieldNamesTheField() {
        let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
        record[RemoteApprovalRecordField.nonce] = nil
        #expect(throws: RemoteApprovalRecordError.missingField(name: RemoteApprovalRecordField.nonce)) {
            try RemoteApprovalCloudKitRecords.request(record: record)
        }
    }

    @Test
    func aFieldOfAnotherTypeNamesTheField() {
        let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
        record[RemoteApprovalRecordField.nonce] = "not-bytes"
        #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.nonce)) {
            try RemoteApprovalCloudKitRecords.request(record: record)
        }
    }

    @Test
    func aNameThatIsNotAValidSecretNameIsRefused() {
        let record = RemoteApprovalCloudKitRecords.record(request: makeRequest())
        record[RemoteApprovalRecordField.secretNames] = ["not a secret name", "DEPLOY_KEY", "YOUTUBE_API_KEY"]
        #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.secretNames)) {
            try RemoteApprovalCloudKitRecords.request(record: record)
        }
    }

    @Test
    func anIdentifierThatIsNotAUUIDIsRefused() {
        let record = RemoteApprovalCloudKitRecords.record(decision: RemoteApprovalDecision(requestIdentifier: UUID(), outcome: .rejected, signature: nil))
        record[RemoteApprovalRecordField.requestIdentifier] = "not-a-uuid"
        #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.requestIdentifier)) {
            try RemoteApprovalCloudKitRecords.decision(record: record)
        }
    }

    @Test
    func anOutcomeThatIsNeitherApprovedNorRejectedIsRefused() {
        let record = RemoteApprovalCloudKitRecords.record(decision: RemoteApprovalDecision(requestIdentifier: UUID(), outcome: .rejected, signature: nil))
        record[RemoteApprovalRecordField.outcome] = "maybe"
        #expect(throws: RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.outcome)) {
            try RemoteApprovalCloudKitRecords.decision(record: record)
        }
    }

    /// A query must not depend on the system `recordName` being marked queryable, which is a step
    /// in the CloudKit Console that nothing in the repository can perform.
    @Test
    func theQueryForEveryRecordFiltersOnAFieldOfTheProtocol() {
        #expect(RemoteApprovalCloudKitRecords.everyRecordPredicate().predicateFormat.contains(RemoteApprovalRecordField.schemaVersion))
        #expect(RemoteApprovalCloudKitRecords.everyRecordPredicate().evaluate(with: [RemoteApprovalRecordField.schemaVersion: remoteApprovalSchemaVersion]))
    }

    /// Every field of every record type, so that the fields named here are the ones the production
    /// schema has to carry (documents/remote-approval-records.md, issue #16).
    @Test
    func theRecordsCarryExactlyTheDocumentedFields() {
        let request = makeRequest()
        #expect(
            Set(RemoteApprovalCloudKitRecords.record(request: request).allKeys()) == [
                RemoteApprovalRecordField.schemaVersion,
                RemoteApprovalRecordField.requestIdentifier,
                RemoteApprovalRecordField.nonce,
                RemoteApprovalRecordField.expiry,
                RemoteApprovalRecordField.repositoryIdentity,
                RemoteApprovalRecordField.secretNames,
                RemoteApprovalRecordField.secretScopes,
                RemoteApprovalRecordField.commandArguments,
                RemoteApprovalRecordField.requestingDeviceName,
            ]
        )
        #expect(
            Set(
                RemoteApprovalCloudKitRecords.record(
                    decision: RemoteApprovalDecision(requestIdentifier: request.requestIdentifier, outcome: .approved, signature: Data([1]))
                ).allKeys()
            ) == [
                RemoteApprovalRecordField.schemaVersion,
                RemoteApprovalRecordField.requestIdentifier,
                RemoteApprovalRecordField.outcome,
                RemoteApprovalRecordField.signature,
            ]
        )
        #expect(
            Set(RemoteApprovalCloudKitRecords.record(cancellation: RemoteApprovalCancellation(requestIdentifier: request.requestIdentifier)).allKeys()) == [
                RemoteApprovalRecordField.schemaVersion,
                RemoteApprovalRecordField.requestIdentifier,
            ]
        )
        #expect(
            Set(
                RemoteApprovalCloudKitRecords.record(
                    pairing: RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "Example iPhone")
                ).allKeys()
            ) == [
                RemoteApprovalRecordField.schemaVersion,
                RemoteApprovalRecordField.publicKey,
                RemoteApprovalRecordField.deviceName,
            ]
        )
    }

    /// The same invariant as `RemoteApprovalRecordsTests.noRecordOfTheProtocolCanCarryASecretValue`,
    /// checked on the bytes that actually leave the Mac.
    @Test
    func noEncodedRecordCanCarryASecretValue() throws {
        let dummyValue = "dummy-value-for-test"
        let request = makeRequest()
        let records = [
            RemoteApprovalCloudKitRecords.record(request: request),
            RemoteApprovalCloudKitRecords.record(
                decision: RemoteApprovalDecision(
                    requestIdentifier: request.requestIdentifier,
                    outcome: .approved,
                    signature: try RemoteApproval.signature(request: request) { try pairedKey.signature(for: $0) }
                )
            ),
            RemoteApprovalCloudKitRecords.record(cancellation: RemoteApprovalCancellation(requestIdentifier: request.requestIdentifier)),
            RemoteApprovalCloudKitRecords.record(
                pairing: RemoteApprovalPairing(publicKeyRepresentation: pairedKey.publicKey.x963Representation, deviceName: "Example iPhone")
            ),
        ]
        for record in records {
            #expect(!String(describing: record).contains(dummyValue))
            for key in record.allKeys() {
                #expect(!String(describing: record[key]).contains(dummyValue))
            }
        }
    }
}
