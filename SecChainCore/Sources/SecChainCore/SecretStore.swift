import Foundation

/// The rules shared by every front end: which variant of a secret is the effective one, which scope
/// a name is taken from when several scopes are passed, which environment's secrets a scope gives,
/// when the device owner must authenticate, and how protection level and synchronization change
/// (documents/PROJECT.md, "Protection levels", "Secret scopes", and "Environments"). The Keychain and
/// the authenticator are injected so that these rules are unit-tested without a signed build and
/// without a prompt.
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

    /// The effective secrets of one scope in every environment, the ones without an environment
    /// first, each group sorted by name.
    public func storedSecrets(scope: SecretScope) throws -> [StoredSecret] {
        Self.effectiveSecrets(storedSecrets: try keychain.storedSecrets(scope: scope))
    }

    /// The effective secrets of one scope in one environment, `nil` for the secrets without an
    /// environment, sorted by name.
    public func storedSecrets(scope: SecretScope, environment: SecretEnvironment?) throws -> [StoredSecret] {
        try storedSecrets(scope: scope).filter { $0.environment == environment }
    }

    /// The secrets a command gets when `scopes` are passed to it in `environment`, one per name,
    /// sorted by name (`RunPlan.passedSecrets`). `scopes` is in order of precedence: a name that
    /// several of them hold is taken from the first.
    public func storedSecrets(scopes: [SecretScope], environment: SecretEnvironment?) throws -> [StoredSecret] {
        try RunPlan.passedSecrets(
            storedSecrets: scopes.flatMap { try storedSecrets(scope: $0) },
            passedScopes: scopes,
            environment: environment
        )
    }

    /// The environments that have at least one secret in the scope, sorted. A scope with none gives
    /// its secrets without an environment; a scope with some needs one named (documents/PROJECT.md,
    /// "Environments"). Nothing else records it, so that the Keychain, and with it iCloud Keychain,
    /// is the only place that says it.
    public func environments(scope: SecretScope) throws -> [SecretEnvironment] {
        Set(try keychain.storedSecrets(scope: scope).compactMap(\.environment)).sorted()
    }

    /// Every scope that has at least one secret on this device, repositories and shared scopes,
    /// sorted by Keychain service.
    public func scopes() throws -> [SecretScope] {
        Set(try keychain.storedSecrets(scope: nil).map(\.scope))
            .sorted { $0.keychainService < $1.keychainService }
    }

    /// Every repository that has at least one secret on this device, sorted.
    public func repositoryIdentities() throws -> [RepositoryIdentity] {
        try scopes()
            .compactMap(\.repositoryIdentity)
            .sorted { $0.value < $1.value }
    }

    // MARK: - Reading

    /// Values for `secchain run`. `names == nil` means every secret `scopes` give in `environment`,
    /// and a name is taken from the first scope that holds it (`storedSecrets(scopes:environment:)`).
    /// One authentication covers all requested secrets that are not `standard`.
    public func values(
        names: [SecretName]?,
        scopes: [SecretScope],
        environment: SecretEnvironment?,
        authenticationReason: String
    ) async throws -> [SecretName: SecretValue] {
        let passedSecrets = try storedSecrets(scopes: scopes, environment: environment)
        let requestedSecrets = try (names ?? passedSecrets.map(\.name)).map { name in
            guard let storedSecret = passedSecrets.first(where: { $0.name == name }) else {
                throw Self.notFoundError(
                    name: name,
                    location: scopes.map(\.description).joined(separator: ", "),
                    environment: environment
                )
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
    public func revealedValue(name: SecretName, scope: SecretScope, environment: SecretEnvironment?) async throws -> SecretValue {
        try keychain.value(
            storedSecret: try existingSecret(name: name, scope: scope, environment: environment),
            ownerAuthentication: try await ownerAuthenticator.authenticate(
                reason: String(localized: "reveal \(name.value)", bundle: authenticationReasonBundle)
            )
        )
    }

    // MARK: - Writing

    /// Refuses an operation without an environment on a scope that has environments: a secret
    /// stored there without one would never be passed by `run`. Front ends call it before asking for
    /// a value, so that nobody types a value that is then refused.
    public func checkEnvironmentIsNamed(scope: SecretScope, environment: SecretEnvironment?) throws {
        guard environment == nil else {
            return
        }
        let environments = try environments(scope: scope)
        guard environments.isEmpty else {
            throw SecretStoreError.environmentRequired(repository: scope.description, environments: environments.map(\.value))
        }
    }

    /// Adds the secret, or updates it when the name exists in the environment. `nil` for
    /// `protectionLevel` / `isSynchronized` keeps the existing setting; a new secret defaults to
    /// `standard` and synchronized. Updating a secret that is not `standard` authenticates first,
    /// which also covers every way of lowering a level.
    ///
    /// Nothing is stored for a repository named like a shared scope's service
    /// (`SecretScope.isRepositoryNamedLikeASharedScope`). Every item of a scope comes from here, so
    /// such a repository never has a secret that a later write or delete could use to replace or
    /// remove the scope's device-bound value without the authentication its level asks for. Nor for
    /// a repository whose identifier contains `#`, whose secrets would be read back as those of an
    /// environment of another repository.
    @discardableResult
    public func set(
        name: SecretName,
        value: SecretValue,
        scope: SecretScope,
        environment: SecretEnvironment?,
        protectionLevel: ProtectionLevel?,
        isSynchronized: Bool?
    ) async throws -> StoredSecret {
        guard !value.isEmpty else {
            throw SecretStoreError.emptyValue
        }
        guard !scope.isRepositoryNamedLikeASharedScope else {
            throw SecretStoreError.reservedRepositoryIdentifier(repository: scope.description)
        }
        guard !scope.isRepositoryNamedWithAnEnvironmentSeparator else {
            throw SecretStoreError.repositoryIdentifierContainsEnvironmentSeparator(repository: scope.description)
        }
        try checkEnvironmentIsNamed(scope: scope, environment: environment)
        let variants = try keychain.storedSecrets(scope: scope).filter { $0.name == name && $0.environment == environment }
        let existing = Self.effectiveSecrets(storedSecrets: variants).first
        // `standard`: a secret asks for authentication only when the user opted in.
        let targetProtectionLevel = protectionLevel ?? existing?.protectionLevel ?? .standard
        guard !(targetProtectionLevel == .deviceBound && isSynchronized == true) else {
            throw SecretStoreError.deviceBoundCannotSynchronize
        }
        let target = StoredSecret(
            scope: scope,
            name: name,
            environment: environment,
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
        scope: SecretScope,
        environment: SecretEnvironment?,
        protectionLevel: ProtectionLevel,
        isSynchronized: Bool
    ) async throws -> StoredSecret {
        let existing = try existingSecret(name: name, scope: scope, environment: environment)
        guard !(protectionLevel == .deviceBound && isSynchronized) else {
            throw SecretStoreError.deviceBoundCannotSynchronize
        }
        let ownerAuthentication = existing.protectionLevel != .standard
            ? try await ownerAuthenticator.authenticate(
                reason: String(localized: "change the protection of \(name.value)", bundle: authenticationReasonBundle)
            )
            : nil
        let target = StoredSecret(
            scope: scope,
            name: name,
            environment: environment,
            protectionLevel: protectionLevel,
            isSynchronized: isSynchronized,
            modificationDate: nil
        )
        let value = try keychain.value(storedSecret: existing, ownerAuthentication: ownerAuthentication)
        // Same reason as in `set`: a non-effective variant must not collide with the target.
        for variant in try keychain.storedSecrets(scope: scope)
        where variant.name == name && variant.environment == environment && variant.id != existing.id {
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

    /// Deletes every variant of the name in the environment. Authenticates first when the secret is
    /// not `standard`. Deleting a name that does not exist succeeds (idempotent), except without an
    /// environment in a scope that has environments: there, only a secret left without an
    /// environment is deleted, and a name that has none is `environmentRequired`, because the
    /// command most likely meant one of the environments.
    public func delete(name: SecretName, scope: SecretScope, environment: SecretEnvironment?) async throws {
        let variants = try keychain.storedSecrets(scope: scope).filter { $0.name == name && $0.environment == environment }
        if variants.isEmpty {
            try checkEnvironmentIsNamed(scope: scope, environment: environment)
        }
        if variants.contains(where: { $0.protectionLevel != .standard }) {
            _ = try await ownerAuthenticator.authenticate(reason: String(localized: "delete \(name.value)", bundle: authenticationReasonBundle))
        }
        for variant in variants {
            try keychain.delete(storedSecret: variant)
        }
    }

    /// Moves the scope's secrets without an environment to `environment` (`secchain env migrate`):
    /// all of them when `names` is `nil`, otherwise the named ones. Returns the moved secrets as they
    /// are now, empty when there was nothing to move.
    ///
    /// Idempotent: a named secret that already has no variant without an environment but one in
    /// `environment` was moved before and is skipped. A named secret in neither is `secretNotFound`,
    /// and one that `environment` already holds next to a variant without an environment is
    /// `duplicateSecret`, before anything changes, because moving it would overwrite that value.
    ///
    /// Every value is read before anything is written, under one authentication when any of the
    /// secrets is not `standard`: a device-bound value cannot be read without it, so a refused or
    /// failed authentication leaves every secret where it was. Each secret is then written to the
    /// environment before its old items are deleted, the order of a change of synchronization, so
    /// that a failure in between leaves the value in at least one place.
    @discardableResult
    public func moveToEnvironment(
        names: [SecretName]?,
        scope: SecretScope,
        environment: SecretEnvironment
    ) async throws -> [StoredSecret] {
        let allVariants = try keychain.storedSecrets(scope: scope)
        let secretsWithoutEnvironment = Self.effectiveSecrets(storedSecrets: allVariants.filter { $0.environment == nil })
        let movingSecrets = try names.map { names in
            try names.compactMap { name -> StoredSecret? in
                if let storedSecret = secretsWithoutEnvironment.first(where: { $0.name == name }) {
                    return storedSecret
                }
                guard allVariants.contains(where: { $0.name == name && $0.environment == environment }) else {
                    throw SecretStoreError.secretNotFound(name: name.value, repository: scope.description)
                }
                return nil
            }
        } ?? secretsWithoutEnvironment
        let targets = movingSecrets.map { movingSecret in
            StoredSecret(
                scope: scope,
                name: movingSecret.name,
                environment: environment,
                protectionLevel: movingSecret.protectionLevel,
                isSynchronized: movingSecret.isSynchronized,
                modificationDate: nil
            )
        }
        if let occupiedTarget = targets.first(where: { target in
            allVariants.contains { $0.name == target.name && $0.environment == environment }
        }) {
            throw SecretStoreError.duplicateSecret(name: occupiedTarget.name.value, repository: occupiedTarget.locationDescription)
        }
        guard !movingSecrets.isEmpty else {
            return []
        }
        let ownerAuthentication = movingSecrets.contains(where: { $0.protectionLevel != .standard })
            ? try await ownerAuthenticator.authenticate(
                reason: String(localized: "move \(movingSecrets.map(\.name.value).joined(separator: ", ")) to the environment \(environment.value)", bundle: authenticationReasonBundle)
            )
            : nil
        let values = try movingSecrets.map { try keychain.value(storedSecret: $0, ownerAuthentication: ownerAuthentication) }
        for (target, value) in zip(targets, values) {
            try keychain.write(storedSecret: target, value: value, replacing: nil, ownerAuthentication: ownerAuthentication)
            for variant in allVariants where variant.name == target.name && variant.environment == nil {
                try keychain.delete(storedSecret: variant)
            }
        }
        return targets
    }

    // MARK: - Rules

    /// One entry per name and environment. When a local and a synchronized variant of one name
    /// coexist, the local one wins: it was created on this device on purpose, while the
    /// synchronized one may have arrived from another Mac.
    static func effectiveSecrets(storedSecrets: [StoredSecret]) -> [StoredSecret] {
        Dictionary(grouping: storedSecrets, by: { "\($0.keychainService)\u{0}\($0.name.value)" })
            .values
            .compactMap { variants in
                variants.first(where: { !$0.isSynchronized }) ?? variants.first
            }
            .sorted { ($0.keychainService, $0.name) < ($1.keychainService, $1.name) }
    }

    /// The effective secret of the name in the scope and environment. A name the scope does not
    /// hold there is `secretNotFound`, because every caller is about to read or change that secret.
    func existingSecret(name: SecretName, scope: SecretScope, environment: SecretEnvironment?) throws -> StoredSecret {
        guard let existing = try storedSecrets(scope: scope, environment: environment).first(where: { $0.name == name }) else {
            throw Self.notFoundError(name: name, location: scope.description, environment: environment)
        }
        return existing
    }

    /// The error for a name that `location` does not hold in `environment`.
    static func notFoundError(name: SecretName, location: String, environment: SecretEnvironment?) -> SecretStoreError {
        guard let environment else {
            return .secretNotFound(name: name.value, repository: location)
        }
        return .secretNotFoundInEnvironment(name: name.value, repository: location, environment: environment.value)
    }
}
