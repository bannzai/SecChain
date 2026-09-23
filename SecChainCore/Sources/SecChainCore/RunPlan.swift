import Foundation

/// Why `secchain run` refuses to start the command.
public enum RunPlanError: Error, Equatable, CustomStringConvertible {
    /// The definition file declares secrets that no scope passed to the repository holds. Starting
    /// the command anyway would run it with silently missing variables. `sharedScopeNamesBySecretName`
    /// names, for such a secret, the shared scopes that hold or declare it but are not allowed for
    /// the repository, because allowing one of them is the fix then rather than storing a value.
    case declaredSecretsWithoutValue(names: [String], repository: String, sharedScopeNamesBySecretName: [String: [String]])
    /// A secret's bytes are not UTF-8, so it cannot become an environment variable.
    case valueIsNotText(name: String)

    public var description: String {
        switch self {
        case .declaredSecretsWithoutValue(let names, let repository, let sharedScopeNamesBySecretName):
            let namesToStore = names.filter { sharedScopeNamesBySecretName[$0] == nil }
            return (
                (namesToStore.isEmpty ? [] : [".secchain declares secrets that have no stored value: \(namesToStore.joined(separator: ", ")). Store each with 'secchain set <NAME>'."])
                    + names.compactMap { name in
                        sharedScopeNamesBySecretName[name].map { scopeNames in
                            scopeNames.count == 1
                                ? ".secchain declares \(name), which is in scope \(scopeNames[0]), not allowed for \(repository). Allow it with 'secchain scope allow \(scopeNames[0]) \(repository)'."
                                : ".secchain declares \(name), which is in scopes \(scopeNames.joined(separator: ", ")), none of them allowed for \(repository). Allow one with 'secchain scope allow <scope> \(repository)'."
                        }
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
    /// - `onlyNames` not empty: exactly those (the caller reports names that are not stored).
    /// - otherwise: every stored secret of the scopes passed to the repository, after checking that
    ///   everything the definition file declares has a value.
    ///
    /// `secretNamesOfScopesNotPassed` gives the names each shared scope that is not passed to the
    /// repository holds or declares. It is asked only when a declared name has no value, because
    /// finding out lists every scope of the Keychain.
    public static func secretNames(
        storedSecretNames: [SecretName],
        definition: SecretDefinition?,
        onlyNames: [SecretName],
        repositoryIdentity: RepositoryIdentity,
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
    /// and the shared scopes the requested secrets come from, in the order of `passedScopes`.
    public static func authenticationReason(
        executable: String,
        repositoryIdentity: RepositoryIdentity,
        passedScopes: [SecretScope],
        requestedSecrets: [StoredSecret]
    ) -> String {
        let sharedScopeNames = passedScopes
            .filter { passedScope in requestedSecrets.contains { $0.scope == passedScope } }
            .compactMap(\.sharedScope?.name)
        guard !sharedScopeNames.isEmpty else {
            return "run \(executable) with secrets of \(repositoryIdentity.value)"
        }
        return "run \(executable) with secrets of \(repositoryIdentity.value) and of the \(sharedScopeNames.joined(separator: ", ")) \(sharedScopeNames.count == 1 ? "scope" : "scopes")"
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
