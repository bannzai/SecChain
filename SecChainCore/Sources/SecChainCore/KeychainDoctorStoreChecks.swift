import Foundation
import LocalAuthentication
import Security

/// Authenticator for the doctor: never prompts. It hands out a context with interaction disabled,
/// so a device-bound value stays unreadable, which is exactly what the checks assert.
struct NonInteractiveOwnerAuthenticator: OwnerAuthenticating {
    func authenticate(reason: String) async throws -> OwnerAuthentication {
        let context = LAContext()
        context.interactionNotAllowed = true
        return OwnerAuthentication(context: context)
    }
}

extension KeychainDoctor {
    /// Repository reserved for the doctor. It cannot collide with a real one because a normalized
    /// remote always contains a host with a slash-separated path.
    static let storeCheckRepositoryIdentity = RepositoryIdentity(value: "secchain-doctor")

    /// Exercises `SystemSecretKeychain` through `SecretStore` against the real Keychain: add,
    /// read, update, every protection level and synchronization change, and delete. Only dummy
    /// values are stored, and the reserved repository is emptied before and after.
    public static func runStoreChecks() async -> [KeychainDoctorCheck] {
        let store = SecretStore(keychain: SystemSecretKeychain(), ownerAuthenticator: NonInteractiveOwnerAuthenticator())
        guard let name = SecretName(rawName: "DOCTOR_SECRET") else {
            return []
        }
        let firstValue = SecretValue(exposingString: "dummy-value-for-doctor-1")
        let secondValue = SecretValue(exposingString: "dummy-value-for-doctor-2")
        var checks: [KeychainDoctorCheck] = []

        /// Runs one step and records whether `expectation` held, or the error it threw.
        func check(stepName: String, expectation: () async throws -> Bool) async {
            do {
                let held = try await expectation()
                checks.append(KeychainDoctorCheck(name: stepName, status: errSecSuccess, passed: held, detail: ""))
            } catch {
                checks.append(KeychainDoctorCheck(name: stepName, status: errSecSuccess, passed: false, detail: "\(error)"))
            }
        }

        func effectiveSecret() throws -> StoredSecret? {
            try store.storedSecrets(repositoryIdentity: storeCheckRepositoryIdentity).first
        }

        func currentValue() async throws -> SecretValue? {
            try await store.values(names: [name], repositoryIdentity: storeCheckRepositoryIdentity, authenticationReason: "doctor")[name]
        }

        try? await store.delete(name: name, repositoryIdentity: storeCheckRepositoryIdentity)

        await check(stepName: "store: add a standard, synchronized secret and list it") {
            try await store.set(name: name, value: firstValue, repositoryIdentity: storeCheckRepositoryIdentity, protectionLevel: nil, isSynchronized: nil)
            return try effectiveSecret().map { $0.protectionLevel == .standard && $0.isSynchronized } ?? false
        }
        await check(stepName: "store: read the value back") {
            try await currentValue() == firstValue
        }
        await check(stepName: "store: update the value in place") {
            try await store.set(name: name, value: secondValue, repositoryIdentity: storeCheckRepositoryIdentity, protectionLevel: nil, isSynchronized: nil)
            return try await currentValue() == secondValue
        }
        await check(stepName: "store: raise to confirm without changing the value") {
            try await store.changeProtection(name: name, repositoryIdentity: storeCheckRepositoryIdentity, protectionLevel: .confirm, isSynchronized: true)
            return try effectiveSecret()?.protectionLevel == .confirm
        }
        await check(stepName: "store: switch to this device only, leaving a single item") {
            try await store.changeProtection(name: name, repositoryIdentity: storeCheckRepositoryIdentity, protectionLevel: .confirm, isSynchronized: false)
            let variants = try SystemSecretKeychain().storedSecrets(repositoryIdentity: storeCheckRepositoryIdentity)
            let value = try await currentValue()
            return variants.map(\.isSynchronized) == [false] && value == secondValue
        }
        await check(stepName: "store: make it device-bound; it stays listed without a prompt") {
            try await store.changeProtection(name: name, repositoryIdentity: storeCheckRepositoryIdentity, protectionLevel: .deviceBound, isSynchronized: false)
            return try effectiveSecret()?.protectionLevel == .deviceBound
        }
        #if !targetEnvironment(simulator)
        await check(stepName: "store: a device-bound value is refused without user interaction") {
            do {
                _ = try await currentValue()
                return false
            } catch SecretStoreError.authenticationNotPossible {
                return true
            }
        }
        #endif
        await check(stepName: "store: overwrite the device-bound secret as standard") {
            try await store.set(name: name, value: firstValue, repositoryIdentity: storeCheckRepositoryIdentity, protectionLevel: .standard, isSynchronized: true)
            let value = try await currentValue()
            return try effectiveSecret()?.protectionLevel == .standard && value == firstValue
        }
        await check(stepName: "store: delete, leaving no item and no repository behind") {
            try await store.delete(name: name, repositoryIdentity: storeCheckRepositoryIdentity)
            return try store.storedSecrets(repositoryIdentity: storeCheckRepositoryIdentity).isEmpty
                && !store.repositoryIdentities().contains(storeCheckRepositoryIdentity)
        }
        return checks
    }
}
