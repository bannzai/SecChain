import ArgumentParser
import Foundation
import SecChainCore

extension ProtectionLevel: ExpressibleByArgument {}

/// `secchain set <NAME>`: add a secret, or update it when the name exists.
struct SetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Store or update a secret. The value is read from a hidden prompt, from standard input when piped, or from an environment variable with --from-variable.",
        discussion: """
            The value is never accepted as an argument, so it cannot end up in the shell history or the process list.

            Updating a secret that already has a value asks for authentication (Touch ID, the \
            password, or the paired iPhone), whatever its protection level. Storing a new one does not.

            With --from-variable, the value is the one of an environment variable this command \
            received: the one named like the secret, or the VARIABLE given. It moves a value that the \
            shell or direnv already exported into the Keychain without typing or piping it again.

            With --scope, the secret goes to a shared scope and its name is declared in that scope of \
            ~/.secchain, which gets the scope if it has none yet. Which repositories receive the scope \
            is decided with 'secchain scope allow'.

            With --env, the value is the one of that environment, such as local or prod. Once a \
            scope has an environment, every secret stored in it needs --env, and 'secchain run' \
            needs --env in the repositories the scope is passed to. Giving a scope its first \
            environment while it holds secrets without one warns which of them 'secchain run' stops \
            passing, and how to move them ('secchain env migrate').

            With --note, the secret gets a note, such as what it is for. A note is not a secret: it \
            synchronizes with the secret, and every app and 'secchain list --long' show it, so never \
            put a value in it. Without --note the secret keeps the note it has; 'secchain note' \
            changes or removes a note without storing a new value.
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

    /// What `--from-variable` holds when no variable follows it: the variable named like the secret.
    /// Not a valid variable name, so that it is never mistaken for one that was typed.
    static let variableNamedLikeTheSecret = "<NAME>"

    @Option(
        name: .customLong("from-variable"),
        defaultAsFlag: SetCommand.variableNamedLikeTheSecret,
        // `.next` rather than the default `.scanningForValue`, which reads ahead past the options
        // that follow for a value to take.
        parsing: .next,
        help: ArgumentHelp(
            "Read the value from an environment variable of this command: the one named like the secret, or VARIABLE. Neither the prompt nor standard input is read.",
            valueName: "VARIABLE"
        )
    )
    var fromVariable: String?

    @Option(
        name: .long,
        help: "A note about the secret, such as what it is for: one line without tabs, never a value. Keeps the current note when omitted."
    )
    var note: String?

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
        // Updating a secret authenticates first, whatever its level, and that authentication takes
        // the same route as the one of `run`. The name is what the iPhone is shown; the value is
        // read from standard input or the environment and never leaves this process.
        let setup = try secretStore(
            scope: scope,
            requestedSecrets: try SecretStore.system.storedSecrets(scope: scope, environment: environment).filter { $0.name == secretName },
            authenticatesEveryLevel: true,
            commandArguments: ["set", secretName.value]
                + scopeArguments(scope: scope)
                + environmentArguments(environment: environment)
                + (valueVariableName(secretName: secretName).map { ["--from-variable", $0] } ?? [])
                + (note.map { ["--note", $0] } ?? []),
            approveRemotely: remoteApprovalOptions.approveRemotely
        )
        let value = try secretValue(secretName: secretName, environment: ProcessInfo.processInfo.environment)
        let storedSecret = try await withInterruptCancellingWhileWaiting(waitsForARemoteApproval: setup.waitsForARemoteApproval) {
            try await setup.store.set(
                name: secretName,
                value: value,
                scope: scope,
                environment: environment,
                protectionLevel: level,
                isSynchronized: sync,
                note: note.flatMap(SecretNote.init(rawNote:))
            )
        }
        try writeDefinition()
        writeToStandardOutput(line: "Stored \(secretName.value) for \(storedSecret.locationDescription) (\(storedSecret.protectionLevel.rawValue), \(storedSecret.isSynchronized ? "synchronized" : "this Mac only")).")
    }

    /// Refuses a `--from-variable` name that is not a variable name before anything else runs, and
    /// without repeating it: what was typed there may be the value itself, and the command is what
    /// the paired iPhone is shown. A `--note` that no note can be is refused before a value is read,
    /// so that nobody types a value for a command that then fails.
    func validate() throws {
        if let fromVariable, fromVariable != Self.variableNamedLikeTheSecret, !isValidSecretName(name: fromVariable) {
            throw ValidationError("The name given to --from-variable is not an environment variable name. Use letters, digits and underscores, not starting with a digit.")
        }
        if let note, !isValidSecretNote(note: note) {
            throw ValidationError(invalidNoteMessage)
        }
    }

    /// The environment variable that `--from-variable` reads, `nil` without the option.
    func valueVariableName(secretName: SecretName) -> String? {
        fromVariable.map { $0 == Self.variableNamedLikeTheSecret ? secretName.value : $0 }
    }

    /// The value to store: the one of the variable `--from-variable` names in `environment`, and
    /// otherwise the one typed at the hidden prompt or piped to standard input.
    func secretValue(secretName: SecretName, environment: [String: String]) throws -> SecretValue {
        guard let variableName = valueVariableName(secretName: secretName) else {
            return try SecretInput.read(secretName: secretName)
        }
        return try SecretInput.readFromVariable(variableName: variableName, environment: environment)
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
