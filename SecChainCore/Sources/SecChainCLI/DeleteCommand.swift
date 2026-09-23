import ArgumentParser
import Foundation
import SecChainCore

/// `secchain delete <NAME>`: remove a secret from the Keychain and from the definition file that
/// declares it.
struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a secret from the Keychain. A synchronized secret is deleted on every device."
    )

    @Argument(help: "Secret name.")
    var name: String

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
        // shared scope, the repository's `.secchain` otherwise. The new text is computed before the
        // Keychain is touched, so that a file this version cannot parse stops the command first.
        let writeDefinition: () throws -> Void
        if let sharedScope = try scopeOptions.sharedScope(repositoryOption: repositoryOptions.repository) {
            scope = .shared(sharedScope)
            let userDefinitionText = try readUserDefinition().text.map { text in
                try UserDefinitionText.removing(secretName: secretName, scope: sharedScope, text: text)
            }
            writeDefinition = {
                if let userDefinitionText {
                    try UserDefinitionFile.write(text: userDefinitionText, homeDirectory: UserDefinitionFile.homeDirectory)
                }
            }
        } else {
            let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
            scope = .repository(context.repositoryIdentity)
            writeDefinition = {
                // With --repository the current directory is not that repository's checkout, so its
                // definition file is left alone.
                if repositoryOptions.repository == nil, let definitionText = context.definitionText {
                    try SecretDefinitionFile.write(
                        text: SecretDefinitionText.removing(secretName: secretName, text: definitionText),
                        workingTreeRoot: context.definitionDirectory
                    )
                }
            }
        }
        // Deleting a secret that is not standard authenticates first, on the same route as `run`.
        let setup = try secretStore(
            scope: scope,
            requestedSecrets: try SecretStore.system.storedSecrets(scope: scope).filter { $0.name == secretName },
            commandArguments: ["delete", secretName.value] + scopeArguments(scope: scope),
            approveRemotely: remoteApprovalOptions.approveRemotely
        )
        try await withInterruptCancellingWhileWaiting(waitsForARemoteApproval: setup.waitsForARemoteApproval) {
            try await setup.store.delete(name: secretName, scope: scope)
        }
        try writeDefinition()
        print("Deleted \(secretName.value) from \(scope.description).")
    }
}
