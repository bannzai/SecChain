import Foundation

/// The transport of the remote approval protocol, as the two front ends use it. CloudKit is behind
/// this protocol so that the policy that decides what a Mac accepts (`RemoteApprovalSession`) is
/// unit-tested against `InMemoryRemoteApprovalStore`, without an iCloud account and without a
/// signed build (documents/PROJECT.md, "Tests").
///
/// Everything a store returns was read from the user's private database, which any process running
/// as the user can write to. A caller therefore treats a fetched record as a claim, not as a fact:
/// the Mac verifies an approval against its own copy of the request and the key it enrolled.
public protocol RemoteApprovalStore: Sendable {
    // MARK: - The Mac that asks

    /// Files the request. Writing the same request twice leaves the same single record (idempotent).
    func save(request: RemoteApprovalRequest) async throws

    /// The answer to one request, `nil` while none has been written yet.
    func decision(requestIdentifier: UUID) async throws -> RemoteApprovalDecision?

    /// Records that the Mac stopped waiting. Writing it twice leaves one record (idempotent).
    func save(cancellation: RemoteApprovalCancellation) async throws

    /// Every public key published for pairing. More than one means more than one device published
    /// a key, which the Mac shows the user instead of choosing for them.
    func pairings() async throws -> [RemoteApprovalPairing]

    /// Removes the request, its answer, and its cancellation. Removing what is not there succeeds
    /// (idempotent), so a run can clean up after itself whatever happened.
    func delete(requestIdentifier: UUID) async throws

    // MARK: - The iPhone that answers

    /// Requests waiting for an answer, for the launch and notification paths of the iOS app
    /// (design decision 5: a notification can be coalesced or dropped).
    func requests() async throws -> [RemoteApprovalRequest]

    /// One request by identifier, for the path where a notification names it.
    func request(requestIdentifier: UUID) async throws -> RemoteApprovalRequest?

    /// Writes the answer. Writing it twice leaves one record (idempotent).
    func save(decision: RemoteApprovalDecision) async throws

    /// The Mac's cancellation of a request, `nil` while the Mac is still waiting.
    func cancellation(requestIdentifier: UUID) async throws -> RemoteApprovalCancellation?

    /// Publishes the public key of this device's approval key. Publishing the same key twice
    /// leaves one record (idempotent).
    func save(pairing: RemoteApprovalPairing) async throws

    /// Withdraws a published key, for a device that created a new one.
    func delete(pairing: RemoteApprovalPairing) async throws
}
