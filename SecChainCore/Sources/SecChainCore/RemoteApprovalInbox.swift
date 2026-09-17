import Foundation

/// Why a request the approving device holds can no longer be answered. Both cases mean that no Mac
/// is waiting any more, so writing an answer would leave a record nobody reads.
public enum RemoteApprovalInboxError: Error, Equatable, CustomStringConvertible {
    /// The moment the Mac stops accepting an approval has passed.
    case expired
    /// The Mac stopped waiting before the expiry (the user pressed Ctrl-C).
    case cancelled

    public var description: String {
        switch self {
        case .expired:
            "The request expired."
        case .cancelled:
            "The Mac stopped waiting for this request."
        }
    }
}

/// The requests waiting on the paired device and what answering one writes: the counterpart of
/// `RemoteApprovalSession`, which files a request on the Mac and waits for exactly these records.
///
/// The clock and the transport are injected so that the whole policy — which requests may still be
/// answered, and that an approval is never written for one that may not — is unit-tested in
/// milliseconds against `InMemoryRemoteApprovalStore`.
public struct RemoteApprovalInbox: Sendable {
    /// Transport the requests and the answers travel through.
    let store: any RemoteApprovalStore
    /// Reads the current moment. Injected so that the expiry is exercised without waiting for it.
    let now: @Sendable () -> Date

    public init(store: any RemoteApprovalStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    /// The requests a Mac is still waiting for, the one that expires first at the front, because
    /// that is the one the user has the least time to answer.
    public func openRequests() async throws -> [RemoteApprovalRequest] {
        var openRequests: [RemoteApprovalRequest] = []
        for request in try await store.requests() {
            if try await unanswerableReason(request: request) == nil {
                openRequests.append(request)
            }
        }
        return openRequests.sorted { $0.expiry < $1.expiry }
    }

    /// Why `request` can no longer be answered, `nil` while the Mac is still waiting. The screen
    /// shows the reason instead of dropping the request, so that the user learns what happened to
    /// the approval they were about to give.
    public func unanswerableReason(request: RemoteApprovalRequest) async throws -> RemoteApprovalInboxError? {
        guard now() < request.expiry else {
            return .expired
        }
        return try await store.cancellation(requestIdentifier: request.requestIdentifier) == nil ? nil : .cancelled
    }

    /// Signs `request` with `key` and writes the approval. Throws `RemoteApprovalInboxError` and
    /// writes nothing when no Mac is waiting any more.
    ///
    /// Not idempotent in what the user sees: writing the same approval twice leaves one record, but
    /// each call signs again, which is one Face ID prompt per call.
    public func approve(request: RemoteApprovalRequest, key: any RemoteApprovalKey) async throws {
        try await refuseUnanswerable(request: request)
        let signature = try key.approvalSignature(request: request)
        // Checked again after the signature: answering the Face ID prompt takes time, and an
        // approval that arrives after the expiry or the cancellation is one the Mac refuses anyway.
        try await refuseUnanswerable(request: request)
        try await store.save(
            decision: RemoteApprovalDecision(
                requestIdentifier: request.requestIdentifier,
                outcome: .approved,
                signature: signature
            )
        )
    }

    /// Writes the rejection, which carries no signature: a process that could forge one could also
    /// kill the command, so refusing to read is not a privilege it gains
    /// (documents/remote-approval-records.md).
    public func reject(request: RemoteApprovalRequest) async throws {
        try await refuseUnanswerable(request: request)
        try await store.save(
            decision: RemoteApprovalDecision(
                requestIdentifier: request.requestIdentifier,
                outcome: .rejected,
                signature: nil
            )
        )
    }

    private func refuseUnanswerable(request: RemoteApprovalRequest) async throws {
        if let reason = try await unanswerableReason(request: request) {
            throw reason
        }
    }
}
