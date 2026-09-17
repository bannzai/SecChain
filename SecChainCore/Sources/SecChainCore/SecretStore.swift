import Foundation

/// The rules shared by every front end: which variant of a secret is the effective one, when the
/// device owner must authenticate, and how protection level and synchronization change
/// (documents/PROJECT.md, "Protection levels"). The Keychain and the authenticator are injected so
/// that these rules are unit-tested without a signed build and without a prompt.
public struct SecretStore: Sendable {
    let keychain: any SecretKeychain
    let ownerAuthenticator: any OwnerAuthenticating
    /// Bundle whose String Catalog translates the reasons this store gives the authentication
    /// prompt, so that the system dialog speaks the language of the front end that asked.
    let authenticationReasonBundle: Bundle

    // `Bundle.main` by default: the command-line tool and the tests have no translations there, so
    // their reasons stay English. The apps pass the bundle of SecChainUI, which holds the catalog.
    public init(keychain: any SecretKeychain, ownerAuthenticator: any OwnerAuthenticating, authenticationReasonBundle: Bundle = .main) {
        self.keychain = keychain
        self.ownerAuthenticator = ownerAuthenticator
        self.authenticationReasonBundle = authenticationReasonBundle
    }

    /// The store used by the shipping front ends.
    public static var system: SecretStore {
        SecretStore(keychain: SystemSecretKeychain(), ownerAuthenticator: SystemOwnerAuthenticator())
    }

    // MARK: - Listing (never prompts)

    /// The effective secrets of one repository, sorted by name.
    public func storedSecrets(repositoryIdentity: RepositoryIdentity) throws -> [StoredSecret] {
        Self.effectiveSecrets(storedSecrets: try keychain.storedSecrets(repositoryIdentity: repositoryIdentity))
    }

    /// Every repository that has at least one secret on this device, sorted.
    public func repositoryIdentities() throws -> [RepositoryIdentity] {
        Set(try keychain.storedSecrets(repositoryIdentity: nil).map(\.repositoryIdentity))
            .sorted { $0.value < $1.value }
    }

    // MARK: - Reading

    /// Values for `secchain run`. `names == nil` means every secret of the repository. One
    /// authentication covers all requested secrets that are not `standard`.
    public func values(
        names: [SecretName]?,
        repositoryIdentity: RepositoryIdentity,
        authenticationReason: String
    ) async throws -> [SecretName: SecretValue] {
        let effectiveSecrets = try storedSecrets(repositoryIdentity: repositoryIdentity)
        let requestedSecrets = try (names ?? effectiveSecrets.map(\.name)).map { name in
            guard let storedSecret = effectiveSecrets.first(where: { $0.name == name }) else {
                throw SecretStoreError.secretNotFound(name: name.value, repository: repositoryIdentity.value)
            }
            return storedSecret
        }
        let ownerAuthentication = requestedSecrets.contains(where: { $0.protectionLevel != .standard })
            ? try await ownerAuthenticator.authenticate(reason: authenticationReason)
            : nil
        return try Dictionary(
            uniqueKeysWithValues: requestedSecrets.map { storedSecret in
                (storedSecret.name, try keychain.value(storedSecret: storedSecret, ownerAuthentication: ownerAuthentication))
            }
        )
    }

    /// The value for an explicit reveal in an app. Always authenticates, whatever the level,
    /// because putting a value on screen is the most exposed thing SecChain does.
    public func revealedValue(name: SecretName, repositoryIdentity: RepositoryIdentity) async throws -> SecretValue {
        try keychain.value(
            storedSecret: try existingSecret(name: name, repositoryIdentity: repositoryIdentity),
            ownerAuthentication: try await ownerAuthenticator.authenticate(
                reason: String(localized: "reveal \(name.value)", bundle: authenticationReasonBundle)
            )
        )
    }

    // MARK: - Writing

    /// Adds the secret, or updates it when the name exists. `nil` for `protectionLevel` /
    /// `isSynchronized` keeps the existing setting; a new secret defaults to `standard` and
    /// synchronized. Updating a secret that is not `standard` authenticates first, which also
    /// covers every way of lowering a level.
    @discardableResult
    public func set(
        name: SecretName,
        value: SecretValue,
        repositoryIdentity: RepositoryIdentity,
        protectionLevel: ProtectionLevel?,
        isSynchronized: Bool?
    ) async throws -> StoredSecret {
        guard !value.isEmpty else {
            throw SecretStoreError.emptyValue
        }
        let variants = try keychain.storedSecrets(repositoryIdentity: repositoryIdentity).filter { $0.name == name }
        let existing = Self.effectiveSecrets(storedSecrets: variants).first
        // `standard`: a secret asks for authentication only when the user opted in.
        let targetProtectionLevel = protectionLevel ?? existing?.protectionLevel ?? .standard
        guard !(targetProtectionLevel == .deviceBound && isSynchronized == true) else {
            throw SecretStoreError.deviceBoundCannotSynchronize
        }
        let target = StoredSecret(
            repositoryIdentity: repositoryIdentity,
            name: name,
            protectionLevel: targetProtectionLevel,
            // Synchronized by default: following the user across their Macs is the point of
            // SecChain. A device-bound secret can never synchronize.
            isSynchronized: targetProtectionLevel == .deviceBound ? false : (isSynchronized ?? existing?.isSynchronized ?? true),
            modificationDate: nil
        )
        let ownerAuthentication = (existing.map { $0.protectionLevel != .standard } ?? false)
            ? try await ownerAuthenticator.authenticate(reason: String(localized: "update \(name.value)", bundle: authenticationReasonBundle))
            : nil
        // A non-effective variant (for example a synchronized copy that arrived from another Mac
        // while a local one existed) is removed: it would collide with the target when it has the
        // target's synchronization, and it would resurface later otherwise.
        for variant in variants where variant.id != existing?.id {
            try keychain.delete(storedSecret: variant)
        }
        try keychain.write(storedSecret: target, value: value, replacing: existing, ownerAuthentication: ownerAuthentication)
        return target
    }

    /// Changes protection level and / or synchronization without changing the value.
    @discardableResult
    public func changeProtection(
        name: SecretName,
        repositoryIdentity: RepositoryIdentity,
        protectionLevel: ProtectionLevel,
        isSynchronized: Bool
    ) async throws -> StoredSecret {
        let existing = try existingSecret(name: name, repositoryIdentity: repositoryIdentity)
        guard !(protectionLevel == .deviceBound && isSynchronized) else {
            throw SecretStoreError.deviceBoundCannotSynchronize
        }
        let ownerAuthentication = existing.protectionLevel != .standard
            ? try await ownerAuthenticator.authenticate(
                reason: String(localized: "change the protection of \(name.value)", bundle: authenticationReasonBundle)
            )
            : nil
        let target = StoredSecret(
            repositoryIdentity: repositoryIdentity,
            name: name,
            protectionLevel: protectionLevel,
            isSynchronized: isSynchronized,
            modificationDate: nil
        )
        let value = try keychain.value(storedSecret: existing, ownerAuthentication: ownerAuthentication)
        // Same reason as in `set`: a non-effective variant must not collide with the target.
        for variant in try keychain.storedSecrets(repositoryIdentity: repositoryIdentity)
        where variant.name == name && variant.id != existing.id {
            try keychain.delete(storedSecret: variant)
        }
        try keychain.write(
            storedSecret: target,
            value: value,
            replacing: existing,
            ownerAuthentication: ownerAuthentication
        )
        return target
    }

    /// Deletes every variant of the name. Authenticates first when the secret is not `standard`.
    /// Deleting a name that does not exist succeeds (idempotent).
    public func delete(name: SecretName, repositoryIdentity: RepositoryIdentity) async throws {
        let variants = try keychain.storedSecrets(repositoryIdentity: repositoryIdentity).filter { $0.name == name }
        if variants.contains(where: { $0.protectionLevel != .standard }) {
            _ = try await ownerAuthenticator.authenticate(reason: String(localized: "delete \(name.value)", bundle: authenticationReasonBundle))
        }
        for variant in variants {
            try keychain.delete(storedSecret: variant)
        }
    }

    // MARK: - Rules

    /// One entry per name. When a local and a synchronized variant of one name coexist, the local
    /// one wins: it was created on this device on purpose, while the synchronized one may have
    /// arrived from another Mac.
    static func effectiveSecrets(storedSecrets: [StoredSecret]) -> [StoredSecret] {
        Dictionary(grouping: storedSecrets, by: { "\($0.repositoryIdentity.value)\u{0}\($0.name.value)" })
            .values
            .compactMap { variants in
                variants.first(where: { !$0.isSynchronized }) ?? variants.first
            }
            .sorted { ($0.repositoryIdentity.value, $0.name) < ($1.repositoryIdentity.value, $1.name) }
    }

    func existingSecret(name: SecretName, repositoryIdentity: RepositoryIdentity) throws -> StoredSecret {
        guard let existing = try storedSecrets(repositoryIdentity: repositoryIdentity).first(where: { $0.name == name }) else {
            throw SecretStoreError.secretNotFound(name: name.value, repository: repositoryIdentity.value)
        }
        return existing
    }
}
