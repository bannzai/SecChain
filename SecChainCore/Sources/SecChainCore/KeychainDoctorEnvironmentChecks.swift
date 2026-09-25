import Foundation
import Security

extension KeychainDoctor {
    /// Name of the environment reserved for the doctor.
    static let storeCheckEnvironmentName = "secchain-doctor"

    /// Exercises the environments of `scope` (documents/PROJECT.md, "Environments") through
    /// `SecretStore` against the real Keychain: a secret of an environment is listed with it and read
    /// in it, moving a secret without an environment into one keeps its value, moving a device-bound
    /// secret without the user moves nothing, and the device-bound value of an environment is an item
    /// of its own. Only dummy values are stored, and the doctor's secrets of `scope` are deleted
    /// before and after.
    static func runEnvironmentChecks(scope: SecretScope) async -> [KeychainDoctorCheck] {
        let store = SecretStore(keychain: SystemSecretKeychain(), ownerAuthenticator: NonInteractiveOwnerAuthenticator())
        guard
            let name = SecretName(rawName: "DOCTOR_SECRET"),
            let deviceBoundName = SecretName(rawName: "DOCTOR_DEVICE_BOUND_SECRET"),
            let environment = SecretEnvironment(rawName: storeCheckEnvironmentName)
        else {
            return []
        }
        let firstValue = SecretValue(exposingString: "dummy-value-for-doctor-1")
        let secondValue = SecretValue(exposingString: "dummy-value-for-doctor-2")
        var checks: [KeychainDoctorCheck] = []

        /// Runs one step and records whether `expectation` held, or the error it threw.
        func check(stepName: String, expectation: () async throws -> Bool) async {
            do {
                let held = try await expectation()
                checks.append(KeychainDoctorCheck(name: "store (environments): \(stepName)", status: errSecSuccess, passed: held, detail: ""))
            } catch {
                checks.append(KeychainDoctorCheck(name: "store (environments): \(stepName)", status: errSecSuccess, passed: false, detail: "\(error)"))
            }
        }

        /// Deletes the doctor's secrets of `scope`, the environment's first: while it holds one, a
        /// delete without an environment of a name that has none is refused.
        func deleteTheDoctorsSecrets() async {
            for secretEnvironment in [environment, nil] {
                for secretName in [name, deviceBoundName] {
                    try? await store.delete(name: secretName, scope: scope, environment: secretEnvironment)
                }
            }
        }

        /// Whether the protected value of the device-bound secret in `secretEnvironment` exists.
        func protectedValueExists(secretEnvironment: SecretEnvironment?) -> Bool? {
            KeychainDoctor.protectedValueExists(
                storedSecret: StoredSecret(scope: scope, name: deviceBoundName, environment: secretEnvironment, protectionLevel: .deviceBound, isSynchronized: false, modificationDate: nil)
            )
        }

        await deleteTheDoctorsSecrets()
        await check(stepName: "a secret of an environment is listed with it and read in it") {
            try await store.set(name: name, value: firstValue, scope: scope, environment: environment, protectionLevel: nil, isSynchronized: false)
            let listed = try store.storedSecrets(scope: scope)
            let value = try await store.values(names: [name], scopes: [scope], environment: environment, authenticationReason: "doctor")[name]
            return listed.map(\.environment) == [environment] && value == firstValue
        }
        await check(stepName: "move a secret without an environment into the environment, keeping its value") {
            try await store.delete(name: name, scope: scope, environment: environment)
            try await store.set(name: name, value: secondValue, scope: scope, environment: nil, protectionLevel: nil, isSynchronized: false)
            let movedSecrets = try await store.moveToEnvironment(names: nil, scope: scope, environment: environment)
            let secretsWithoutEnvironment = try store.storedSecrets(scope: scope, environment: nil)
            let value = try await store.values(names: [name], scopes: [scope], environment: environment, authenticationReason: "doctor")[name]
            return movedSecrets.map(\.name) == [name] && secretsWithoutEnvironment.isEmpty && value == secondValue
        }
        #if !targetEnvironment(simulator)
        await check(stepName: "moving a device-bound secret is refused without user interaction, and nothing moves") {
            await deleteTheDoctorsSecrets()
            try await store.set(name: deviceBoundName, value: firstValue, scope: scope, environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
            do {
                _ = try await store.moveToEnvironment(names: nil, scope: scope, environment: environment)
                return false
            } catch SecretStoreError.authenticationNotPossible {
                return try store.storedSecrets(scope: scope).map(\.environment) == [nil]
                    && protectedValueExists(secretEnvironment: nil) == true
                    && protectedValueExists(secretEnvironment: environment) == false
            }
        }
        #endif
        await check(stepName: "the device-bound value of an environment is an item of its own") {
            await deleteTheDoctorsSecrets()
            try await store.set(name: deviceBoundName, value: firstValue, scope: scope, environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
            try await store.set(name: deviceBoundName, value: secondValue, scope: scope, environment: environment, protectionLevel: .deviceBound, isSynchronized: nil)
            try await store.delete(name: deviceBoundName, scope: scope, environment: environment)
            return protectedValueExists(secretEnvironment: nil) == true && protectedValueExists(secretEnvironment: environment) == false
        }
        await deleteTheDoctorsSecrets()
        await check(stepName: "delete, leaving no item of the environment behind") {
            try store.storedSecrets(scope: scope).isEmpty
        }
        return checks
    }
}
