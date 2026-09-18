import CryptoKit
import Foundation
import Testing

@testable import SecChainCore

@Suite
struct RemoteApprovalInboxTests {
    let store = InMemoryRemoteApprovalStore()
    let key = SoftwareRemoteApprovalKey()
    let startOfWaiting = Date(timeIntervalSince1970: 1_800_000_000)

    func makeInbox(clock: ManualClock) -> RemoteApprovalInbox {
        RemoteApprovalInbox(store: store, now: { clock.now })
    }

    /// Files a request the way a Mac does, so that the inbox reads what `RemoteApprovalSession`
    /// wrote rather than a value built for the test.
    func fileRequest(clock: ManualClock, secretName: String = "API_TOKEN", commandArguments: [String] = ["npm", "run", "deploy"]) async throws -> RemoteApprovalRequest {
        let request = RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/example/repository"),
            secretNames: [SecretName(rawName: secretName)].compactMap { $0 },
            commandArguments: commandArguments,
            requestingDeviceName: "Example Mac",
            now: clock.now,
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
        try await store.save(request: request)
        return request
    }

    @Test
    func theApprovalIsAcceptedByTheMacThatEnrolledTheKey() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let request = try await fileRequest(clock: clock)
        try await makeInbox(clock: clock).approve(request: request, key: key)

        let decision = try #require(try await store.decision(requestIdentifier: request.requestIdentifier))
        #expect(decision.outcome == .approved)
        try RemoteApproval.verify(
            signature: decision.signature,
            request: request,
            publicKey: try key.pairing(deviceName: "Example iPhone").publicKey(),
            now: clock.now
        )
    }

    /// The whole round with both sides against one store: the Mac files a request and waits, the
    /// iPhone approves it while the Mac is between two fetches, and the Mac returns without
    /// throwing.
    @Test
    func theMacStopsWaitingWhenTheInboxApproves() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let inbox = makeInbox(clock: clock)
        let request = try await fileRequest(clock: clock)
        let store = store
        try await RemoteApprovalSession(
            store: store,
            enrolledPublicKey: try key.pairing(deviceName: "Example iPhone").publicKey(),
            now: { clock.now },
            sleep: { duration in
                clock.advance(seconds: Double(duration.components.seconds))
                if store.fetchesOfTheDecision == 1 {
                    try await inbox.approve(request: request, key: key)
                }
            },
            report: { _ in }
        ).waitForApproval(request: request)
        #expect(store.fetchesOfTheDecision == 2)
    }

    @Test
    func aRejectionCarriesNoSignature() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let request = try await fileRequest(clock: clock)
        try await makeInbox(clock: clock).reject(request: request)

        let decision = try #require(try await store.decision(requestIdentifier: request.requestIdentifier))
        #expect(decision.outcome == .rejected)
        #expect(decision.signature == nil)
    }

    @Test
    func anExpiredRequestIsNeitherOfferedNorAnswered() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let inbox = makeInbox(clock: clock)
        let request = try await fileRequest(clock: clock)
        clock.advance(seconds: RemoteApprovalSession.expiryInterval)

        #expect(try await inbox.unanswerableReason(request: request) == .expired)
        await #expect(throws: RemoteApprovalInboxError.expired) {
            try await inbox.approve(request: request, key: key)
        }
        await #expect(throws: RemoteApprovalInboxError.expired) {
            try await inbox.reject(request: request)
        }
        #expect(try await store.decision(requestIdentifier: request.requestIdentifier) == nil)

        // Nothing expires by itself in CloudKit, and a Mac killed while it waited wrote neither an
        // answer nor a cancellation, so the iPhone is the device that removes the request
        // (documents/remote-approval-records.md, "Who deletes a record").
        #expect(try await inbox.openRequests().isEmpty)
        #expect(try await store.request(requestIdentifier: request.requestIdentifier) == nil)
    }

    @Test
    func aCancelledRequestIsNeitherOfferedNorAnswered() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let inbox = makeInbox(clock: clock)
        let request = try await fileRequest(clock: clock)
        // What the Mac writes when the user presses Ctrl-C: the request stays, the cancellation
        // refers to it.
        try await store.save(cancellation: RemoteApprovalCancellation(requestIdentifier: request.requestIdentifier))

        #expect(try await inbox.unanswerableReason(request: request) == .cancelled)
        await #expect(throws: RemoteApprovalInboxError.cancelled) {
            try await inbox.approve(request: request, key: key)
        }
        await #expect(throws: RemoteApprovalInboxError.cancelled) {
            try await inbox.reject(request: request)
        }
        #expect(try await store.decision(requestIdentifier: request.requestIdentifier) == nil)

        // Acting on the cancellation means removing the three records: the Mac leaves the request
        // in place, because its cancellation refers to it
        // (documents/remote-approval-records.md, "Who deletes a record").
        #expect(try await inbox.openRequests().isEmpty)
        #expect(try await store.request(requestIdentifier: request.requestIdentifier) == nil)
        #expect(try await store.cancellation(requestIdentifier: request.requestIdentifier) == nil)
    }

    @Test
    func theRequestThatExpiresFirstIsOfferedFirst() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let inbox = makeInbox(clock: clock)
        let earlierRequest = try await fileRequest(clock: clock, secretName: "FIRST")
        clock.advance(seconds: 1)
        let laterRequest = try await fileRequest(clock: clock, secretName: "SECOND")

        #expect(try await inbox.openRequests().map(\.requestIdentifier) == [earlierRequest.requestIdentifier, laterRequest.requestIdentifier])
        #expect(try await inbox.unanswerableReason(request: earlierRequest) == nil)
    }

    @Test
    func nothingTheInboxWritesCarriesMoreThanTheRequestIdentifierAndTheSignature() async throws {
        let clock = ManualClock(instant: startOfWaiting)
        let request = try await fileRequest(clock: clock, secretName: "API_TOKEN", commandArguments: ["npm", "run", "deploy"])
        try await makeInbox(clock: clock).approve(request: request, key: key)

        // The answer names the request and proves who answered it; the value of API_TOKEN is not in
        // the request either, and nothing of what was shown is copied into the answer
        // (.claude/rules/secret-handling.md).
        let decision = try #require(try await store.decision(requestIdentifier: request.requestIdentifier))
        #expect(RemoteApprovalCloudKitRecords.record(decision: decision).allKeys().sorted() == [
            RemoteApprovalRecordField.outcome,
            RemoteApprovalRecordField.requestIdentifier,
            RemoteApprovalRecordField.schemaVersion,
            RemoteApprovalRecordField.signature,
        ].sorted())
    }
}
