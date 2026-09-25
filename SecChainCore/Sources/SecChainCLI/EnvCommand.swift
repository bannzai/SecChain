import ArgumentParser
import Foundation
import SecChainCore

/// `secchain env`: the environments of a scope's secrets (documents/PROJECT.md, "Environments").
struct EnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Manage the environments of secrets, such as local and prod.",
        discussion: """
            A secret stored with 'secchain set <NAME> --env <environment>' holds the value of that \
            environment, under the same name. A scope that has an environment gives 'secchain run' \
            only the secrets of the environment named with --env. 'secchain list --envs' shows the \
            environments of each scope.
            """,
        subcommands: [EnvMigrateCommand.self]
    )
}

/// `secchain env migrate <environment> [NAME]`: move secrets without an environment into one.
struct EnvMigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Move the secrets of a scope that have no environment to an environment.",
        discussion: """
            Without a name, every secret of the scope that has no environment moves; with one, only \
            that secret. The value, the protection level, and the synchronization stay as they are. \
            A secret that is not 'standard' asks for authentication first, once for the whole \
            command. A secret that the environment already holds is not overwritten: the command \
            fails before anything moves. With nothing left to move, the command does nothing.
            """
    )

    @Argument(help: "The environment to move the secrets to, such as local.")
    var environment: String

    @Argument(help: "Move only this secret.")
    var name: String?

    @OptionGroup
    var scopeOptions: ScopeOptions

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    @OptionGroup
    var remoteApprovalOptions: RemoteApprovalOptions

    func run() async throws {
        let secretEnvironment = try validatedEnvironment(rawName: environment)
        let secretNames = try name.map { [try validatedSecretName(rawName: $0)] }
        let scope: SecretScope = try scopeOptions.sharedScope(repositoryOption: repositoryOptions.repository).map(SecretScope.shared)
            ?? .repository(try CommandContext.resolve(repositoryOption: repositoryOptions.repository).repositoryIdentity)
        let secretsWithoutEnvironment = try SecretStore.system.storedSecrets(scope: scope, environment: nil)
        let movingSecrets = secretNames.map { secretNames in secretsWithoutEnvironment.filter { secretNames.contains($0.name) } }
            ?? secretsWithoutEnvironment
        // Moving every secret leaves none behind, so only moving named ones can warn.
        if secretNames != nil, !movingSecrets.isEmpty {
            try warnAboutSecretsWithoutEnvironment(
                scope: scope,
                environment: secretEnvironment,
                remainingSecretNames: secretsWithoutEnvironment.filter { !movingSecrets.contains($0) }.map(\.name)
            )
        }
        // Moving a secret that is not standard reads its value and deletes it, so it authenticates
        // on the same route as `run`.
        let setup = try secretStore(
            scope: scope,
            requestedSecrets: movingSecrets,
            commandArguments: ["env", "migrate", secretEnvironment.value] + (secretNames?.map(\.value) ?? []) + scopeArguments(scope: scope),
            approveRemotely: remoteApprovalOptions.approveRemotely
        )
        let movedSecrets = try await withInterruptCancellingWhileWaiting(waitsForARemoteApproval: setup.waitsForARemoteApproval) {
            try await setup.store.moveToEnvironment(names: secretNames, scope: scope, environment: secretEnvironment)
        }
        guard !movedSecrets.isEmpty else {
            print("Nothing to move: \(secretNames.map { "\($0.map(\.value).joined(separator: ", ")) of " } ?? "")\(scope.description) has no secret without an environment.")
            return
        }
        print("Moved \(movedSecrets.map(\.name.value).joined(separator: ", ")) of \(scope.description) to the environment \(secretEnvironment.value).")
    }
}
