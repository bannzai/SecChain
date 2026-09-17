import Foundation

/// The Keychain operations SecChain needs, without any policy (who must authenticate when is
/// decided by `SecretStore`). A protocol so that the policy and the front ends can be tested
/// against `InMemorySecretKeychain`, because the real Keychain is only reachable from a build
/// signed with the team's identity.
///
/// Every method throws `SecretStoreError`.
public protocol SecretKeychain: Sendable {
    /// Non-secret attributes of the stored secrets, never prompting. `nil` lists every repository.
    func storedSecrets(repositoryIdentity: RepositoryIdentity?) throws -> [StoredSecret]

    /// The value of one secret. `ownerAuthentication` is required for device-bound secrets.
    func value(storedSecret: StoredSecret, ownerAuthentication: OwnerAuthentication?) throws -> SecretValue

    /// Stores `value` as described by `storedSecret`. `replacing` is the variant of the same name
    /// that exists today, if any; it may differ in protection level and synchronization. The new
    /// variant is written before the old one is removed, so a failure never loses the value.
    func write(
        storedSecret: StoredSecret,
        value: SecretValue,
        replacing: StoredSecret?,
        ownerAuthentication: OwnerAuthentication?
    ) throws

    /// Removes the secret. Deleting a secret that does not exist succeeds (idempotent).
    func delete(storedSecret: StoredSecret) throws
}
