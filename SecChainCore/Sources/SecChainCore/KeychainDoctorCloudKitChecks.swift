import CloudKit
import CryptoKit
import Foundation
import Security

extension KeychainDoctor {
    /// Fixed identifier for the doctor's request, so that a run removes whatever an interrupted run
    /// left behind instead of leaving records nobody addresses any more.
    static let cloudKitDoctorRequestIdentifier = UUID(uuidString: "00000000-0000-4000-8000-00000000d0c7")!
    /// Private key of the doctor's pairing record, derived from fixed bytes for the same reason: the
    /// record name follows from the public key, so a fixed key gives a fixed record to clean up. It
    /// is a software key in the source of an open-source project and protects nothing.
    static let cloudKitDoctorKeyBytes = Data(repeating: 7, count: 32)
    /// Name of the device in the doctor's records, so that nobody mistakes them for a real request.
    static let cloudKitDoctorDeviceName = "dummy-device-for-doctor"
    /// Dummy notification text. A remote approval notification names the requesting Mac instead.
    static let cloudKitProbeAlertBody = "dummy-alert-for-doctor"
    /// Subscription the iOS app installs on the request type; the doctor saves and removes its own
    /// under this name.
    static let cloudKitProbeName = "secchain-doctor-probe"

    /// Checks whether this binary can use SecChain's CloudKit container the way remote approval
    /// needs (issue #32): the private database stores, returns, queries, and deletes every record
    /// type of the protocol, and accepts a query subscription whose notification is visible.
    ///
    /// It exercises the protocol's record types rather than a type of its own: a deployed CloudKit
    /// record type cannot be deleted, so the production schema must not carry a type that only the
    /// doctor uses (documents/PROJECT.md, design decision 5). Running it against the development
    /// environment is also what creates those record types there, which is what the production
    /// schema is deployed from (issue #16).
    ///
    /// Only dummy values are stored, and never a secret value.
    public static func runCloudKitChecks() async -> [KeychainDoctorCheck] {
        let entitlementCheck = cloudKitContainerEntitlementCheck()
        guard entitlementCheck.passed else {
            return [entitlementCheck]
        }
        var checks = [entitlementCheck]

        /// Runs one step and records whether it held, what was observed, or the error it threw.
        func check(stepName: String, observation: () async throws -> (held: Bool, detail: String)) async -> Bool {
            do {
                let result = try await observation()
                checks.append(KeychainDoctorCheck(name: stepName, status: errSecSuccess, passed: result.held, detail: result.detail))
                return result.held
            } catch {
                checks.append(KeychainDoctorCheck(name: stepName, status: errSecSuccess, passed: false, detail: cloudKitErrorDetail(error: error)))
                return false
            }
        }

        let container = CKContainer(identifier: SecChainSharedConfig.cloudKitContainerIdentifier)
        let database = container.privateCloudDatabase
        let store = CloudKitRemoteApprovalStore(database: database)

        let accountIsAvailable = await check(stepName: "CloudKit: the iCloud account is available") {
            let accountStatus = try await container.accountStatus()
            return (accountStatus == .available, "accountStatus = \(accountStatus.rawValue) (available = \(CKAccountStatus.available.rawValue))")
        }
        guard accountIsAvailable else {
            return checks
        }
        _ = await check(stepName: "CloudKit: the container returns the user record identifier") {
            _ = try await container.userRecordID()
            return (true, "")
        }

        let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: cloudKitDoctorKeyBytes)
        guard let privateKey else {
            checks.append(
                KeychainDoctorCheck(
                    name: "CloudKit: the doctor's dummy key can be created",
                    status: errSecParam,
                    passed: false,
                    detail: "P256.Signing.PrivateKey(rawRepresentation:) failed"
                )
            )
            return checks
        }
        let pairing = RemoteApprovalPairing(publicKeyRepresentation: privateKey.publicKey.x963Representation, deviceName: cloudKitDoctorDeviceName)
        let request = RemoteApprovalRequest(
            requestIdentifier: cloudKitDoctorRequestIdentifier,
            nonce: Data((0..<RemoteApprovalRequest.nonceByteCount).map { _ in UInt8.random(in: .min ... .max) }),
            expiry: Date().addingTimeInterval(RemoteApprovalSession.expiryInterval),
            repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/SecChain"),
            secretNames: [SecretName(rawName: "DUMMY_NAME_FOR_DOCTOR")].compactMap { $0 },
            commandArguments: ["true"],
            requestingDeviceName: cloudKitDoctorDeviceName
        )

        /// Leaves nothing behind, before and after the checks.
        func removeTheDoctorsRecords() async {
            try? await store.delete(requestIdentifier: request.requestIdentifier)
            try? await store.delete(pairing: pairing)
            _ = try? await database.deleteSubscription(withID: cloudKitProbeName)
        }
        await removeTheDoctorsRecords()

        _ = await check(stepName: "CloudKit: save and read back an \(RemoteApprovalRecordType.request) record") {
            try await store.save(request: request)
            return (try await store.request(requestIdentifier: request.requestIdentifier) == request, "")
        }
        _ = await check(stepName: "CloudKit: query the \(RemoteApprovalRecordType.request) records") {
            try await appearsInAQuery(description: "the request") {
                try await store.requests().contains(request)
            }
        }
        _ = await check(stepName: "CloudKit: save and read back an \(RemoteApprovalRecordType.decision) record") {
            let decision = RemoteApprovalDecision(
                requestIdentifier: request.requestIdentifier,
                outcome: .approved,
                signature: try RemoteApproval.signature(request: request) { try privateKey.signature(for: $0) }
            )
            try await store.save(decision: decision)
            return (try await store.decision(requestIdentifier: request.requestIdentifier) == decision, "")
        }
        _ = await check(stepName: "CloudKit: save and read back an \(RemoteApprovalRecordType.cancellation) record") {
            let cancellation = RemoteApprovalCancellation(requestIdentifier: request.requestIdentifier)
            try await store.save(cancellation: cancellation)
            return (try await store.cancellation(requestIdentifier: request.requestIdentifier) == cancellation, "")
        }
        _ = await check(stepName: "CloudKit: save and query a \(RemoteApprovalRecordType.pairing) record") {
            try await store.save(pairing: pairing)
            return try await appearsInAQuery(description: "the published key") {
                try await store.pairings().contains(pairing)
            }
        }
        _ = await check(stepName: "CloudKit: delete the records of the protocol") {
            try await store.delete(requestIdentifier: request.requestIdentifier)
            try await store.delete(pairing: pairing)
            // Each read is its own statement because `try` cannot appear inside `&&`.
            let remainingRequest = try await store.request(requestIdentifier: request.requestIdentifier)
            let remainingDecision = try await store.decision(requestIdentifier: request.requestIdentifier)
            let remainingCancellation = try await store.cancellation(requestIdentifier: request.requestIdentifier)
            let remainingPairings = try await store.pairings()
            return (
                remainingRequest == nil && remainingDecision == nil && remainingCancellation == nil && !remainingPairings.contains(pairing),
                ""
            )
        }
        _ = await check(stepName: "CloudKit: save a query subscription on \(RemoteApprovalRecordType.request) with a visible notification") {
            let subscription = CKQuerySubscription(
                recordType: RemoteApprovalRecordType.request,
                predicate: RemoteApprovalCloudKitRecords.everyRecordPredicate(),
                subscriptionID: cloudKitProbeName,
                options: [.firesOnRecordCreation]
            )
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.title = "SecChain"
            notificationInfo.alertBody = cloudKitProbeAlertBody
            subscription.notificationInfo = notificationInfo
            _ = try await database.save(subscription)
            return (true, "")
        }
        _ = await check(stepName: "CloudKit: fetch the subscription back with its notification") {
            let subscription = try await database.subscription(for: cloudKitProbeName)
            return (subscription.notificationInfo?.alertBody == cloudKitProbeAlertBody, "alertBody \(subscription.notificationInfo?.alertBody == cloudKitProbeAlertBody ? "matches" : "does not match")")
        }
        _ = await check(stepName: "CloudKit: delete the subscription") {
            _ = try await database.deleteSubscription(withID: cloudKitProbeName)
            return (true, "")
        }
        await removeTheDoctorsRecords()
        return checks
    }

    /// How long the doctor waits for a query to see a record that was just saved. A fetch by record
    /// name reads the record itself, but a query reads an index that CloudKit updates
    /// asynchronously, so a record can be missing from a query right after it was stored
    /// (documents/PROJECT.md, "Remote approval spike"). 30 seconds is far above the delay measured
    /// there and keeps the doctor from hanging when the index never catches up.
    static let cloudKitQueryIndexTimeout: TimeInterval = 30
    /// Time between two attempts, chosen so that the reported delay is precise to a second without
    /// spending a CloudKit call every few milliseconds.
    static let cloudKitQueryIndexRetryInterval = Duration.seconds(1)

    /// Repeats `isFound` until it holds or the timeout passes, and reports how long the index took.
    static func appearsInAQuery(description: String, isFound: () async throws -> Bool) async throws -> (held: Bool, detail: String) {
        let start = Date()
        while true {
            if try await isFound() {
                return (true, "\(description) appeared in the query after \(Int(Date().timeIntervalSince(start).rounded()))s")
            }
            guard Date().timeIntervalSince(start) < cloudKitQueryIndexTimeout else {
                return (false, "\(description) was still missing from the query after \(Int(cloudKitQueryIndexTimeout))s")
            }
            try await Task.sleep(for: cloudKitQueryIndexRetryInterval)
        }
    }

    /// Creating a `CKContainer` stops a process that lacks the container entitlement (measured: a trace
    /// trap inside CloudKit), so the doctor reads its own signature first and reports a code-signing
    /// problem instead. The environment is reported because a Developer ID profile allows only
    /// Production.
    static func cloudKitContainerEntitlementCheck() -> KeychainDoctorCheck {
        KeychainDoctorCheck(
            name: "CloudKit: this binary is signed with the container entitlement",
            status: CloudKitEntitlements.isSignedForSecChainContainer ? errSecSuccess : errSecMissingEntitlement,
            passed: CloudKitEntitlements.isSignedForSecChainContainer,
            detail: "containers = \(CloudKitEntitlements.containerIdentifiers()), icloud-container-environment = \(CloudKitEntitlements.containerEnvironment() ?? "not set")"
        )
    }

    /// The CloudKit error code and the server's explanation, which name the missing entitlement,
    /// schema, or account problem.
    static func cloudKitErrorDetail(error: any Error) -> String {
        guard let cloudKitError = error as? CKError else {
            return "\(error)"
        }
        return "CKError \(cloudKitError.code.rawValue): \(cloudKitError.localizedDescription)"
    }
}
