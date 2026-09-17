import Foundation
import LocalAuthentication
import Security

/// Outcome of one diagnostic step. The raw `OSStatus` is kept because the purpose of the doctor
/// is to show what the system really answered on this machine with this code signature.
public struct KeychainDoctorCheck: Sendable {
    /// What the step verifies, phrased as the expected behavior.
    public let name: String
    /// Status returned by the Security framework call that decides the step.
    public let status: OSStatus
    /// Whether the observed behavior is the one SecChain's design relies on.
    public let passed: Bool
    /// Extra observation that does not fit a status code (counts, policy availability).
    public let detail: String
}

/// Diagnoses whether the running binary can use SecChain's shared Keychain access group the way
/// the design requires (documents/PROJECT.md, design decisions 1, 2 and 4). It only ever stores a
/// fixed dummy value under a dedicated service, never a user's secret.
public enum KeychainDoctor {
    /// Service reserved for diagnostic items so that they can never collide with a repository.
    static let service = "com.bannzai.SecChain.doctor"
    /// Dummy payload. Its content is irrelevant; a fixed value lets another binary verify a read.
    static let dummyValue = Data("dummy-value-for-doctor".utf8)

    /// Runs the self-contained checks: every item it creates is deleted before and after.
    public static func runSelfContainedChecks() -> [KeychainDoctorCheck] {
        _ = deleteAll()
        defer {
            _ = deleteAll()
        }
        return [
            addPlainItem(account: "local", synchronizable: false),
            readPlainItem(account: "local", synchronizable: false),
            addPlainItem(account: "local", synchronizable: true),
            countItemsIgnoringSynchronizable(account: "local", expectedCount: 2),
            listAttributesWithoutData(account: "local"),
            addUserPresenceItem(account: "device-bound", synchronizable: false, expectSuccess: true),
            readUserPresenceItemWithoutInteraction(account: "device-bound"),
            listingFailsWhenAnAccessControlledItemMatches(),
            addUserPresenceItem(account: "device-bound-sync", synchronizable: true, expectSuccess: false),
            canEvaluateOwnerAuthentication(),
        ]
    }

    /// Leaves a synchronizable fixture item behind so that a different binary can prove it shares
    /// the access group by reading it.
    public static func writeFixture(account: String) -> KeychainDoctorCheck {
        _ = SecItemDelete(baseQuery(account: account, synchronizable: true) as CFDictionary)
        return addPlainItem(account: account, synchronizable: true)
    }

    /// Reads and then deletes a fixture written by another binary.
    public static func readAndDeleteFixture(account: String) -> [KeychainDoctorCheck] {
        [
            readPlainItem(account: account, synchronizable: true),
            KeychainDoctorCheck(
                name: "delete the fixture written by the other binary",
                status: SecItemDelete(baseQuery(account: account, synchronizable: true) as CFDictionary),
                passedStatus: errSecSuccess
            ),
        ]
    }

    /// Prompts for owner authentication. This is the only interactive check, so it is separate
    /// from `runSelfContainedChecks` and must be requested explicitly.
    public static func evaluateOwnerAuthentication() async -> KeychainDoctorCheck {
        do {
            try await LAContext().evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "confirm that SecChain can ask for authentication"
            )
            return KeychainDoctorCheck(
                name: "LAContext.evaluatePolicy succeeds from this binary",
                status: errSecSuccess,
                passed: true,
                detail: "authenticated"
            )
        } catch {
            return KeychainDoctorCheck(
                name: "LAContext.evaluatePolicy succeeds from this binary",
                status: OSStatus((error as NSError).code),
                passed: false,
                detail: "LAError code \((error as NSError).code)"
            )
        }
    }

    /// Lets an app binary run the doctor when launched with `--doctor`, `--doctor-cloudkit`,
    /// `--doctor-write-fixture <account>` or `--doctor-read-fixture <account>`, printing the result
    /// lines. Apps have no command-line interface of their own, and the interoperability check needs
    /// each signed binary to act on the Keychain itself. Returns `nil` when the arguments do not ask
    /// for it.
    public static func exitCodeForLaunchArguments(arguments: [String]) -> Int32? {
        let checks: [KeychainDoctorCheck]
        if let index = arguments.firstIndex(of: "--doctor-write-fixture"), arguments.indices.contains(index + 1) {
            checks = [writeFixture(account: arguments[index + 1])]
        } else if let index = arguments.firstIndex(of: "--doctor-read-fixture"), arguments.indices.contains(index + 1) {
            checks = readAndDeleteFixture(account: arguments[index + 1])
        } else if arguments.contains("--doctor-cloudkit") {
            checks = blockingChecks(runChecks: runCloudKitChecks)
        } else if arguments.contains("--doctor") {
            checks = runSelfContainedChecks() + blockingChecks(runChecks: runStoreChecks)
        } else {
            return nil
        }
        for check in checks {
            print(check.line)
        }
        return checks.allSatisfy(\.passed) ? 0 : 1
    }

    /// `App.init` is synchronous, and the process exits right after the doctor, so the launch
    /// argument path waits for the asynchronous checks. Nothing in them needs the main actor (the
    /// doctor's authenticator never prompts, and CloudKit calls back on its own queues), so
    /// blocking the calling thread is safe.
    static func blockingChecks(runChecks: @escaping @Sendable () async -> [KeychainDoctorCheck]) -> [KeychainDoctorCheck] {
        let result = BlockingResult()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            result.checks = await runChecks()
            semaphore.signal()
        }
        semaphore.wait()
        return result.checks
    }

    /// Carries the result out of the detached task. The semaphore orders the single write before
    /// the single read, which is why the class can be unchecked `Sendable`.
    final class BlockingResult: @unchecked Sendable {
        var checks: [KeychainDoctorCheck] = []
    }

    // MARK: - Steps

    static func addPlainItem(account: String, synchronizable: Bool) -> KeychainDoctorCheck {
        var attributes = baseQuery(account: account, synchronizable: synchronizable)
        attributes[kSecValueData as String] = dummyValue
        attributes[kSecAttrDescription as String] = "standard"
        return KeychainDoctorCheck(
            name: "add an item to the shared access group (synchronizable: \(synchronizable))",
            status: SecItemAdd(attributes as CFDictionary, nil),
            passedStatus: errSecSuccess
        )
    }

    static func readPlainItem(account: String, synchronizable: Bool) -> KeychainDoctorCheck {
        var query = baseQuery(account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return KeychainDoctorCheck(
            name: "read the item back without a permission dialog (synchronizable: \(synchronizable))",
            status: status,
            passed: status == errSecSuccess && (item as? Data) == dummyValue,
            detail: (item as? Data) == dummyValue ? "value matches" : "value does not match"
        )
    }

    static func countItemsIgnoringSynchronizable(account: String, expectedCount: Int) -> KeychainDoctorCheck {
        var query = baseQuery(account: account, synchronizable: nil)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        let count = (items as? [[String: Any]])?.count ?? 0
        return KeychainDoctorCheck(
            name: "synchronizable and local variants of one account are separate items",
            status: status,
            passed: status == errSecSuccess && count == expectedCount,
            detail: "found \(count), expected \(expectedCount)"
        )
    }

    static func listAttributesWithoutData(account: String) -> KeychainDoctorCheck {
        var query = baseQuery(account: account, synchronizable: false)
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let description = (item as? [String: Any])?[kSecAttrDescription as String] as? String
        return KeychainDoctorCheck(
            name: "a non-secret attribute can carry the protection level and is readable without the value",
            status: status,
            passed: status == errSecSuccess && description == "standard",
            detail: "kSecAttrDescription = \(description ?? "nil")"
        )
    }

    static func addUserPresenceItem(account: String, synchronizable: Bool, expectSuccess: Bool) -> KeychainDoctorCheck {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            return KeychainDoctorCheck(
                name: "create an access control object requiring user presence",
                status: errSecParam,
                passed: false,
                detail: "SecAccessControlCreateWithFlags failed"
            )
        }
        var attributes = baseQuery(account: account, synchronizable: synchronizable)
        attributes[kSecValueData as String] = dummyValue
        attributes[kSecAttrAccessControl as String] = accessControl
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return KeychainDoctorCheck(
            name: expectSuccess
                ? "add a device-bound item (user presence, this device only)"
                : "a user-presence item cannot be synchronizable",
            status: status,
            passed: expectSuccess ? status == errSecSuccess : status != errSecSuccess,
            detail: expectSuccess ? "" : "expected a failure"
        )
    }

    static func readUserPresenceItemWithoutInteraction(account: String) -> KeychainDoctorCheck {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account, synchronizable: false)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #if targetEnvironment(simulator)
        // Measured on the iOS 26.5 Simulator: the read succeeds without any authentication, so
        // the step can only report the behavior there. Enforcement is checked on real hardware.
        return KeychainDoctorCheck(
            name: "the Keychain refuses to return a device-bound item without user interaction",
            status: status,
            passed: true,
            detail: "not enforced by the Simulator; verify on a device"
        )
        #else
        return KeychainDoctorCheck(
            name: "the Keychain refuses to return a device-bound item without user interaction",
            status: status,
            passed: status == errSecInteractionNotAllowed && item == nil,
            detail: "expected errSecInteractionNotAllowed (\(errSecInteractionNotAllowed))"
        )
        #endif
    }

    /// Documents why a device-bound secret is split into a listable marker and a protected value
    /// stored under another item class (see `SystemSecretKeychain`). Measured on macOS 26: a
    /// query that matches an access-controlled item fails as a whole with
    /// `errSecInteractionNotAllowed` when prompting is disabled, even if only attributes are
    /// requested. Listing must never prompt, so list queries must never match such an item.
    static func listingFailsWhenAnAccessControlledItemMatches() -> KeychainDoctorCheck {
        let context = LAContext()
        context.interactionNotAllowed = true
        var items: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: SecChainSharedConfig.keychainAccessGroup,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecUseAuthenticationContext as String: context,
            ] as CFDictionary,
            &items
        )
        #if targetEnvironment(simulator)
        // The Simulator does not enforce access control, so the query simply succeeds there.
        return KeychainDoctorCheck(
            name: "an attribute query that matches an access-controlled item fails instead of prompting",
            status: status,
            passed: true,
            detail: "not enforced by the Simulator; verify on a device"
        )
        #else
        return KeychainDoctorCheck(
            name: "an attribute query that matches an access-controlled item fails instead of prompting",
            status: status,
            passed: status == errSecInteractionNotAllowed,
            detail: "expected errSecInteractionNotAllowed (\(errSecInteractionNotAllowed))"
        )
        #endif
    }

    static func canEvaluateOwnerAuthentication() -> KeychainDoctorCheck {
        var error: NSError?
        let canEvaluate = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return KeychainDoctorCheck(
            name: "owner authentication is available to this binary",
            status: OSStatus(error?.code ?? 0),
            passed: canEvaluate,
            detail: canEvaluate ? "canEvaluatePolicy = true" : "LAError code \(error?.code ?? 0)"
        )
    }

    // MARK: - Queries

    /// `synchronizable == nil` leaves the attribute out so that the caller can set
    /// `kSecAttrSynchronizableAny`.
    static func baseQuery(account: String, synchronizable: Bool?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: SecChainSharedConfig.keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable
        }
        return query
    }

    static func deleteAll() -> OSStatus {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: SecChainSharedConfig.keychainAccessGroup,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ] as CFDictionary
        )
    }
}

extension KeychainDoctorCheck {
    // The synthesized memberwise initializer stays available; this one covers the common case
    // where a single expected status decides the outcome.
    init(name: String, status: OSStatus, passedStatus: OSStatus) {
        self.init(name: name, status: status, passed: status == passedStatus, detail: "")
    }

    /// One line for terminal output. `SecCopyErrorMessageString` gives the system's wording for
    /// the status so that the reader does not have to look the number up.
    public var line: String {
        "\(passed ? "ok  " : "FAIL") \(name) [status \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")]\(detail.isEmpty ? "" : " (\(detail))")"
    }
}
