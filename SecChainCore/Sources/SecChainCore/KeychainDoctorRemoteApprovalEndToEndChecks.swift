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
    public static func runRemoteApprovalEndToEndChecks() async -> [KeychainDoctorCheck] {
        #if DEBUG
        await runRemoteApprovalRounds()
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
    static func runRemoteApprovalRounds() async -> [KeychainDoctorCheck] {
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
            ]
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
            secretNames: [SecretName(rawName: "DUMMY_NAME_FOR_DOCTOR")].compactMap { $0 },
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
