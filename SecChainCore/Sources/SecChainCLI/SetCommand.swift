import ArgumentParser
import Foundation
import SecChainCore

extension ProtectionLevel: ExpressibleByArgument {}

/// `secchain set <NAME>`: add a secret, or update it when the name exists.
struct SetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Store or update a secret. The value is read from a hidden prompt, or from standard input when piped.",
        discussion: """
            The value is never accepted as an argument, so it cannot end up in the shell history or the process list.

            With --scope, the secret goes to a shared scope and its name is declared in that scope of \
            ~/.secchain, which gets the scope if it has none yet. Which repositories receive the scope \
            is decided with 'secchain scope allow'.
            """
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
    var scopeOptions: ScopeOptions

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    @OptionGroup
    var remoteApprovalOptions: RemoteApprovalOptions

    func run() async throws {
        let secretName = try validatedSecretName(rawName: name)
        let scope: SecretScope
        // The definition file that declares the name: the scope's section of `~/.secchain` for a
        // shared scope, the repository's `.secchain` otherwise. It is parsed before the value is
        // read, so that a file this version cannot read stops the command first, and edited as it
        // is once the value is stored, so that a change made to it meanwhile is kept.
        let writeDefinition: () throws -> Void
        if let sharedScope = try scopeOptions.sharedScope(repositoryOption: repositoryOptions.repository) {
            scope = .shared(sharedScope)
            _ = try readUserDefinition()
            writeDefinition = {
                try editUserDefinition { text in
                    try UserDefinitionText.adding(secretName: secretName, scope: sharedScope, text: text)
                }
            }
        } else {
            let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
            scope = .repository(context.repositoryIdentity)
            writeDefinition = {
                // With --repository the current directory is not that repository's checkout, so its
                // definition file is left alone.
                if repositoryOptions.repository == nil, let definitionDirectory = context.definitionDirectory {
                    try SecretDefinitionFile.write(
                        text: try SecretDefinitionText.adding(
                            secretName: secretName,
                            text: try SecretDefinitionFile.readText(workingTreeRoot: definitionDirectory)
                        ),
                        workingTreeRoot: definitionDirectory
                    )
                }
            }
        }
        // Updating a secret that is not standard authenticates first, and that authentication takes
        // the same route as the one of `run`. The name is what the iPhone is shown; the value is
        // read from standard input and never leaves this process.
        let setup = try secretStore(
            scope: scope,
            requestedSecrets: try SecretStore.system.storedSecrets(scope: scope).filter { $0.name == secretName },
            commandArguments: ["set", secretName.value] + scopeArguments(scope: scope),
            approveRemotely: remoteApprovalOptions.approveRemotely
        )
        let value = try SecretInput.read(secretName: secretName)
        let storedSecret = try await withInterruptCancellingWhileWaiting(waitsForARemoteApproval: setup.waitsForARemoteApproval) {
            try await setup.store.set(
                name: secretName,
                value: value,
                scope: scope,
                protectionLevel: level,
                isSynchronized: sync
            )
        }
        try writeDefinition()
        print("Stored \(secretName.value) for \(scope.description) (\(storedSecret.protectionLevel.rawValue), \(storedSecret.isSynchronized ? "synchronized" : "this Mac only")).")
    }
}

/// `--scope <name>` for a shared scope, nothing for a repository's own. Part of the command the
/// paired iPhone is shown, so that the command reads as the one the user typed.
func scopeArguments(scope: SecretScope) -> [String] {
    scope.sharedScope.map { ["--scope", $0.name] } ?? []
}
