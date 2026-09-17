import ArgumentParser
import Foundation
import SecChainCore

extension ProtectionLevel: ExpressibleByArgument {}

/// `secchain set <NAME>`: add a secret, or update it when the name exists.
struct SetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Store or update a secret. The value is read from a hidden prompt, or from standard input when piped.",
        discussion: "The value is never accepted as an argument, so it cannot end up in the shell history or the process list."
    )

    @Argument(help: "Secret name. It is also the environment variable name used by 'secchain run'.")
    var name: String

    @Option(
        name: .long,
        help: "Protection level: standard (no prompt), confirm (authenticate on every run), device-bound (enforced by the Keychain, never synchronized). Keeps the current level when omitted."
    )
    var level: ProtectionLevel?

    @Flag(
        inversion: .prefixedNo,
        help: "Synchronize through iCloud Keychain, or keep the secret on this Mac only. Keeps the current setting when omitted; a new secret synchronizes."
    )
    var sync: Bool?

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    func run() async throws {
        let secretName = try validatedSecretName(rawName: name)
        let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
        let storedSecret = try await SecretStore.system.set(
            name: secretName,
            value: try SecretInput.read(secretName: secretName),
            repositoryIdentity: context.repositoryIdentity,
            protectionLevel: level,
            isSynchronized: sync
        )
        // With --repository the current directory is not that repository's checkout, so its
        // definition file is left alone.
        if repositoryOptions.repository == nil {
            try SecretDefinitionFile.write(
                text: try SecretDefinitionText.adding(secretName: secretName, text: context.definitionText),
                workingTreeRoot: context.definitionDirectory
            )
        }
        print("Stored \(secretName.value) for \(context.repositoryIdentity.value) (\(storedSecret.protectionLevel.rawValue), \(storedSecret.isSynchronized ? "synchronized" : "this Mac only")).")
    }
}
