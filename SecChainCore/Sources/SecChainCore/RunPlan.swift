import Foundation

/// Why `secchain run` refuses to start the command.
public enum RunPlanError: Error, Equatable, CustomStringConvertible {
    /// The definition file declares secrets that no scope passed to the repository holds (in
    /// `environment`, when one was named). Starting the command anyway would run it with silently
    /// missing variables. `sharedScopeNamesBySecretName` names, for such a secret, the shared scopes
    /// that hold or declare it but are not allowed for the repository, because allowing one of them
    /// is the fix then rather than storing a value.
    case declaredSecretsWithoutValue(names: [String], repository: String, environment: String?, sharedScopeNamesBySecretName: [String: [String]])
    /// A passed scope has environments and no environment was named, so which of their values the
    /// command should get is unknown (documents/PROJECT.md, "Environments"). `scopesWithEnvironments`
    /// are those scopes in order of precedence, `environments` every environment they have, and
    /// `secretNamesWithoutEnvironmentByScope` the secrets they still hold without one, which no
    /// environment passes.
    case environmentRequired(scopesWithEnvironments: [SecretScope], environments: [String], secretNamesWithoutEnvironmentByScope: [SecretScope: [String]])
    /// A secret's bytes are not UTF-8, so it cannot become an environment variable.
    case valueIsNotText(name: String)

    public var description: String {
        switch self {
        case .declaredSecretsWithoutValue(let names, let repository, let environment, let sharedScopeNamesBySecretName):
            let namesToStore = names.filter { sharedScopeNamesBySecretName[$0] == nil }
            let storeLine = environment.map {
                ".secchain declares secrets that have no stored value in the environment \($0): \(namesToStore.joined(separator: ", ")). Store each with 'secchain set <NAME> --env \($0)'."
            } ?? ".secchain declares secrets that have no stored value: \(namesToStore.joined(separator: ", ")). Store each with 'secchain set <NAME>'."
            return (
                (namesToStore.isEmpty ? [] : [storeLine])
                    + names.compactMap { name in
                        sharedScopeNamesBySecretName[name].map { scopeNames in
                            scopeNames.count == 1
                                ? ".secchain declares \(name), which is in scope \(scopeNames[0]), not allowed for \(repository). Allow it with 'secchain scope allow \(scopeNames[0]) \(repository)'."
                                : ".secchain declares \(name), which is in scopes \(scopeNames.joined(separator: ", ")), none of them allowed for \(repository). Allow one with 'secchain scope allow <scope> \(repository)'."
                        }
                    }
            )
            .joined(separator: "\n")
        case .environmentRequired(let scopesWithEnvironments, let environments, let secretNamesWithoutEnvironmentByScope):
            return (
                ["\(scopesWithEnvironments.map(\.description).joined(separator: ", ")) \(scopesWithEnvironments.count == 1 ? "has" : "have") the environments \(environments.joined(separator: ", ")), so name the one to run with: secchain run --env <environment> -- <command>"]
                    + scopesWithEnvironments.flatMap { scope in
                        secretNamesWithoutEnvironmentByScope[scope].map { secretNames in
                            ["These secrets of \(scope.description) have no environment, and 'secchain run' does not pass them: \(secretNames.joined(separator: ", "))."]
                                + environmentHowToLines(scope: scope)
                        } ?? []
                    }
            )
            .joined(separator: "\n")
        case .valueIsNotText(let name):
            return "\(name) cannot be passed as an environment variable because its value is not UTF-8 text."
        }
    }
}

/// Pure decisions of `secchain run`: which secrets are handed to the command, and what the
/// command's environment looks like.
public enum RunPlan {
    /// The secrets that each passed scope offers in `environment`, before a name held by several
    /// scopes is decided: a scope with environments offers the secrets of `environment`, a scope
    /// without any offers its secrets without an environment. A scope with environments never falls
    /// back to its secrets without one or to those of another environment: a value meant for one
    /// deployment target must not silently reach another (documents/PROJECT.md, design decision 7).
    ///
    /// `storedSecrets` are the effective secrets of the passed scopes in every environment. Without
    /// an environment, a scope with environments is `RunPlanError.environmentRequired`.
    public static func offeredSecrets(
        storedSecrets: [StoredSecret],
        passedScopes: [SecretScope],
        environment: SecretEnvironment?
    ) throws -> [StoredSecret] {
        let scopesWithEnvironments = passedScopes.filter { passedScope in
            storedSecrets.contains { $0.scope == passedScope && $0.environment != nil }
        }
        guard environment != nil || scopesWithEnvironments.isEmpty else {
            throw RunPlanError.environmentRequired(
                scopesWithEnvironments: scopesWithEnvironments,
                environments: Set(storedSecrets.compactMap(\.environment)).sorted().map(\.value),
                secretNamesWithoutEnvironmentByScope: Dictionary(
                    uniqueKeysWithValues: scopesWithEnvironments.compactMap { scope in
                        let secretNames = storedSecrets.filter { $0.scope == scope && $0.environment == nil }.map(\.name.value).sorted()
                        return secretNames.isEmpty ? nil : (scope, secretNames)
                    }
                )
            )
        }
        return passedScopes.flatMap { passedScope in
            storedSecrets.filter { storedSecret in
                storedSecret.scope == passedScope
                    && storedSecret.environment == (scopesWithEnvironments.contains(passedScope) ? environment : nil)
            }
        }
    }

    /// The secrets a command gets when `passedScopes` are passed to it in `environment`, one per
    /// name, sorted by name. `passedScopes` is in order of precedence: a name that several of them
    /// offer (`offeredSecrets`) is taken from the first, in every environment alike.
    public static func passedSecrets(
        storedSecrets: [StoredSecret],
        passedScopes: [SecretScope],
        environment: SecretEnvironment?
    ) throws -> [StoredSecret] {
        var takenNames = Set<SecretName>()
        return try offeredSecrets(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: environment)
            .filter { takenNames.insert($0.name).inserted }
            .sorted { $0.name < $1.name }
    }

    /// - `onlyNames` not empty: exactly those (the caller reports names that are not stored).
    /// - otherwise: every stored secret of the scopes passed to the repository, after checking that
    ///   everything the definition file declares has a value. `environment` is the one the
    ///   secrets were chosen for, which the error names.
    ///
    /// `secretNamesOfScopesNotPassed` gives the names each shared scope that is not passed to the
    /// repository holds or declares. It is asked only when a declared name has no value, because
    /// finding out lists every scope of the Keychain.
    public static func secretNames(
        storedSecretNames: [SecretName],
        definition: SecretDefinition?,
        onlyNames: [SecretName],
        repositoryIdentity: RepositoryIdentity,
        environment: SecretEnvironment?,
        secretNamesOfScopesNotPassed: () throws -> [SharedScope: Set<SecretName>]
    ) throws -> [SecretName] {
        guard onlyNames.isEmpty else {
            return onlyNames
        }
        if let definition {
            let missingSecretNames = SecretDefinitionText.missingSecretNames(
                definition: definition,
                storedSecretNames: Set(storedSecretNames)
            )
            guard missingSecretNames.isEmpty else {
                let secretNamesByScopeNotPassed = try secretNamesOfScopesNotPassed()
                throw RunPlanError.declaredSecretsWithoutValue(
                    names: missingSecretNames.map(\.value),
                    repository: repositoryIdentity.value,
                    environment: environment?.value,
                    sharedScopeNamesBySecretName: Dictionary(
                        uniqueKeysWithValues: missingSecretNames.compactMap { missingSecretName in
                            let scopeNames = secretNamesByScopeNotPassed
                                .filter { $0.value.contains(missingSecretName) }
                                .map(\.key.name)
                                .sorted()
                            return scopeNames.isEmpty ? nil : (missingSecretName.value, scopeNames)
                        }
                    )
                )
            }
        }
        return storedSecretNames
    }

    /// What the authentication prompt of a run says the command is about to get: the repository,
    /// the shared scopes the requested secrets come from, in the order of `passedScopes`, and the
    /// environment, when one was named.
    public static func authenticationReason(
        executable: String,
        repositoryIdentity: RepositoryIdentity,
        passedScopes: [SecretScope],
        environment: SecretEnvironment?,
        requestedSecrets: [StoredSecret]
    ) -> String {
        let sharedScopeNames = passedScopes
            .filter { passedScope in requestedSecrets.contains { $0.scope == passedScope } }
            .compactMap(\.sharedScope?.name)
        let environmentSuffix = environment.map { " in the environment \($0.value)" } ?? ""
        guard !sharedScopeNames.isEmpty else {
            return "run \(executable) with secrets of \(repositoryIdentity.value)\(environmentSuffix)"
        }
        return "run \(executable) with secrets of \(repositoryIdentity.value) and of the \(sharedScopeNames.joined(separator: ", ")) \(sharedScopeNames.count == 1 ? "scope" : "scopes")\(environmentSuffix)"
    }

    /// The parent environment with the secrets added. A secret overrides an inherited variable of
    /// the same name: the point of `run` is that the stored value is the one the command sees.
    public static func childEnvironment(
        inheritedEnvironment: [String: String],
        values: [SecretName: SecretValue]
    ) throws -> [String: String] {
        try values.reduce(into: inheritedEnvironment) { environment, entry in
            guard let text = entry.value.exposedString else {
                throw RunPlanError.valueIsNotText(name: entry.key.value)
            }
            environment[entry.key.value] = text
        }
    }
}
