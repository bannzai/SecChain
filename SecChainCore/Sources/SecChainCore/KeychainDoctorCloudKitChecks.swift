import CloudKit
import Foundation
import Security

extension KeychainDoctor {
    /// Record type reserved for the doctor. A development build creates it in the development schema
    /// on the first save; the production schema only has it after the schema is deployed.
    static let cloudKitProbeRecordType = "DoctorProbe"
    /// Fixed record and subscription name, so that a run removes whatever an interrupted run left behind.
    static let cloudKitProbeName = "secchain-doctor-probe"
    /// Dummy notification text. A remote approval notification would name the requesting Mac instead.
    static let cloudKitProbeAlertBody = "dummy-alert-for-doctor"

    /// Checks whether this binary can use SecChain's CloudKit container the way remote approval
    /// needs (issue #32): the private database stores, returns, and deletes a record, and accepts a
    /// query subscription whose notification is visible. Only dummy values are stored.
    public static func runCloudKitChecks() async -> [KeychainDoctorCheck] {
        #if os(macOS)
        let entitlementCheck = cloudKitContainerEntitlementCheck()
        guard entitlementCheck.passed else {
            return [entitlementCheck]
        }
        var checks = [entitlementCheck]
        #else
        var checks: [KeychainDoctorCheck] = []
        #endif

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
        let recordID = CKRecord.ID(recordName: cloudKitProbeName)

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

        _ = try? await database.deleteRecord(withID: recordID)
        _ = try? await database.deleteSubscription(withID: cloudKitProbeName)

        _ = await check(stepName: "CloudKit: save a record to the private database") {
            let record = CKRecord(recordType: cloudKitProbeRecordType, recordID: recordID)
            record["payload"] = String(decoding: dummyValue, as: UTF8.self)
            _ = try await database.save(record)
            return (true, "")
        }
        _ = await check(stepName: "CloudKit: fetch the record back") {
            let record = try await database.record(for: recordID)
            return (record["payload"] as? String == String(decoding: dummyValue, as: UTF8.self), "")
        }
        _ = await check(stepName: "CloudKit: delete the record") {
            _ = try await database.deleteRecord(withID: recordID)
            return (true, "")
        }
        _ = await check(stepName: "CloudKit: save a query subscription with a visible notification") {
            let subscription = CKQuerySubscription(
                recordType: cloudKitProbeRecordType,
                predicate: NSPredicate(value: true),
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
        return checks
    }

    #if os(macOS)
    /// CloudKit terminates the process with an exception when the container entitlement is missing,
    /// so the doctor reads its own signature first and reports a code-signing problem instead. The
    /// environment entitlement is reported because Developer ID builds must name Production.
    static func cloudKitContainerEntitlementCheck() -> KeychainDoctorCheck {
        let task = SecTaskCreateFromSelf(nil)
        let containerIdentifiers = task.flatMap {
            SecTaskCopyValueForEntitlement($0, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        } as? [String] ?? []
        let environment = task.flatMap {
            SecTaskCopyValueForEntitlement($0, "com.apple.developer.icloud-container-environment" as CFString, nil)
        } as? String
        let isEntitled = containerIdentifiers.contains(SecChainSharedConfig.cloudKitContainerIdentifier)
        return KeychainDoctorCheck(
            name: "CloudKit: this binary is signed with the container entitlement",
            status: isEntitled ? errSecSuccess : errSecMissingEntitlement,
            passed: isEntitled,
            detail: "containers = \(containerIdentifiers), icloud-container-environment = \(environment ?? "not set")"
        )
    }
    #endif

    /// The CloudKit error code and the server's explanation, which name the missing entitlement,
    /// schema, or account problem.
    static func cloudKitErrorDetail(error: any Error) -> String {
        guard let cloudKitError = error as? CKError else {
            return "\(error)"
        }
        return "CKError \(cloudKitError.code.rawValue): \(cloudKitError.localizedDescription)"
    }
}
