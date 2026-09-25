import ArgumentParser
import Dispatch
import Foundation
import SecChainCore

/// Options of the commands that can have their authentication answered on the paired iPhone.
struct RemoteApprovalOptions: ParsableArguments {
    @Flag(
        name: .customLong("approve-remotely"),
        help: "Ask the iPhone paired with this Mac to approve, instead of showing a prompt here. Needs 'secchain pair' first."
    )
    var approveRemotely = false
}

/// Writes one line to standard error, prefixed like every other message of the tool. Standard
/// output belongs to the command being run, so progress and warnings never go there.
func reportToStandardError(line: String) {
    FileHandle.standardError.write(Data("secchain: \(line)\n".utf8))
}

/// Name of this Mac as the user knows it, which is what the iPhone shows next to a request.
func thisMacName() -> String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
}

/// The store for one invocation, together with whether reading a value can end up waiting for the
/// paired iPhone.
///
/// Where a *confirm* authentication is answered is decided here, because only the command knows
/// what the iPhone would be shown: the repository, the secret names, and the command the user is
/// about to run (documents/PROJECT.md, design decision 5). `scope` is what the command acts on: the
/// repository of `run`, or the scope of `set` / `delete`.
///
/// The pairing is only read when an authentication can actually happen, so that a repository of
/// *standard* secrets behaves exactly as before.
func secretStore(
    scope: SecretScope,
    requestedSecrets: [StoredSecret],
    commandArguments: [String],
    approveRemotely: Bool
) throws -> (store: SecretStore, waitsForARemoteApproval: Bool) {
    guard requestedSecrets.contains(where: { $0.protectionLevel != .standard }) else {
        return (SecretStore.system, false)
    }
    let enrolledPairing = try RemoteApprovalPairingStore.system.enrolledPairing()
    let includesDeviceBoundSecret = requestedSecrets.contains { $0.protectionLevel == .deviceBound }
    let route = OwnerAuthenticationRouting.route(
        isPaired: enrolledPairing != nil,
        answersConfirmOnTheIPhone: enrolledPairing?.answersConfirmOnTheIPhone ?? false,
        approveRemotelyRequested: approveRemotely,
        includesDeviceBoundSecret: includesDeviceBoundSecret
    )
    guard let enrolledPairing, route != .localPrompt else {
        if approveRemotely {
            reportToStandardError(
                line: includesDeviceBoundSecret
                    // The Keychain enforces user presence on the device that holds the value, so an
                    // approval from the iPhone cannot satisfy it.
                    ? "a device-bound secret can only be confirmed on this Mac, asking here"
                    : "this Mac is not paired with an iPhone, asking here. Run 'secchain pair' to pair it"
            )
        }
        return (SecretStore.system, false)
    }
    let remoteAuthenticator = RemoteOwnerAuthenticator(
        session: RemoteApprovalSession(
            store: try CloudKitRemoteApprovalStore.system(),
            enrolledPublicKey: try enrolledPairing.pairing.publicKey(),
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            report: { reportToStandardError(line: $0) }
        ),
        request: RemoteApprovalRequest.filed(
            // `set` and `delete` of a shared scope act on no repository, so the scope takes the
            // repository's place as `scope <name>` (`RemoteApprovalRequest.repositoryIdentity`).
            repositoryIdentity: scope.repositoryIdentity ?? RepositoryIdentity(value: scope.description),
            // `requestedSecrets` holds one secret per name, the one the command acts on
            // (`SecretStore.storedSecrets(scopes:)`); should a name come twice, the first wins, as
            // it does there.
            secretScopes: Dictionary(requestedSecrets.map { ($0.name, $0.scope) }, uniquingKeysWith: { first, _ in first }),
            commandArguments: commandArguments,
            requestingDeviceName: thisMacName(),
            now: Date(),
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
    )
    return (
        SecretStore(
            keychain: SystemSecretKeychain(),
            ownerAuthenticator: route == .pairedIPhone
                ? remoteAuthenticator
                : LocalOrRemoteOwnerAuthenticator(
                    localAuthenticator: SystemOwnerAuthenticator(),
                    remoteAuthenticator: remoteAuthenticator,
                    report: { reportToStandardError(line: $0) }
                )
        ),
        true
    )
}

/// Runs `operation` with Ctrl-C cancelling it only when a remote approval can be waited for.
/// Everywhere else Ctrl-C keeps terminating the process the way it always did, which is what a user
/// expects while a local prompt is on screen.
func withInterruptCancellingWhileWaiting<Value: Sendable>(
    waitsForARemoteApproval: Bool,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    guard waitsForARemoteApproval else {
        return try await operation()
    }
    return try await withInterruptCancellingTheOperation(operation: operation)
}

/// Runs `operation` with Ctrl-C turned into cancellation of its task, so that a command waiting for
/// a remote approval saves a cancellation record instead of dying at the signal (design decision 5).
///
/// A `DispatchSource` rather than a `signal` handler: Swift's concurrency runtime runs this code on
/// a thread that blocks signals (measured, see `RunCommand.replaceProcess`), while a dispatch source
/// is kqueue-based and sees the signal anyway. `SIG_IGN` keeps the default "terminate this process"
/// disposition from firing first, and it is restored before returning, because a `SIG_IGN`
/// disposition survives `execve` and would leave the command that replaces this process unable to
/// be interrupted.
///
/// Not idempotent by nature: it changes the process's signal disposition while it runs.
func withInterruptCancellingTheOperation<Value: Sendable>(
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let operationTask = Task {
        try await operation()
    }
    // `sigaction` rather than `signal`, so that the disposition this process started with is put
    // back exactly, including the case where the shell started it with the signal already ignored.
    var previousAction = sigaction()
    sigaction(SIGINT, nil, &previousAction)
    var ignoringAction = sigaction()
    sigemptyset(&ignoringAction.sa_mask)
    ignoringAction.sa_flags = 0
    ignoringAction.__sigaction_u.__sa_handler = SIG_IGN
    sigaction(SIGINT, &ignoringAction, nil)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interruptSource.setEventHandler {
        operationTask.cancel()
    }
    interruptSource.resume()
    defer {
        interruptSource.cancel()
        sigaction(SIGINT, &previousAction, nil)
    }
    return try await operationTask.value
}
