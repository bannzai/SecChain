import ArgumentParser
import Foundation
import SecChainCore

/// `secchain run -- <command>`: run a command with the repository's secrets in its environment.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with this repository's secrets as environment variables.",
        discussion: "Example: secchain run -- npm run dev\nSecrets that are not 'standard' ask for Touch ID or your password first; one prompt covers all of them."
    )

    @Option(name: .long, help: "Pass only this secret. Repeat the option to pass several.")
    var only: [String] = []

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    @Argument(parsing: .postTerminator, help: "The command to run, after '--'.")
    var command: [String] = []

    func run() async throws {
        guard let executable = command.first else {
            throw ValidationError("No command given. Usage: secchain run -- <command> [arguments...]")
        }
        let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
        let environment = try RunPlan.childEnvironment(
            inheritedEnvironment: ProcessInfo.processInfo.environment,
            values: try await SecretStore.system.values(
                names: try RunPlan.secretNames(
                    storedSecretNames: try SecretStore.system.storedSecrets(repositoryIdentity: context.repositoryIdentity).map(\.name),
                    definition: context.definition,
                    onlyNames: try only.map(validatedSecretName(rawName:))
                ),
                repositoryIdentity: context.repositoryIdentity,
                authenticationReason: "run \(executable) with secrets of \(context.repositoryIdentity.value)"
            )
        )
        try replaceProcess(command: command, environment: environment)
    }

    /// Replaces this process with the command (`execve` semantics) instead of spawning a child.
    /// The command gets the terminal, the signals and the exit status directly, and no SecChain
    /// process holding the secrets stays alive next to it. No temporary file is involved.
    /// Not idempotent by nature: on success it never returns.
    func replaceProcess(command: [String], environment: [String: String]) throws {
        var argumentPointers = command.map { strdup($0) } + [nil]
        var environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        // The signal mask survives execve. Swift's concurrency runtime runs this code on a thread
        // that blocks signals, and the command inherited that mask: measured, it could not be
        // stopped with SIGTERM, SIGINT (Ctrl-C) or SIGHUP. Start the command with nothing blocked.
        var emptySignalSet = sigset_t()
        sigemptyset(&emptySignalSet)
        pthread_sigmask(SIG_SETMASK, &emptySignalSet, nil)
        execve(try resolvedExecutablePath(executable: command[0], environment: environment), &argumentPointers, &environmentPointers)
        // Only reached when execve failed.
        let failure = String(cString: strerror(errno))
        for pointer in argumentPointers + environmentPointers {
            free(pointer)
        }
        FileHandle.standardError.write(Data("secchain: cannot run \(command[0]): \(failure)\n".utf8))
        // 126: the conventional shell status for "found but could not be executed".
        throw ExitCode(126)
    }

    /// `execve` does not search PATH, so the lookup a shell would do is done here.
    func resolvedExecutablePath(executable: String, environment: [String: String]) throws -> String {
        guard !executable.contains("/") else {
            return executable
        }
        // `/usr/bin:/bin` is the POSIX default search path for an unset PATH.
        for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        FileHandle.standardError.write(Data("secchain: command not found: \(executable)\n".utf8))
        // 127: the conventional shell status for "command not found".
        throw ExitCode(127)
    }
}
