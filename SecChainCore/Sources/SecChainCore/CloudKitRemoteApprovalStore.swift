import CloudKit
import Foundation
import Security

/// What this binary's code signature says about CloudKit. `CKContainer(identifier:)` stops a
/// process that is not signed for the container (measured: a trace trap inside CloudKit, exit
/// status 133), so every caller asks here before it creates a container.
public enum CloudKitEntitlements {
    /// Containers named in `com.apple.developer.icloud-container-identifiers`.
    public static func containerIdentifiers() -> [String] {
        #if os(macOS)
        (SecTaskCreateFromSelf(nil).flatMap {
            SecTaskCopyValueForEntitlement($0, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        } as? [String]) ?? []
        #else
        // `SecTaskCreateFromSelf` is macOS only. An iOS app cannot run without the entitlements it
        // was signed with, so there is nothing to check before creating the container.
        [SecChainSharedConfig.cloudKitContainerIdentifier]
        #endif
    }

    /// `com.apple.developer.icloud-container-environment`, which a Developer ID profile only ever
    /// sets to `Production`. `nil` for a development build, where the environment is chosen by the
    /// profile Xcode manages.
    public static func containerEnvironment() -> String? {
        #if os(macOS)
        SecTaskCreateFromSelf(nil).flatMap {
            SecTaskCopyValueForEntitlement($0, "com.apple.developer.icloud-container-environment" as CFString, nil)
        } as? String
        #else
        nil
        #endif
    }

    /// Whether this binary may use SecChain's container.
    public static var isSignedForSecChainContainer: Bool {
        containerIdentifiers().contains(SecChainSharedConfig.cloudKitContainerIdentifier)
    }
}

/// The remote approval transport as it really is: the private database of SecChain's CloudKit
/// container (documents/PROJECT.md, design decision 5 — the command-line tool talks to CloudKit
/// itself, so that `secchain run` works over SSH and on a Mac where the app was never opened).
///
/// Errors from CloudKit are passed on as they are: their code and the server's explanation name
/// the missing entitlement, the undeployed schema, or the account problem, and rewriting them would
/// hide what has to be fixed.
public struct CloudKitRemoteApprovalStore: RemoteApprovalStore {
    /// Database the records live in. Injected so that a caller can use another container while
    /// developing, and so that this type stays free of the container's identifier.
    let database: CKDatabase

    public init(database: CKDatabase) {
        self.database = database
    }

    /// The transport the shipping front ends use. Throws instead of creating the container when
    /// this binary is not signed for it, because creating it would stop the process.
    public static func system() throws -> CloudKitRemoteApprovalStore {
        guard CloudKitEntitlements.isSignedForSecChainContainer else {
            throw SecretStoreError.missingEntitlement
        }
        return CloudKitRemoteApprovalStore(
            database: CKContainer(identifier: SecChainSharedConfig.cloudKitContainerIdentifier).privateCloudDatabase
        )
    }

    // MARK: - RemoteApprovalStore

    public func save(request: RemoteApprovalRequest) async throws {
        _ = try await database.save(RemoteApprovalCloudKitRecords.record(request: request))
    }

    public func decision(requestIdentifier: UUID) async throws -> RemoteApprovalDecision? {
        try await fetched(recordName: RemoteApprovalRecordName.decision(requestIdentifier: requestIdentifier))
            .map(RemoteApprovalCloudKitRecords.decision(record:))
    }

    public func save(cancellation: RemoteApprovalCancellation) async throws {
        _ = try await database.save(RemoteApprovalCloudKitRecords.record(cancellation: cancellation))
    }

    public func pairings() async throws -> [RemoteApprovalPairing] {
        try await matching(recordType: RemoteApprovalRecordType.pairing).map(RemoteApprovalCloudKitRecords.pairing(record:))
    }

    public func delete(requestIdentifier: UUID) async throws {
        for recordName in [
            RemoteApprovalRecordName.request(requestIdentifier: requestIdentifier),
            RemoteApprovalRecordName.decision(requestIdentifier: requestIdentifier),
            RemoteApprovalRecordName.cancellation(requestIdentifier: requestIdentifier),
        ] {
            try await deleted(recordName: recordName)
        }
    }

    public func requests() async throws -> [RemoteApprovalRequest] {
        try await matching(recordType: RemoteApprovalRecordType.request).map(RemoteApprovalCloudKitRecords.request(record:))
    }

    public func request(requestIdentifier: UUID) async throws -> RemoteApprovalRequest? {
        try await fetched(recordName: RemoteApprovalRecordName.request(requestIdentifier: requestIdentifier))
            .map(RemoteApprovalCloudKitRecords.request(record:))
    }

    public func save(decision: RemoteApprovalDecision) async throws {
        _ = try await database.save(RemoteApprovalCloudKitRecords.record(decision: decision))
    }

    public func cancellation(requestIdentifier: UUID) async throws -> RemoteApprovalCancellation? {
        try await fetched(recordName: RemoteApprovalRecordName.cancellation(requestIdentifier: requestIdentifier))
            .map(RemoteApprovalCloudKitRecords.cancellation(record:))
    }

    public func save(pairing: RemoteApprovalPairing) async throws {
        _ = try await database.save(RemoteApprovalCloudKitRecords.record(pairing: pairing))
    }

    public func delete(pairing: RemoteApprovalPairing) async throws {
        try await deleted(recordName: RemoteApprovalRecordName.pairing(publicKeyRepresentation: pairing.publicKeyRepresentation))
    }

    // MARK: - Database

    /// One record by name. A record that is not there yet is the answer "not yet", not a failure,
    /// which is what the polling loop asks about every 2 seconds.
    func fetched(recordName: String) async throws -> CKRecord? {
        do {
            return try await database.record(for: CKRecord.ID(recordName: recordName))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Deletes one record by name. Deleting what is not there succeeds, so that a caller can clean
    /// up without knowing what it left behind (idempotent).
    func deleted(recordName: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }

    /// Every record of one type, following the cursor to the end. The query filters on
    /// `schemaVersion` rather than on the record name, which CloudKit does not index on its own
    /// (documents/remote-approval-records.md).
    func matching(recordType: String) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var response = try await database.records(
            matching: CKQuery(recordType: recordType, predicate: RemoteApprovalCloudKitRecords.everyRecordPredicate())
        )
        while true {
            records += try response.matchResults.map { try $0.1.get() }
            guard let cursor = response.queryCursor else {
                return records
            }
            response = try await database.records(continuingMatchFrom: cursor)
        }
    }
}
