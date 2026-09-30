import Foundation
import SecChainCore

/// `UserDefaults` key of the repositories and shared scopes added by hand in an app
/// (`AppModel.addScope`). Nothing else records a scope without a secret, so without this list one
/// would be gone after the app restarts. It holds identifiers only, never a value
/// (documents/PROJECT.md, "Security invariants"), and belongs to one device: `UserDefaults` is not
/// synchronized.
let addedScopesDefaultsKey = "addedScopes"

/// The scopes added by hand on this device, in the order they were added. An entry that names no
/// scope this version accepts is left out rather than guessed at.
func addedScopes(userDefaults: UserDefaults) -> [SecretScope] {
    (userDefaults.stringArray(forKey: addedScopesDefaultsKey) ?? []).compactMap(addedScope(keychainService:))
}

/// Replaces the scopes added by hand on this device. Writing the list it already holds changes
/// nothing (idempotent).
func writeAddedScopes(scopes: [SecretScope], userDefaults: UserDefaults) {
    userDefaults.set(scopes.map(\.keychainService), forKey: addedScopesDefaultsKey)
}

/// A scope of the list, written as its Keychain service because that spelling tells a repository
/// from a shared scope. A repository is read back whole: `SecretScope(keychainService:)` would read
/// an identifier typed with `#` as an environment of another repository.
func addedScope(keychainService: String) -> SecretScope? {
    RepositoryIdentity(keychainService: keychainService).map(SecretScope.repository) ?? SecretScope(keychainService: keychainService)
}
