import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

/// Clock a test advances by hand, so that the 2 second polling interval and the 2 minute expiry
/// are exercised without waiting for them.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(instant: Date) {
        self.instant = instant
    }

    var now: Date {
        lock.withLock {
            instant
        }
    }

    func advance(seconds: TimeInterval) {
        lock.withLock {
            instant += seconds
        }
    }
}

/// Collects what the session reports while it waits, which the command-line tool writes to
/// standard error.
final class ReportedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(line: String) {
        lock.withLock {
            lines.append(line)
        }
    }

    var all: [String] {
        lock.withLock {
            lines
        }
    }
}

@Suite
struct RemoteApprovalSessionTests {
    let pairedKey = P256.Signing.PrivateKey()
    let startOfWaiting = Date(timeIntervalSince1970: 1_800_000_000)

    func makeRequest(clock: ManualClock) -> RemoteApprovalRequest {
        RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
            secretNames: [SecretName(rawName: "API_TOKEN")].compactMap { $0 },
            commandArguments: ["npm", "run", "deploy"],
            requestingDeviceName: "Example Mac",
            now: clock.now,
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
    }

    /// A session whose waiting only moves the clock forward, so a test runs the whole expiry in
    /// microseconds.
    func makeSession(
        store: InMemoryRemoteApprovalStore,
        clock: ManualClock,
        publicKey: P256.Signing.PublicKey? = nil,
        report: ReportedLines = ReportedLines(),
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) -> RemoteApprovalSession {
        RemoteApprovalSession(
            store: store,
            enrolledPublicKey: publicKey ?? pairedKey.publicKey,
            now: { clock.now },
            sleep: sleep ?? { duration in
                clock.advance(seconds: Double(duration.components.seconds))
            },
            report: { report.append(line: $0) }
        )
    }

    func signature(request: RemoteApprovalRequest, key: P256.Signing.PrivateKey) throws -> Data {
        try RemoteApproval.signature(request: request) { try key.signature(for: $0) }
    }

    /// Plays the iPhone: writes an answer to the store.
    func answer(store: InMemoryRemoteApprovalStore, request: RemoteApprovalRequest, outcome: RemoteApprovalOutcome, signature: Data?) async throws {
        try await store.save(
            decision: RemoteApprovalDecision(requestIdentifier: request.requestIdentifier, outcome: outcome, signature: signature)
        )
    }

    @Test
    func anApprovalSignedByTheEnrolledKeyEndsTheWaiting() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        try await answer(store: store, request: request, outcome: .approved, signature: try signature(request: request, key: pairedKey))
        try await makeSession(store: store, clock: clock).waitForApproval(request: request)
        #expect(store.fetchesOfTheDecision == 1)
        // The answered request is removed, so that the iPhone stops offering it.
        #expect(try await store.request(requestIdentifier: request.requestIdentifier) == nil)
        #expect(try await store.decision(requestIdentifier: request.requestIdentifier) == nil)
    }

    /// The request has to be in the store before the waiting starts, because that is where the
    /// iPhone reads what it shows the user. An answer written while the Mac waits is picked up by
    /// a later fetch.
    @Test
    func theRequestIsFiledBeforeTheWaitingAndAnAnswerDuringItIsPickedUp() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        let signedApproval = try signature(request: request, key: pairedKey)
        let requestsSeenByTheIPhone = ReportedLines()
        store.setDecisionFetchObserver { fetchCount, store in
            Task {
                if let filed = try await store.request(requestIdentifier: request.requestIdentifier) {
                    requestsSeenByTheIPhone.append(line: filed.requestIdentifier.uuidString)
                }
                guard fetchCount == 3 else {
                    return
                }
                try await store.save(
                    decision: RemoteApprovalDecision(requestIdentifier: request.requestIdentifier, outcome: .approved, signature: signedApproval)
                )
            }
        }
        try await makeSession(store: store, clock: clock, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
            .waitForApproval(request: request)
        #expect(store.fetchesOfTheDecision >= 3)
        #expect(requestsSeenByTheIPhone.all.contains(request.requestIdentifier.uuidString))
    }

    @Test
    func aRejectionOnTheIPhoneIsItsOwnError() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        try await answer(store: store, request: request, outcome: .rejected, signature: nil)
        await #expect(throws: RemoteApprovalError.rejected) {
            try await makeSession(store: store, clock: clock).waitForApproval(request: request)
        }
    }

    /// A rejection is accepted without a signature: a process that could forge one could also kill
    /// the command, so refusing to read is not a privilege it gains.
    @Test
    func aRejectionDoesNotNeedASignature() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        try await answer(store: store, request: request, outcome: .rejected, signature: try signature(request: request, key: pairedKey))
        await #expect(throws: RemoteApprovalError.rejected) {
            try await makeSession(store: store, clock: clock).waitForApproval(request: request)
        }
    }

    @Test
    func noAnswerBeforeTheExpiryIsItsOwnError() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        await #expect(throws: RemoteApprovalError.expired) {
            try await makeSession(store: store, clock: clock).waitForApproval(request: request)
        }
        // 2 minutes at one fetch every 2 seconds, the cost design decision 5 accounts for.
        #expect(store.fetchesOfTheDecision == Int(RemoteApprovalSession.expiryInterval) / 2)
        #expect(try await store.request(requestIdentifier: request.requestIdentifier) == nil)
    }

    /// The expiry the Mac enforces is its own copy of it: an approval that arrives late is refused
    /// even though it carries a valid signature.
    @Test
    func anApprovalThatArrivesAfterTheExpiryIsRefused() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        let signedApproval = try signature(request: request, key: pairedKey)
        store.setDecisionFetchObserver { _, store in
            Task {
                try await store.save(
                    decision: RemoteApprovalDecision(requestIdentifier: request.requestIdentifier, outcome: .approved, signature: signedApproval)
                )
            }
        }
        clock.advance(seconds: RemoteApprovalSession.expiryInterval)
        await #expect(throws: RemoteApprovalError.expired) {
            try await makeSession(store: store, clock: clock).waitForApproval(request: request)
        }
    }

    @Test
    func cancellingTheWaitingSavesACancellationAndKeepsTheRequest() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        let session = makeSession(store: store, clock: clock, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        let waiting = Task {
            try await session.waitForApproval(request: request)
        }
        while store.fetchesOfTheDecision == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        waiting.cancel()
        await #expect(throws: RemoteApprovalError.cancelled) {
            try await waiting.value
        }
        #expect(try await store.cancellation(requestIdentifier: request.requestIdentifier) != nil)
        // The cancellation refers to the request, so the request stays until the iPhone is done
        // with it.
        #expect(try await store.request(requestIdentifier: request.requestIdentifier) != nil)
    }

    /// Every forgery a process running as the user could write. None of them ends the waiting with
    /// a return, which is what keeps `secchain run` from reading the secret.
    @Test
    func aForgedApprovalIsRefusedWithTheReasonItWasRefused() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let request = makeRequest(clock: clock)
        let anotherRequest = makeRequest(clock: clock)
        let forgeries: [(name: String, signature: Data?, expected: RemoteApprovalVerificationError)] = [
            ("no signature at all", nil, .missingSignature),
            ("an empty signature", Data(), .missingSignature),
            ("bytes that are not a signature", Data("approved".utf8), .malformedSignature),
            ("a signature by another key", try signature(request: request, key: P256.Signing.PrivateKey()), .signatureMismatch),
            ("an approval of another request", try signature(request: anotherRequest, key: pairedKey), .signatureMismatch),
        ]
        for forgery in forgeries {
            let store = InMemoryRemoteApprovalStore()
            try await answer(store: store, request: request, outcome: .approved, signature: forgery.signature)
            await #expect(throws: RemoteApprovalError.unverifiableApproval(forgery.expected), "\(forgery.name) was not refused") {
                try await makeSession(store: store, clock: ManualClock(instant: startOfWaiting)).waitForApproval(request: request)
            }
        }
    }

    /// The Mac verifies against the request it filed, not against the record it reads back: a
    /// process that rewrites the filed request cannot make the approval cover something else.
    @Test
    func rewritingTheFiledRequestDoesNotChangeWhatIsVerified() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        let rewrittenRequest = RemoteApprovalRequest(
            requestIdentifier: request.requestIdentifier,
            nonce: request.nonce,
            expiry: request.expiry,
            repositoryIdentity: request.repositoryIdentity,
            secretNames: request.secretNames,
            commandArguments: ["env"],
            requestingDeviceName: request.requestingDeviceName
        )
        // The iPhone is shown, and signs, the rewritten request.
        try await store.save(request: rewrittenRequest)
        try await answer(store: store, request: request, outcome: .approved, signature: try signature(request: rewrittenRequest, key: pairedKey))
        await #expect(throws: RemoteApprovalError.unverifiableApproval(.signatureMismatch)) {
            try await makeSession(store: store, clock: clock).waitForApproval(request: request)
        }
    }

    @Test
    func anApprovalForAnotherMacsEnrolledKeyIsRefused() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        try await answer(store: store, request: request, outcome: .approved, signature: try signature(request: request, key: pairedKey))
        await #expect(throws: RemoteApprovalError.unverifiableApproval(.signatureMismatch)) {
            try await makeSession(store: store, clock: clock, publicKey: P256.Signing.PrivateKey().publicKey)
                .waitForApproval(request: request)
        }
    }

    @Test
    func theWaitingIsReportedWithTheRemainingTimeAndNoSecretValue() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        let request = makeRequest(clock: clock)
        let report = ReportedLines()
        await #expect(throws: RemoteApprovalError.expired) {
            try await makeSession(store: store, clock: clock, report: report).waitForApproval(request: request)
        }
        #expect(report.all.first?.contains("\(Int(RemoteApprovalSession.expiryInterval))s left") == true)
        #expect(report.all.last?.contains("2s left") == true)
        for line in report.all {
            #expect(line.contains("waiting for approval"))
            #expect(!line.contains("dummy-value-for-test"))
        }
    }

    /// A transport that fails must not look like an expiry or like a rejection: the user has to be
    /// able to tell "iCloud did not answer" from "you rejected it".
    @Test
    func aTransportFailureIsReportedAsItself() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let store = InMemoryRemoteApprovalStore()
        store.setFailure(failure: RemoteApprovalStoreFailure(message: "the private database did not answer"))
        await #expect(throws: RemoteApprovalStoreFailure(message: "the private database did not answer")) {
            try await makeSession(store: store, clock: clock).waitForApproval(request: makeRequest(clock: clock))
        }
    }

    @Test
    func everySessionErrorExplainsItself() {
        let errors: [RemoteApprovalError] = [.rejected, .expired, .cancelled, .unverifiableApproval(.signatureMismatch)]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
        #expect(Set(errors.map(\.description)).count == errors.count)
        #expect(RemoteApprovalError.unverifiableApproval(.signatureMismatch).description.contains(RemoteApprovalVerificationError.signatureMismatch.description))
    }
}
