import ArgumentParser

/// Entry point of the `secchain` command-line tool.
@main
struct SecChain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secchain",
        abstract: "Per-repository secrets stored in the macOS Keychain.",
        version: "0.1.0"
    )
}
