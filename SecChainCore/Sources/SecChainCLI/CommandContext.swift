import ArgumentParser
import Foundation
import SecChainCore

/// What every command needs to know about where it runs: the repository the secrets belong to,
/// and the definition file next to it.
struct CommandContext {
    /// Repository whose secrets the command acts on.
    let repositoryIdentity: RepositoryIdentity
    /// Directory that holds (or will hold) `.secchain`: the working tree root inside Git,
    /// otherwise the current directory.
    let definitionDirectory: URL
    /// Text of `.secchain`, `nil` when the file does not exist.
    let definitionText: String?
    /// Parsed `definitionText`.
    let definition: SecretDefinition?

    /// `repositoryOption` is the `--repository` flag: it overrides both the definition file and
    /// the Git remote, for acting on a repository from outside its checkout.
    static func resolve(repositoryOption: String?) throws -> CommandContext {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let definitionDirectory = try RepositoryIdentityResolver.workingTreeRoot(directory: currentDirectory) ?? currentDirectory
        let definitionText = try SecretDefinitionFile.readText(workingTreeRoot: definitionDirectory)
        let definition = try definitionText.map(SecretDefinitionText.parse(text:))
        return CommandContext(
            repositoryIdentity: try RepositoryIdentityResolver.resolve(
                directory: currentDirectory,
                declaredIdentifier: repositoryOption ?? definition?.declaredRepositoryIdentifier
            ),
            definitionDirectory: definitionDirectory,
            definitionText: definitionText,
            definition: definition
        )
    }
}

/// Options shared by the commands that act on one repository.
struct RepositoryOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Act on this repository identifier instead of the one derived from the current directory."
    )
    var repository: String?
}

/// Parses a secret name argument, so that an invalid name is reported as a usage error.
func validatedSecretName(rawName: String) throws -> SecretName {
    guard let secretName = SecretName(rawName: rawName) else {
        throw ValidationError("'\(rawName)' is not a valid secret name. Use letters, digits and underscores, not starting with a digit.")
    }
    return secretName
}
