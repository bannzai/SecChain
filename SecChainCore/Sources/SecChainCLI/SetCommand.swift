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

            With --env, the value is the one of that environment, such as local or prod. Once a \
            scope has an environment, every secret stored in it needs --env, and 'secchain run' \
            needs --env in the repositories the scope is passed to. Giving a scope its first \
            environment while it holds secrets without one warns which of them 'secchain run' stops \
            passing, and how to move them ('secchain env migrate').
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
        // Refused before the value is typed: a value stored without an environment in a scope that
        // has environments would never be passed by `run`.
        try SecretStore.system.checkEnvironmentIsNamed(scope: scope, environment: environment)
        if let environment {
            try warnAboutSecretsWithoutEnvironment(scope: scope, environment: environment, remainingSecretNames: nil)
        }
        // Updating a secret that is not standard authenticates first, and that authentication takes
        // the same route as the one of `run`. The name is what the iPhone is shown; the value is
        // read from standard input and never leaves this process.
        let setup = try secretStore(
            scope: scope,
            requestedSecrets: try SecretStore.system.storedSecrets(scope: scope, environment: environment).filter { $0.name == secretName },
            commandArguments: ["set", secretName.value] + scopeArguments(scope: scope) + environmentArguments(environment: environment),
            approveRemotely: remoteApprovalOptions.approveRemotely
        )
        let value = try SecretInput.read(secretName: secretName)
        let storedSecret = try await withInterruptCancellingWhileWaiting(waitsForARemoteApproval: setup.waitsForARemoteApproval) {
            try await setup.store.set(
                name: secretName,
                value: value,
                scope: scope,
                environment: environment,
                protectionLevel: level,
                isSynchronized: sync
            )
        }
        try writeDefinition()
        print("Stored \(secretName.value) for \(storedSecret.locationDescription) (\(storedSecret.protectionLevel.rawValue), \(storedSecret.isSynchronized ? "synchronized" : "this Mac only")).")
    }
}

/// `--scope <name>` for a shared scope, nothing for a repository's own. Part of the command the
/// paired iPhone is shown, so that the command reads as the one the user typed.
func scopeArguments(scope: SecretScope) -> [String] {
    scope.sharedScope.map { ["--scope", $0.name] } ?? []
}

/// `--env <environment>`, nothing without an environment. Part of the command the paired iPhone is
/// shown, for the reason of `scopeArguments`.
func environmentArguments(environment: SecretEnvironment?) -> [String] {
    environment.map { ["--env", $0.value] } ?? []
}

/// Writes `environmentWarningLines` to standard error before an operation that stores secrets of
/// `environment` in `scope` (`set --env`, `env migrate` of named secrets). `remainingSecretNames` are
/// the secrets without an environment that the operation leaves, `nil` for all of the scope's.
///
/// The warning comes when the operation gives the scope its first environment, and, for
/// `env migrate` of named secrets, whenever secrets without one remain. The operation goes on
/// afterwards: a command run without a terminal is not stopped by a question nobody answers.
func warnAboutSecretsWithoutEnvironment(scope: SecretScope, environment: SecretEnvironment, remainingSecretNames: [SecretName]?) throws {
    let isFirstEnvironment = try SecretStore.system.environments(scope: scope).isEmpty
    guard isFirstEnvironment || remainingSecretNames != nil else {
        return
    }
    for line in environmentWarningLines(
        scope: scope,
        environment: environment,
        isFirstEnvironment: isFirstEnvironment,
        secretNamesWithoutEnvironment: try remainingSecretNames ?? SecretStore.system.storedSecrets(scope: scope, environment: nil).map(\.name)
    ) {
        reportToStandardError(line: "warning: \(line)")
    }
}
