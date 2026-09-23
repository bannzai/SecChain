import ArgumentParser
import Foundation
import SecChainCore

/// What every command needs to know about where it runs: the repository the secrets belong to,
/// the definition file next to it, and the user's `~/.secchain`.
struct CommandContext {
    /// Repository whose secrets the command acts on.
    let repositoryIdentity: RepositoryIdentity
    /// Directory that holds (or will hold) `.secchain`: the directory of the `@path` that names the
    /// repository, otherwise the working tree root inside Git, otherwise the current directory.
    let definitionDirectory: URL
    /// Text of `.secchain`, `nil` when the file does not exist.
    let definitionText: String?
    /// Parsed `definitionText`.
    let definition: SecretDefinition?
    /// Parsed `~/.secchain`: the shared scopes, which of them the repository gets, and the
    /// `@alias` / `@path` its identity went through.
    let userDefinition: UserDefinition

    /// `repositoryOption` is the `--repository` flag: it overrides `@path` and the Git remote, for
    /// acting on a repository from outside its checkout.
    static func resolve(repositoryOption: String?) throws -> CommandContext {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let userDefinition = try readUserDefinition().definition
        let definitionDirectory = try userDefinition.pathRepository(directory: currentDirectory)?.directory
            ?? RepositoryIdentityResolver.workingTreeRoot(directory: currentDirectory)
            ?? currentDirectory
        let definitionText = try SecretDefinitionFile.readText(workingTreeRoot: definitionDirectory)
        return CommandContext(
            repositoryIdentity: try RepositoryIdentityResolver.resolve(
                directory: currentDirectory,
                explicitIdentifier: repositoryOption,
                userDefinition: userDefinition
            ),
            definitionDirectory: definitionDirectory,
            definitionText: definitionText,
            definition: try definitionText.map(SecretDefinitionText.parse(text:)),
            userDefinition: userDefinition
        )
    }
}

/// `~/.secchain` as text, `nil` when the file does not exist, together with what it declares.
func readUserDefinition() throws -> (text: String?, definition: UserDefinition) {
    let text = try UserDefinitionFile.readText(homeDirectory: UserDefinitionFile.homeDirectory)
    return (text, try UserDefinitionText.parse(text: text ?? ""))
}

/// Options shared by the commands that act on one repository.
struct RepositoryOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Act on this repository identifier instead of the one derived from the current directory."
    )
    var repository: String?
}

/// Options of the commands that act on one scope.
struct ScopeOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Act on this scope: 'user', a custom scope of ~/.secchain, or 'repository', the current repository's own secrets (the default)."
    )
    var scope: String?

    /// The shared scope `--scope` names, `nil` for the repository scope (`--scope repository`, or
    /// no `--scope`). `--repository` picks a repository scope, so it cannot go with a shared one.
    func sharedScope(repositoryOption: String?) throws -> SharedScope? {
        guard let scope, scope != SecretScope.repositoryScopeName else {
            return nil
        }
        guard repositoryOption == nil else {
            throw ValidationError("--repository picks a repository's own secrets, so it cannot be combined with --scope \(scope).")
        }
        return try validatedSharedScope(rawName: scope)
    }
}

/// Parses a secret name argument, so that an invalid name is reported as a usage error.
func validatedSecretName(rawName: String) throws -> SecretName {
    guard let secretName = SecretName(rawName: rawName) else {
        throw ValidationError("'\(rawName)' is not a valid secret name. Use letters, digits and underscores, not starting with a digit.")
    }
    return secretName
}

/// Parses the name of a shared scope, so that an invalid one is reported as a usage error.
func validatedSharedScope(rawName: String) throws -> SharedScope {
    guard rawName != SecretScope.repositoryScopeName else {
        throw ValidationError("'repository' is every repository's own scope, which is always passed to its repository. Name the user scope or a custom scope.")
    }
    guard let sharedScope = SharedScope(name: rawName) else {
        throw ValidationError("'\(rawName)' is not a scope name. Use lowercase letters, digits and hyphens, starting with a letter or a digit.")
    }
    return sharedScope
}
