import Foundation

/// Transport failure a caller asks the double to raise, so that the handling of a CloudKit outage
/// can be rehearsed without CloudKit.
public struct RemoteApprovalStoreFailure: Error, Equatable, CustomStringConvertible {
    /// What the store pretends went wrong.
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

/// Remote approval transport that keeps records in memory and behaves like the private database in
/// the ways that matter to callers: a record is addressed by identifier, writing the same record
/// twice leaves one, and both devices see everything the other wrote.
///
/// It is part of the library (not the test target) because the apps' previews and the command-line
/// tool's own checks need it too, the same reason `InMemorySecretKeychain` lives here. A class with
/// a lock, because a shared database is mutable state with identity.
public final class InMemoryRemoteApprovalStore: RemoteApprovalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var requestsByIdentifier: [UUID: RemoteApprovalRequest] = [:]
    private var decisionsByIdentifier: [UUID: RemoteApprovalDecision] = [:]
    private var cancellationsByIdentifier: [UUID: RemoteApprovalCancellation] = [:]
    private var pairingsByRecordName: [String: RemoteApprovalPairing] = [:]
    private var failure: RemoteApprovalStoreFailure?
    private var decisionFetchCount = 0
    private var decisionFetchObserver: (@Sendable (Int, InMemoryRemoteApprovalStore) -> Void)?

    public init() {}

    // MARK: - Rehearsing

    /// When set, every call throws it.
    public func setFailure(failure: RemoteApprovalStoreFailure?) {
        lock.withLock {
            self.failure = failure
        }
    }

    /// Called before every fetch of an answer, with the number of the fetch and the store itself,
    /// so that a caller can play the iPhone and answer at a chosen moment.
    public func setDecisionFetchObserver(observer: (@Sendable (Int, InMemoryRemoteApprovalStore) -> Void)?) {
        lock.withLock {
            self.decisionFetchObserver = observer
        }
    }

    /// How many times an answer was fetched, which is how a caller sees that waiting happened.
    public var fetchesOfTheDecision: Int {
        lock.withLock {
            decisionFetchCount
        }
    }

    // MARK: - RemoteApprovalStore

    public func save(request: RemoteApprovalRequest) async throws {
        try lock.withLock {
            try throwFailureIfSet()
            requestsByIdentifier[request.requestIdentifier] = request
        }
    }

    public func decision(requestIdentifier: UUID) async throws -> RemoteApprovalDecision? {
        let observer = try lock.withLock {
            try throwFailureIfSet()
            decisionFetchCount += 1
            return (observer: decisionFetchObserver, count: decisionFetchCount)
        }
        observer.observer?(observer.count, self)
        return try lock.withLock {
            try throwFailureIfSet()
            return decisionsByIdentifier[requestIdentifier]
        }
    }

    public func save(cancellation: RemoteApprovalCancellation) async throws {
        try lock.withLock {
            try throwFailureIfSet()
            cancellationsByIdentifier[cancellation.requestIdentifier] = cancellation
        }
    }

    public func pairings() async throws -> [RemoteApprovalPairing] {
        try lock.withLock {
            try throwFailureIfSet()
            return pairingsByRecordName.keys.sorted().compactMap { pairingsByRecordName[$0] }
        }
    }

    public func delete(requestIdentifier: UUID) async throws {
        try lock.withLock {
            try throwFailureIfSet()
            requestsByIdentifier[requestIdentifier] = nil
            decisionsByIdentifier[requestIdentifier] = nil
            cancellationsByIdentifier[requestIdentifier] = nil
        }
    }

    public func requests() async throws -> [RemoteApprovalRequest] {
        try lock.withLock {
            try throwFailureIfSet()
            return requestsByIdentifier.values.sorted { $0.expiry < $1.expiry }
        }
    }

    public func request(requestIdentifier: UUID) async throws -> RemoteApprovalRequest? {
        try lock.withLock {
            try throwFailureIfSet()
            return requestsByIdentifier[requestIdentifier]
        }
    }

    public func save(decision: RemoteApprovalDecision) async throws {
        try lock.withLock {
            try throwFailureIfSet()
            decisionsByIdentifier[decision.requestIdentifier] = decision
        }
    }

    public func cancellation(requestIdentifier: UUID) async throws -> RemoteApprovalCancellation? {
        try lock.withLock {
            try throwFailureIfSet()
            return cancellationsByIdentifier[requestIdentifier]
        }
    }

    public func save(pairing: RemoteApprovalPairing) async throws {
        try lock.withLock {
            try throwFailureIfSet()
            pairingsByRecordName[RemoteApprovalRecordName.pairing(publicKeyRepresentation: pairing.publicKeyRepresentation)] = pairing
        }
    }

    public func delete(pairing: RemoteApprovalPairing) async throws {
        try lock.withLock {
            try throwFailureIfSet()
            pairingsByRecordName[RemoteApprovalRecordName.pairing(publicKeyRepresentation: pairing.publicKeyRepresentation)] = nil
        }
    }

    private func throwFailureIfSet() throws {
        if let failure {
            throw failure
        }
    }
}
