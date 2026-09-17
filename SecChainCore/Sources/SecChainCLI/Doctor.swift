import ArgumentParser
import SecChainCore

/// `secchain doctor`: shows whether this binary's code signature lets it use SecChain's Keychain
/// items. It exists because the most likely installation problem (an unsigned or differently
/// signed binary) otherwise looks like "no secrets found".
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that this binary can use SecChain's Keychain items."
    )

    @Flag(help: "Also ask for Touch ID / password once to confirm that the prompt can be shown.")
    var authenticate = false

    @Option(help: .hidden)
    var writeFixture: String?

    @Option(help: .hidden)
    var readFixture: String?

    func run() async throws {
        var checks: [KeychainDoctorCheck]
        if let writeFixture {
            checks = [KeychainDoctor.writeFixture(account: writeFixture)]
        } else if let readFixture {
            checks = KeychainDoctor.readAndDeleteFixture(account: readFixture)
        } else {
            checks = KeychainDoctor.runSelfContainedChecks()
        }
        if authenticate {
            checks.append(await KeychainDoctor.evaluateOwnerAuthentication())
        }
        for check in checks {
            print(check.line)
        }
        if checks.contains(where: { !$0.passed }) {
            throw ExitCode.failure
        }
    }
}
