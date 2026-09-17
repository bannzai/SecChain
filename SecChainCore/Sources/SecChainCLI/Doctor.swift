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

    #if DEBUG
    /// Debug builds only, and hidden: plays both sides of one remote approval against the real
    /// CloudKit container with a software key, because the iOS app that would answer does not
    /// exist yet (issue #39). `make test-integration` runs it; the notarized DMG is a Release
    /// build and does not contain it.
    @Flag(name: .customLong("remote-approval-end-to-end"), help: .hidden)
    var remoteApprovalEndToEnd = false
    #endif

    func run() async throws {
        var checks: [KeychainDoctorCheck]
        if let writeFixture {
            checks = [KeychainDoctor.writeFixture(account: writeFixture)]
        } else if let readFixture {
            checks = KeychainDoctor.readAndDeleteFixture(account: readFixture)
        } else if cloudKit {
            checks = await KeychainDoctor.runCloudKitChecks()
        } else if remoteApprovalEndToEndRequested {
            checks = await KeychainDoctor.runRemoteApprovalEndToEndChecks(
                waitWithInterruptCancelling: { try await withInterruptCancellingTheOperation(operation: $0) }
            )
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

    /// Whether the end-to-end round was asked for. A release build has no such flag, so the
    /// branch that runs it is compiled out with it.
    var remoteApprovalEndToEndRequested: Bool {
        #if DEBUG
        remoteApprovalEndToEnd
        #else
        false
        #endif
    }
}
