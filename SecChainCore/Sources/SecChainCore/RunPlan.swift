import Foundation

/// Why `secchain run` refuses to start the command.
public enum RunPlanError: Error, Equatable, CustomStringConvertible {
    /// The definition file declares secrets that have no stored value. Starting the command
    /// anyway would run it with silently missing variables.
    case declaredSecretsWithoutValue(names: [String])
    /// A secret's bytes are not UTF-8, so it cannot become an environment variable.
    case valueIsNotText(name: String)

    public var description: String {
        switch self {
        case .declaredSecretsWithoutValue(let names):
            ".secchain declares secrets that have no stored value: \(names.joined(separator: ", ")). Store each with 'secchain set <NAME>'."
        case .valueIsNotText(let name):
            "\(name) cannot be passed as an environment variable because its value is not UTF-8 text."
        }
    }
}

/// Pure decisions of `secchain run`: which secrets are handed to the command, and what the
/// command's environment looks like.
public enum RunPlan {
    /// - `onlyNames` not empty: exactly those (the caller reports names that are not stored).
    /// - otherwise: every stored secret of the repository, after checking that everything the
    ///   definition file declares has a value.
    public static func secretNames(
        storedSecretNames: [SecretName],
        definition: SecretDefinition?,
        onlyNames: [SecretName]
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
                throw RunPlanError.declaredSecretsWithoutValue(names: missingSecretNames.map(\.value))
            }
        }
        return storedSecretNames
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
