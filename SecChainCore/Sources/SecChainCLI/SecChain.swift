import ArgumentParser

/// Entry point of the `secchain` command-line tool.
@main
struct SecChain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secchain",
        abstract: "Per-repository secrets stored in the macOS Keychain.",
        version: "0.1.0",
        subcommands: [SetCommand.self, ListCommand.self, DeleteCommand.self, RunCommand.self, ScopeCommand.self, EnvCommand.self, PairCommand.self, Doctor.self]
    )
}
