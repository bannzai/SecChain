import CloudKit
import CryptoKit
import Foundation
import Security

extension KeychainDoctor {
    /// A whole remote approval round against the real CloudKit container, with a software key
    /// playing the paired iPhone: the Mac files a request, the "iPhone" reads it back out of the
    /// private database and signs it, and the Mac verifies the answer.
    ///
    /// It exists because the iOS side is not built yet (issue #39) while the Mac side has to be
    /// verified against the real private database with a development signature (issue #38). Reading
    /// the request back before signing it is the point: it proves that what CloudKit returns still
    /// produces the same signed message, which is what the whole-second expiry is there for.
    ///
    /// **Debug builds only.** `make test-integration` builds the Debug configuration, while the
    /// notarized DMG comes from Release (`make dmg`), so the shipped tool contains no way to
    /// approve its own requests. The signing key is created in memory for one run and is never
    /// stored, published, or enrolled.
    /// `waitWithInterruptCancelling` is how the command-line tool wraps a wait so that Ctrl-C
    /// cancels it; it is passed in because the wrapper changes the process's signal disposition,
    /// which belongs to the tool rather than to a library the apps also link.
    public static func runRemoteApprovalEndToEndChecks(
        waitWithInterruptCancelling: @escaping (@escaping @Sendable () async throws -> Void) async throws -> Void
    ) async -> [KeychainDoctorCheck] {
        #if DEBUG
        await runRemoteApprovalRounds(waitWithInterruptCancelling: waitWithInterruptCancelling)
        #else
        [
            KeychainDoctorCheck(
                name: "remote approval: play both sides of one approval",
                status: errSecUnimplemented,
                passed: false,
                detail: "only a debug build can sign an approval for itself; this is a release build"
            ),
        ]
        #endif
    }

    #if DEBUG
    static func runRemoteApprovalRounds(
        waitWithInterruptCancelling: @escaping (@escaping @Sendable () async throws -> Void) async throws -> Void
    ) async -> [KeychainDoctorCheck] {
        let entitlementCheck = cloudKitContainerEntitlementCheck()
        guard entitlementCheck.passed else {
            return [entitlementCheck]
        }
        let store = CloudKitRemoteApprovalStore(
            database: CKContainer(identifier: SecChainSharedConfig.cloudKitContainerIdentifier).privateCloudDatabase
        )
        let theIPhonesKey = P256.Signing.PrivateKey()
        return [entitlementCheck]
            + [
                await roundCheck(
                    stepName: "remote approval: an approval signed by the enrolled key lets the read through",
                    store: store,
                    enrolledPublicKey: theIPhonesKey.publicKey,
                    signingKey: theIPhonesKey,
                    outcome: .approved,
                    expectedFailure: nil
                ),
                await roundCheck(
                    stepName: "remote approval: an approval signed by another key is refused",
                    store: store,
                    enrolledPublicKey: theIPhonesKey.publicKey,
                    // A process running as the user can write an answer, but not one this Mac's
                    // enrolled key would verify.
                    signingKey: P256.Signing.PrivateKey(),
                    outcome: .approved,
                    expectedFailure: .unverifiableApproval(.signatureMismatch)
                ),
                await roundCheck(
                    stepName: "remote approval: a rejection on the iPhone stops the read",
                    store: store,
                    enrolledPublicKey: theIPhonesKey.publicKey,
                    signingKey: theIPhonesKey,
                    outcome: .rejected,
                    expectedFailure: .rejected
                ),
                await interruptRoundCheck(
                    store: store,
                    enrolledPublicKey: theIPhonesKey.publicKey,
                    waitWithInterruptCancelling: waitWithInterruptCancelling
                ),
            ]
    }

    /// The Ctrl-C path in a real process: the wait is wrapped the way `secchain run` wraps it, and
    /// a SIGINT is sent to this process while it waits. It has to end in a cancellation record
    /// rather than in a dead process, which is the claim behind using a kqueue-based dispatch
    /// source: the thread Swift's concurrency runtime runs on blocks signals, so a plain handler
    /// would never see this one.
    static func interruptRoundCheck(
        store: CloudKitRemoteApprovalStore,
        enrolledPublicKey: P256.Signing.PublicKey,
        waitWithInterruptCancelling: (@escaping @Sendable () async throws -> Void) async throws -> Void
    ) async -> KeychainDoctorCheck {
        let stepName = "remote approval: Ctrl-C stops the waiting and leaves a cancellation behind"
        let request = RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/SecChain"),
            secretScopes: Dictionary(uniqueKeysWithValues: ["DUMMY_NAME_FOR_DOCTOR"].compactMap(SecretName.init(rawName:)).map { ($0, SecretScope.repository(RepositoryIdentity(value: "github.com/bannzai/SecChain"))) }),
            commandArguments: ["true"],
            requestingDeviceName: cloudKitDoctorDeviceName,
            now: Date(),
            // Nobody answers this request, so the interrupt is what has to end the wait. A short
            // expiry means a broken signal path fails in seconds instead of after the two minutes
            // a real request waits.
            expiryInterval: 10
        )
        let interruptWasSent = CallbackResult<Bool>()
        let session = RemoteApprovalSession(
            store: store,
            enrolledPublicKey: enrolledPublicKey,
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            report: { _ in
                // The first report happens inside the wait, which is where a Ctrl-C would land.
                guard interruptWasSent.value != true else {
                    return
                }
                interruptWasSent.value = true
                kill(getpid(), SIGINT)
            }
        )
        var failure: (any Error)?
        do {
            try await waitWithInterruptCancelling {
                try await session.waitForApproval(request: request)
            }
        } catch {
            failure = error
        }
        let cancellation = try? await store.cancellation(requestIdentifier: request.requestIdentifier)
        _ = try? await store.delete(requestIdentifier: request.requestIdentifier)
        let stoppedAsACancellation = failure as? RemoteApprovalError == .cancelled
        return KeychainDoctorCheck(
            name: stepName,
            status: errSecSuccess,
            passed: stoppedAsACancellation && cancellation?.requestIdentifier == request.requestIdentifier,
            detail: stoppedAsACancellation
                ? (cancellation == nil ? "the waiting stopped, but no cancellation record was written" : "the waiting stopped and the cancellation record is there")
                : "expected the waiting to stop as a cancellation, got \(failure.map { "\($0)" } ?? "an accepted approval")"
        )
    }

    /// One round: the Mac waits while the "iPhone" answers, and the outcome is compared with
    /// `expectedFailure` (`nil` meaning the approval has to be accepted).
    static func roundCheck(
        stepName: String,
        store: CloudKitRemoteApprovalStore,
        enrolledPublicKey: P256.Signing.PublicKey,
        signingKey: P256.Signing.PrivateKey,
        outcome: RemoteApprovalOutcome,
        expectedFailure: RemoteApprovalError?
    ) async -> KeychainDoctorCheck {
        let request = RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/SecChain"),
            secretScopes: Dictionary(uniqueKeysWithValues: ["DUMMY_NAME_FOR_DOCTOR"].compactMap(SecretName.init(rawName:)).map { ($0, SecretScope.repository(RepositoryIdentity(value: "github.com/bannzai/SecChain"))) }),
            commandArguments: ["true"],
            requestingDeviceName: cloudKitDoctorDeviceName,
            now: Date(),
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
        let theIPhone = Task {
            try await answerAsTheIPhone(store: store, request: request, signingKey: signingKey, outcome: outcome)
        }
        let start = Date()
        let session = RemoteApprovalSession(
            store: store,
            enrolledPublicKey: enrolledPublicKey,
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            // The waiting lines belong on a user's terminal, not in the doctor's output.
            report: { _ in }
        )
        var failure: (any Error)?
        do {
            try await session.waitForApproval(request: request)
        } catch {
            failure = error
        }
        let seconds = Int(Date().timeIntervalSince(start).rounded())
        if case .failure(let iPhoneError) = await theIPhone.result {
            _ = try? await store.delete(requestIdentifier: request.requestIdentifier)
            return KeychainDoctorCheck(
                name: stepName,
                status: errSecSuccess,
                passed: false,
                detail: "the stand-in for the iPhone could not answer: \(cloudKitErrorDetail(error: iPhoneError))"
            )
        }
        _ = try? await store.delete(requestIdentifier: request.requestIdentifier)
        guard let expectedFailure else {
            return KeychainDoctorCheck(
                name: stepName,
                status: errSecSuccess,
                passed: failure == nil,
                detail: failure.map { "refused with: \($0)" } ?? "verified after \(seconds)s"
            )
        }
        let refusedAsExpected = failure as? RemoteApprovalError == expectedFailure
        return KeychainDoctorCheck(
            name: stepName,
            status: errSecSuccess,
            passed: refusedAsExpected,
            detail: refusedAsExpected
                ? "refused after \(seconds)s: \(expectedFailure)"
                : "expected \(expectedFailure), got \(failure.map { "\($0)" } ?? "an accepted approval")"
        )
    }

    /// Plays the paired iPhone: waits until the Mac's request is in the private database, reads it
    /// back, and answers it. Signing the request **as CloudKit returned it** is what makes this an
    /// end-to-end check of the record layout and not just of the signature.
    static func answerAsTheIPhone(
        store: CloudKitRemoteApprovalStore,
        request: RemoteApprovalRequest,
        signingKey: P256.Signing.PrivateKey,
        outcome: RemoteApprovalOutcome
    ) async throws {
        while true {
            guard let filedRequest = try await store.request(requestIdentifier: request.requestIdentifier) else {
                // Short enough that the answer arrives inside one of the Mac's 2 second polls.
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            try await store.save(
                decision: RemoteApprovalDecision(
                    requestIdentifier: filedRequest.requestIdentifier,
                    outcome: outcome,
                    signature: outcome == .approved
                        ? try RemoteApproval.signature(request: filedRequest) { try signingKey.signature(for: $0) }
                        : nil
                )
            )
            return
        }
    }
    #endif
}
