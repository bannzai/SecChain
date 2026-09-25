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

    /// Name of the custom scope reserved for the doctor. It is the doctor repository's identifier on
    /// purpose: a scope and a repository of the same name are the case in which their device-bound
    /// values would share a Keychain item if the layout did not keep them apart.
    static let storeCheckScopeName = "secchain-doctor"

    /// Exercises `SystemSecretKeychain` through `SecretStore` against the real Keychain, for a
    /// repository scope and for a shared scope: add, read, update, every protection level and
    /// synchronization change, and delete. Then it checks that the device-bound values of the two
    /// are separate items. Only dummy values are stored, and the reserved scopes are emptied before
    /// and after.
    public static func runStoreChecks() async -> [KeychainDoctorCheck] {
        guard let storeCheckScope = CustomScopeName(rawName: storeCheckScopeName).map(SharedScope.custom) else {
            return []
        }
        return await runStoreChecks(scope: .repository(storeCheckRepositoryIdentity), label: "repository scope")
            + (await runStoreChecks(scope: .shared(storeCheckScope), label: "custom scope"))
            + [await deviceBoundValuesOfAScopeAndARepositoryAreSeparate(sharedScope: storeCheckScope)]
            + (await runEnvironmentChecks(scope: .shared(storeCheckScope)))
    }

    /// What an attribute query finds for the protected value of a device-bound `storedSecret`,
    /// without being allowed to prompt: a query that matches an access-controlled item fails instead
    /// of prompting (`listingFailsWhenAnAccessControlledItemMatches`), and the Simulator, which does
    /// not enforce access control, returns the item. `nil` for any other answer. Neither value can be
    /// read without a prompt, so the checks ask whether the item exists instead of reading it.
    static func protectedValueExists(storedSecret: StoredSecret) -> Bool? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = SystemSecretKeychain.protectedValueQuery(storedSecret: storedSecret)
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecInteractionNotAllowed, errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            return nil
        }
    }

    /// The round trip of `runStoreChecks` in one scope. `label` tells the scopes apart in the
    /// check names.
    static func runStoreChecks(scope: SecretScope, label: String) async -> [KeychainDoctorCheck] {
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
                checks.append(KeychainDoctorCheck(name: "store (\(label)): \(stepName)", status: errSecSuccess, passed: held, detail: ""))
            } catch {
                checks.append(KeychainDoctorCheck(name: "store (\(label)): \(stepName)", status: errSecSuccess, passed: false, detail: "\(error)"))
            }
        }

        func effectiveSecret() throws -> StoredSecret? {
            try store.storedSecrets(scope: scope).first
        }

        func currentValue() async throws -> SecretValue? {
            try await store.values(names: [name], scopes: [scope], environment: nil, authenticationReason: "doctor")[name]
        }

        try? await store.delete(name: name, scope: scope, environment: nil)

        await check(stepName: "add a standard, synchronized secret and list it") {
            try await store.set(name: name, value: firstValue, scope: scope, environment: nil, protectionLevel: nil, isSynchronized: nil)
            return try effectiveSecret().map { $0.protectionLevel == .standard && $0.isSynchronized } ?? false
        }
        await check(stepName: "read the value back") {
            try await currentValue() == firstValue
        }
        await check(stepName: "update the value in place") {
            try await store.set(name: name, value: secondValue, scope: scope, environment: nil, protectionLevel: nil, isSynchronized: nil)
            return try await currentValue() == secondValue
        }
        await check(stepName: "raise to confirm without changing the value") {
            try await store.changeProtection(name: name, scope: scope, environment: nil, protectionLevel: .confirm, isSynchronized: true)
            return try effectiveSecret()?.protectionLevel == .confirm
        }
        await check(stepName: "switch to this device only, leaving a single item") {
            try await store.changeProtection(name: name, scope: scope, environment: nil, protectionLevel: .confirm, isSynchronized: false)
            let variants = try SystemSecretKeychain().storedSecrets(scope: scope)
            let value = try await currentValue()
            return variants.map(\.isSynchronized) == [false] && value == secondValue
        }
        await check(stepName: "make it device-bound; it stays listed without a prompt") {
            try await store.changeProtection(name: name, scope: scope, environment: nil, protectionLevel: .deviceBound, isSynchronized: false)
            return try effectiveSecret()?.protectionLevel == .deviceBound
        }
        #if !targetEnvironment(simulator)
        await check(stepName: "a device-bound value is refused without user interaction") {
            do {
                _ = try await currentValue()
                return false
            } catch SecretStoreError.authenticationNotPossible {
                return true
            }
        }
        #endif
        await check(stepName: "overwrite the device-bound secret as standard") {
            try await store.set(name: name, value: firstValue, scope: scope, environment: nil, protectionLevel: .standard, isSynchronized: true)
            let value = try await currentValue()
            return try effectiveSecret()?.protectionLevel == .standard && value == firstValue
        }
        await check(stepName: "delete, leaving no item and no scope behind") {
            try await store.delete(name: name, scope: scope, environment: nil)
            return try store.storedSecrets(scope: scope).isEmpty && !store.scopes().contains(scope)
        }
        return checks
    }

    /// A device-bound value of `sharedScope` and one of the doctor's repository, whose identifier is
    /// the scope's name, are two items: deleting the scope's secret leaves the repository's value in
    /// place.
    static func deviceBoundValuesOfAScopeAndARepositoryAreSeparate(sharedScope: SharedScope) async -> KeychainDoctorCheck {
        let checkName = "store: a device-bound value of a scope and one of a repository of the same name are separate items"
        let store = SecretStore(keychain: SystemSecretKeychain(), ownerAuthenticator: NonInteractiveOwnerAuthenticator())
        guard let name = SecretName(rawName: "DOCTOR_SECRET") else {
            return KeychainDoctorCheck(name: checkName, status: errSecParam, passed: false, detail: "invalid secret name")
        }
        let repositoryScope = SecretScope.repository(storeCheckRepositoryIdentity)

        /// Whether the protected value of the device-bound secret of `scope` exists.
        func protectedValueExists(scope: SecretScope) -> Bool? {
            KeychainDoctor.protectedValueExists(
                storedSecret: StoredSecret(scope: scope, name: name, environment: nil, protectionLevel: .deviceBound, isSynchronized: false, modificationDate: nil)
            )
        }

        do {
            for scope in [repositoryScope, .shared(sharedScope)] {
                try? await store.delete(name: name, scope: scope, environment: nil)
                try await store.set(
                    name: name,
                    value: SecretValue(exposingString: "dummy-value-for-doctor-\(scope.name)"),
                    scope: scope,
                    environment: nil,
                    protectionLevel: .deviceBound,
                    isSynchronized: nil
                )
            }
            try await store.delete(name: name, scope: .shared(sharedScope), environment: nil)
            let repositoryValueExists = protectedValueExists(scope: repositoryScope)
            let scopeValueExists = protectedValueExists(scope: .shared(sharedScope))
            try await store.delete(name: name, scope: repositoryScope, environment: nil)
            return KeychainDoctorCheck(
                name: checkName,
                status: errSecSuccess,
                passed: repositoryValueExists == true && scopeValueExists == false,
                detail: "after deleting the scope's secret, the repository's value exists: \(repositoryValueExists.map(String.init) ?? "unknown"), the scope's value exists: \(scopeValueExists.map(String.init) ?? "unknown")"
            )
        } catch {
            try? await store.delete(name: name, scope: .shared(sharedScope), environment: nil)
            try? await store.delete(name: name, scope: repositoryScope, environment: nil)
            return KeychainDoctorCheck(name: checkName, status: errSecSuccess, passed: false, detail: "\(error)")
        }
    }
}
