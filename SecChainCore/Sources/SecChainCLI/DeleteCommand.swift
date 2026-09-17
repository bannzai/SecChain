import ArgumentParser
import Foundation
import SecChainCore

/// `secchain delete <NAME>`: remove a secret from the Keychain and from `.secchain`.
struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a secret from the Keychain. A synchronized secret is deleted on every device."
    )

    @Argument(help: "Secret name.")
    var name: String

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    @OptionGroup
    var remoteApprovalOptions: RemoteApprovalOptions

    func run() async throws {
        let secretName = try validatedSecretName(rawName: name)
        let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
        // Deleting a secret that is not standard authenticates first, on the same route as `run`.
        let setup = try secretStore(
            repositoryIdentity: context.repositoryIdentity,
            requestedSecrets: try SecretStore.system.storedSecrets(repositoryIdentity: context.repositoryIdentity)
                .filter { $0.name == secretName },
            commandArguments: ["delete", secretName.value],
            approveRemotely: remoteApprovalOptions.approveRemotely
        )
        try await withInterruptCancellingWhileWaiting(waitsForARemoteApproval: setup.waitsForARemoteApproval) {
            try await setup.store.delete(name: secretName, repositoryIdentity: context.repositoryIdentity)
        }
        // With --repository the current directory is not that repository's checkout, so its
        // definition file is left alone.
        if repositoryOptions.repository == nil, let definitionText = context.definitionText {
            try SecretDefinitionFile.write(
                text: SecretDefinitionText.removing(secretName: secretName, text: definitionText),
                workingTreeRoot: context.definitionDirectory
            )
        }
        print("Deleted \(secretName.value) from \(context.repositoryIdentity.value).")
    }
}
