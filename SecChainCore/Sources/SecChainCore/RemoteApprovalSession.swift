import CryptoKit
import Foundation

/// Why a remote approval did not authorize the read. The cases are separate because the user acts
/// differently on each of them, and because a forged approval must never look like an approved one
/// (documents/PROJECT.md, design decision 5).
public enum RemoteApprovalError: Error, Equatable, CustomStringConvertible {
    /// The user rejected the request on the iPhone.
    case rejected
    /// No answer arrived before the request expired.
    case expired
    /// The Mac stopped waiting (Ctrl-C).
    case cancelled
    /// An answer claiming to be an approval was not signed by the enrolled key for this request.
    case unverifiableApproval(RemoteApprovalVerificationError)

    public var description: String {
        switch self {
        case .rejected:
            "The request was rejected on your iPhone."
        case .expired:
            "No answer arrived from your iPhone before the request expired."
        case .cancelled:
            "Waiting for the approval was cancelled."
        case .unverifiableApproval(let verificationError):
            "The approval was refused: \(verificationError)"
        }
    }
}

/// One round of remote approval: file the request, wait for the paired iPhone's answer, and accept
/// it only when it is a signature by the enrolled key over this request.
///
/// The clock, the waiting, and the transport are injected so that the whole policy — the polling
/// interval, the expiry, the distinction between rejected, expired, cancelled, and forged — is
/// unit-tested in milliseconds against `InMemoryRemoteApprovalStore`.
public struct RemoteApprovalSession: Sendable {
    /// Time between two fetches of the answer. A command-line process cannot receive pushes, so it
    /// polls; one CloudKit call from the tool was measured at about 0.3 seconds
    /// (documents/PROJECT.md, "Remote approval spike"), which puts about 60 fetches in one request.
    public static let pollInterval = Duration.seconds(2)
    /// How long a request stays open (design decision 5): long enough to pick up the iPhone, short
    /// enough that a `secchain run` nobody answers does not hang.
    public static let expiryInterval: TimeInterval = 120

    /// Transport the request and the answer travel through.
    let store: any RemoteApprovalStore
    /// Public key enrolled on this Mac during pairing. An answer that is not signed by it is not an
    /// approval, whatever the record says.
    let enrolledPublicKey: P256.Signing.PublicKey
    /// Reads the current moment. Injected so that the expiry is exercised without waiting for it.
    let now: @Sendable () -> Date
    /// Waits between two fetches. Injected for the same reason, and because cancelling this call is
    /// what Ctrl-C does.
    let sleep: @Sendable (Duration) async throws -> Void
    /// Receives one line per fetch about what is being waited for. The command-line tool writes
    /// them to standard error, because standard output belongs to the command being run.
    let report: @Sendable (String) -> Void

    public init(
        store: any RemoteApprovalStore,
        enrolledPublicKey: P256.Signing.PublicKey,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        report: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.enrolledPublicKey = enrolledPublicKey
        self.now = now
        self.sleep = sleep
        self.report = report
    }

    /// Files `request` and returns once the iPhone's approval has been verified. Throws
    /// `RemoteApprovalError` for every other outcome, so that no caller can mistake a refusal for
    /// an approval.
    ///
    /// Not idempotent: each call files a request with its own identifier and nonce, which is what
    /// makes one approval unusable for another run.
    public func waitForApproval(request: RemoteApprovalRequest) async throws {
        do {
            try await forgetExpiredRequests(requestingDeviceName: request.requestingDeviceName)
        } catch {
            // Housekeeping must not stop an authentication the user is waiting for, but it is said
            // out loud rather than swallowed.
            report("could not remove this Mac's expired requests: \(error)")
        }
        try await store.save(request: request)
        do {
            try await waitForVerifiedApproval(request: request)
        } catch RemoteApprovalError.cancelled {
            // The cancellation record is what tells the iPhone to stop offering the request, so the
            // request itself stays: deleting it would take away what the record refers to.
            throw RemoteApprovalError.cancelled
        } catch {
            try await forgetRequest(request: request)
            throw error
        }
        try await forgetRequest(request: request)
    }

    /// The polling loop. Every answer is verified against the caller's own `request` and the
    /// enrolled key, never against fields read back from the store.
    func waitForVerifiedApproval(request: RemoteApprovalRequest) async throws {
        while true {
            let remainingSeconds = Int(request.expiry.timeIntervalSince(now()).rounded(.up))
            guard remainingSeconds > 0 else {
                throw RemoteApprovalError.expired
            }
            report("waiting for approval on \(request.requestingDeviceName)'s paired iPhone, \(remainingSeconds)s left")
            do {
                if let decision = try await store.decision(requestIdentifier: request.requestIdentifier) {
                    try verified(decision: decision, request: request)
                    return
                }
                try await sleep(Self.pollInterval)
            } catch {
                // Once the task is cancelled, whatever the transport threw is a consequence of the
                // cancellation, not a reason of its own: CloudKit reports a cancelled operation as
                // a `CKError` rather than as a `CancellationError`.
                guard error is CancellationError || Task.isCancelled else {
                    throw error
                }
                try await cancel(request: request)
                throw RemoteApprovalError.cancelled
            }
        }
    }

    /// Accepts the answer, or throws the reason it is not an approval.
    func verified(decision: RemoteApprovalDecision, request: RemoteApprovalRequest) throws {
        guard decision.outcome == .approved else {
            throw RemoteApprovalError.rejected
        }
        do {
            try RemoteApproval.verify(
                signature: decision.signature,
                request: request,
                publicKey: enrolledPublicKey,
                now: now()
            )
        } catch {
            // An approval that arrives after the expiry is the same fact as no approval arriving,
            // so the user sees one error for it instead of two.
            throw error == .expired ? RemoteApprovalError.expired : RemoteApprovalError.unverifiableApproval(error)
        }
    }

    /// Removes the requests this Mac filed that nobody may act on any more, so that records do not
    /// pile up after a Mac was killed while waiting and the iOS app is not opened for a while
    /// (documents/remote-approval-records.md, "Who deletes a record").
    ///
    /// A request is only removed once its expiry has passed, which is the moment after which no
    /// device may act on it. Two Macs that happen to share a name therefore cannot remove each
    /// other's open requests.
    func forgetExpiredRequests(requestingDeviceName: String) async throws {
        for request in try await store.requests()
        where request.requestingDeviceName == requestingDeviceName && request.expiry <= now() {
            try await store.delete(requestIdentifier: request.requestIdentifier)
        }
    }

    /// Records that this Mac is no longer waiting.
    func cancel(request: RemoteApprovalRequest) async throws {
        try await uncancellable {
            try await $0.save(cancellation: RemoteApprovalCancellation(requestIdentifier: request.requestIdentifier))
        }
    }

    /// Removes the request and its answer once the outcome is known, so that the iPhone stops
    /// offering it and the private database does not fill up with answered requests.
    func forgetRequest(request: RemoteApprovalRequest) async throws {
        try await uncancellable {
            try await $0.delete(requestIdentifier: request.requestIdentifier)
        }
    }

    /// Runs a store call in a task of its own. The clean-up and the cancellation record are written
    /// while the calling task is already cancelled or failing, and a store that honors cancellation
    /// would otherwise skip them.
    func uncancellable(operation: @escaping @Sendable (any RemoteApprovalStore) async throws -> Void) async throws {
        let store = store
        try await Task.detached {
            try await operation(store)
        }.value
    }
}
