import CloudKit
import Foundation

/// Conversion between the remote approval value types and `CKRecord`. It is separated from the
/// database calls (`CloudKitRemoteApprovalStore`) because a `CKRecord` can be built and read
/// without an iCloud account, which makes the field layout that both front ends and the production
/// schema depend on unit-testable (documents/remote-approval-records.md).
public enum RemoteApprovalCloudKitRecords {
    public static func record(request: RemoteApprovalRequest) -> CKRecord {
        let record = CKRecord(
            recordType: RemoteApprovalRecordType.request,
            recordID: CKRecord.ID(recordName: RemoteApprovalRecordName.request(requestIdentifier: request.requestIdentifier))
        )
        record[RemoteApprovalRecordField.schemaVersion] = remoteApprovalSchemaVersion
        record[RemoteApprovalRecordField.requestIdentifier] = request.requestIdentifier.uuidString
        record[RemoteApprovalRecordField.nonce] = request.nonce
        record[RemoteApprovalRecordField.expiry] = request.expiry
        record[RemoteApprovalRecordField.repositoryIdentity] = request.repositoryIdentity.value
        record[RemoteApprovalRecordField.secretNames] = request.secretNames.map(\.value)
        record[RemoteApprovalRecordField.commandArguments] = request.commandArguments
        record[RemoteApprovalRecordField.requestingDeviceName] = request.requestingDeviceName
        return record
    }

    public static func request(record: CKRecord) throws -> RemoteApprovalRequest {
        try validate(record: record, recordType: RemoteApprovalRecordType.request)
        let secretNames = try field(record: record, name: RemoteApprovalRecordField.secretNames, type: [String].self)
        return RemoteApprovalRequest(
            requestIdentifier: try identifier(record: record),
            nonce: try field(record: record, name: RemoteApprovalRecordField.nonce, type: Data.self),
            expiry: try field(record: record, name: RemoteApprovalRecordField.expiry, type: Date.self),
            repositoryIdentity: RepositoryIdentity(
                value: try field(record: record, name: RemoteApprovalRecordField.repositoryIdentity, type: String.self)
            ),
            secretNames: try secretNames.map { rawName in
                guard let secretName = SecretName(rawName: rawName) else {
                    throw RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.secretNames)
                }
                return secretName
            },
            commandArguments: try field(record: record, name: RemoteApprovalRecordField.commandArguments, type: [String].self),
            requestingDeviceName: try field(record: record, name: RemoteApprovalRecordField.requestingDeviceName, type: String.self)
        )
    }

    public static func record(decision: RemoteApprovalDecision) -> CKRecord {
        let record = CKRecord(
            recordType: RemoteApprovalRecordType.decision,
            recordID: CKRecord.ID(recordName: RemoteApprovalRecordName.decision(requestIdentifier: decision.requestIdentifier))
        )
        record[RemoteApprovalRecordField.schemaVersion] = remoteApprovalSchemaVersion
        record[RemoteApprovalRecordField.requestIdentifier] = decision.requestIdentifier.uuidString
        record[RemoteApprovalRecordField.outcome] = decision.outcome.rawValue
        record[RemoteApprovalRecordField.signature] = decision.signature
        return record
    }

    public static func decision(record: CKRecord) throws -> RemoteApprovalDecision {
        try validate(record: record, recordType: RemoteApprovalRecordType.decision)
        let rawOutcome = try field(record: record, name: RemoteApprovalRecordField.outcome, type: String.self)
        guard let outcome = RemoteApprovalOutcome(rawValue: rawOutcome) else {
            throw RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.outcome)
        }
        return RemoteApprovalDecision(
            requestIdentifier: try identifier(record: record),
            outcome: outcome,
            // A missing signature is not an error here: it is one of the forgeries that
            // `RemoteApproval.verify` has to refuse, and a rejection carries none.
            signature: record[RemoteApprovalRecordField.signature] as? Data
        )
    }

    public static func record(cancellation: RemoteApprovalCancellation) -> CKRecord {
        let record = CKRecord(
            recordType: RemoteApprovalRecordType.cancellation,
            recordID: CKRecord.ID(recordName: RemoteApprovalRecordName.cancellation(requestIdentifier: cancellation.requestIdentifier))
        )
        record[RemoteApprovalRecordField.schemaVersion] = remoteApprovalSchemaVersion
        record[RemoteApprovalRecordField.requestIdentifier] = cancellation.requestIdentifier.uuidString
        return record
    }

    public static func cancellation(record: CKRecord) throws -> RemoteApprovalCancellation {
        try validate(record: record, recordType: RemoteApprovalRecordType.cancellation)
        return RemoteApprovalCancellation(requestIdentifier: try identifier(record: record))
    }

    public static func record(pairing: RemoteApprovalPairing) -> CKRecord {
        let record = CKRecord(
            recordType: RemoteApprovalRecordType.pairing,
            recordID: CKRecord.ID(recordName: RemoteApprovalRecordName.pairing(publicKeyRepresentation: pairing.publicKeyRepresentation))
        )
        record[RemoteApprovalRecordField.schemaVersion] = remoteApprovalSchemaVersion
        record[RemoteApprovalRecordField.publicKey] = pairing.publicKeyRepresentation
        record[RemoteApprovalRecordField.deviceName] = pairing.deviceName
        return record
    }

    public static func pairing(record: CKRecord) throws -> RemoteApprovalPairing {
        try validate(record: record, recordType: RemoteApprovalRecordType.pairing)
        return RemoteApprovalPairing(
            publicKeyRepresentation: try field(record: record, name: RemoteApprovalRecordField.publicKey, type: Data.self),
            deviceName: try field(record: record, name: RemoteApprovalRecordField.deviceName, type: String.self)
        )
    }

    /// The predicate that fetches every record of a type. A `CKQuery` needs a field that the schema
    /// indexes as queryable, and the system `recordName` is not indexed unless someone marks it in
    /// the CloudKit Console; `schemaVersion` is a field of every record, so the query works in the
    /// development environment as soon as the first record exists and needs no manual step.
    public static func everyRecordPredicate() -> NSPredicate {
        NSPredicate(format: "%K >= %@", RemoteApprovalRecordField.schemaVersion, NSNumber(value: 1))
    }

    /// Checks the record type and the layout version before any field is read, so that a record of
    /// another version is reported rather than half-read.
    static func validate(record: CKRecord, recordType: String) throws {
        guard record.recordType == recordType else {
            throw RemoteApprovalRecordError.unexpectedRecordType(expected: recordType, found: record.recordType)
        }
        let schemaVersion = try field(record: record, name: RemoteApprovalRecordField.schemaVersion, type: Int.self)
        guard schemaVersion == remoteApprovalSchemaVersion else {
            throw RemoteApprovalRecordError.unsupportedSchemaVersion(found: schemaVersion, supported: remoteApprovalSchemaVersion)
        }
    }

    static func identifier(record: CKRecord) throws -> UUID {
        guard let requestIdentifier = UUID(uuidString: try field(record: record, name: RemoteApprovalRecordField.requestIdentifier, type: String.self)) else {
            throw RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.requestIdentifier)
        }
        return requestIdentifier
    }

    /// One field, telling a missing field apart from one of the wrong type: the first means the
    /// record was written by another version, the second that something else wrote it.
    static func field<Value>(record: CKRecord, name: String, type: Value.Type) throws -> Value {
        guard let value = record[name] else {
            throw RemoteApprovalRecordError.missingField(name: name)
        }
        guard let typedValue = value as? Value else {
            throw RemoteApprovalRecordError.malformedField(name: name)
        }
        return typedValue
    }
}
