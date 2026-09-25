import ArgumentParser
import Foundation
import SecChainCore

/// `secchain delete <NAME>`: remove a secret from the Keychain and from the definition file that
/// declares it.
struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a secret from the Keychain. A synchronized secret is deleted on every device.",
        discussion: """
            With --env, only the value of that environment is deleted. Without --env in a scope that \
            has environments, the secret of that name left without an environment is deleted, and \
            the command fails when there is none. The name stays declared in the definition file \
            while any environment still holds it.
            """
    )

    @Argument(help: "Secret name.")
    var name: String

    @OptionGroup
    var scopeOptions: ScopeOptions

    @OptionGroup
    var environmentOptions: EnvironmentOptions

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    @OptionGroup
    var remoteApprovalOptions: RemoteApprovalOptions

    func run() async throws {
        let secretName = try validatedSecretName(rawName: name)
        let environment = try environmentOptions.validatedEnvironment()
        let scope: SecretScope
        // The definition file that declares the name: the scope's section of `~/.secchain` for a
        // shared scope, the repository's `.secchain` otherwise. It is parsed before the Keychain is
        // touched, so that a file this version cannot read stops the command first, and edited as
        // it is once the secret is deleted, so that a change made to it meanwhile is kept. The name
        // stays declared while another environment of the scope holds it.
        let writeDefinition: () throws -> Void
        if let sharedScope = try scopeOptions.sharedScope(repositoryOption: repositoryOptions.repository) {
            scope = .shared(sharedScope)
            _ = try readUserDefinition()
            writeDefinition = {
                try editUserDefinition { text in
                    try text.map { try UserDefinitionText.removing(secretName: secretName, scope: sharedScope, text: $0) }
                }
            }
        } else {
            let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
            scope = .repository(context.repositoryIdentity)
            writeDefinition = {
                // With --repository the current directory is not that repository's checkout, so its
                // definition file is left alone.
                if repositoryOptions.repository == nil,
                    let definitionDirectory = context.definitionDirectory,
                    let definitionText = try SecretDefinitionFile.readText(workingTreeRoot: definitionDirectory)
                {
                    try SecretDefinitionFile.write(
                        text: SecretDefinitionText.removing(secretName: secretName, text: definitionText),
                        workingTreeRoot: definitionDirectory
                    )
                }
            }
        }
        // Deleting a secret that is not standard authenticates first, on the same route as `run`.
        let setup = try secretStore(
            scope: scope,
            requestedSecrets: try SecretStore.system.storedSecrets(scope: scope, environment: environment).filter { $0.name == secretName },
            commandArguments: ["delete", secretName.value] + scopeArguments(scope: scope) + environmentArguments(environment: environment),
            approveRemotely: remoteApprovalOptions.approveRemotely
        )
        try await withInterruptCancellingWhileWaiting(waitsForARemoteApproval: setup.waitsForARemoteApproval) {
            try await setup.store.delete(name: secretName, scope: scope, environment: environment)
        }
        if try !SecretStore.system.storedSecrets(scope: scope).contains(where: { $0.name == secretName }) {
            try writeDefinition()
        }
        print("Deleted \(secretName.value) from \(scope.locationDescription(environment: environment)).")
    }
}
