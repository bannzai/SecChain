/// The ways out of a scope whose secrets are partly without an environment, as the command-line
/// tool prints them (documents/PROJECT.md, "Environments"). `scope` decides whether the commands
/// carry `--scope`, so that each line can be run as it is.
public func environmentHowToLines(scope: SecretScope) -> [String] {
    let scopeArguments = scope.sharedScope.map { " --scope \($0.name)" } ?? ""
    return [
        "To move all of them to one environment: secchain env migrate local\(scopeArguments) (any name works; 'local' is an example).",
        "To move them one at a time: secchain env migrate <environment> <NAME>\(scopeArguments)",
        "Where a value differs between environments, move it, then store the value of each other environment: secchain set <NAME> --env <environment>\(scopeArguments)",
    ]
}

/// The warning printed before an operation leaves secrets of `scope` without an environment next to
/// secrets of `environment`: those secrets are no longer passed by `run`, which nothing else would
/// tell the user. `isFirstEnvironment` says that the operation gives the scope its first environment,
/// which is when `run` and `set` start needing `--env`. Empty when no secret stays without an
/// environment.
public func environmentWarningLines(
    scope: SecretScope,
    environment: SecretEnvironment,
    isFirstEnvironment: Bool,
    secretNamesWithoutEnvironment: [SecretName]
) -> [String] {
    guard !secretNamesWithoutEnvironment.isEmpty else {
        return []
    }
    let firstEnvironmentLines = isFirstEnvironment
        ? [
            "\(environment.value) is the first environment of \(scope.description).",
            scope.sharedScope.map {
                "From now on 'secchain set --scope \($0.name)' needs --env <environment>, and so does 'secchain run' in every repository that scope \($0.name) is passed to."
            } ?? "From now on 'secchain run' and 'secchain set' need --env <environment> in \(scope.description).",
        ]
        : []
    return firstEnvironmentLines
        + ["These secrets of \(scope.description) have no environment, and 'secchain run' does not pass them: \(secretNamesWithoutEnvironment.map(\.value).joined(separator: ", "))."]
        + environmentHowToLines(scope: scope)
}
