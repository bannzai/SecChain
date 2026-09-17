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

    /// Hidden until remote approval ships: checks this binary's access to the CloudKit container
    /// instead of the Keychain (issue #32).
    @Flag(name: .customLong("cloudkit"), help: .hidden)
    var cloudKit = false

    func run() async throws {
        var checks: [KeychainDoctorCheck]
        if let writeFixture {
            checks = [KeychainDoctor.writeFixture(account: writeFixture)]
        } else if let readFixture {
            checks = KeychainDoctor.readAndDeleteFixture(account: readFixture)
        } else if cloudKit {
            checks = await KeychainDoctor.runCloudKitChecks()
        } else {
            checks = KeychainDoctor.runSelfContainedChecks() + (await KeychainDoctor.runStoreChecks())
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
