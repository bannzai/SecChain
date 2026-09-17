import Foundation

/// How a *confirm* authentication is answered for one invocation (documents/PROJECT.md, design
/// decision 5, "When remote approval is used").
public enum OwnerAuthenticationRoute: Sendable, Equatable, CaseIterable {
    /// The system prompt on this Mac, as before remote approval existed.
    case localPrompt
    /// The paired iPhone, without trying the local prompt first.
    case pairedIPhone
    /// The local prompt, and the paired iPhone when the prompt cannot be shown.
    case localPromptThenPairedIPhone
}

/// Which route an invocation takes. A pure decision, so that the three cases of design decision 5
/// and the exclusion of device-bound secrets are unit-tested without a Keychain or CloudKit.
public enum OwnerAuthenticationRouting {
    /// - `isPaired`: this Mac has an enrolled key.
    /// - `answersConfirmOnTheIPhone`: the per-Mac setting.
    /// - `approveRemotelyRequested`: `secchain run --approve-remotely`.
    /// - `includesDeviceBoundSecret`: the invocation reads a *device-bound* secret. Those are
    ///   excluded from remote approval: the Keychain itself demands user presence on the device
    ///   that holds the value, and an approval from the iPhone cannot satisfy it.
    ///
    /// Without a pairing every case behaves as before: the local prompt, or the authentication
    /// error where no prompt can be shown.
    public static func route(
        isPaired: Bool,
        answersConfirmOnTheIPhone: Bool,
        approveRemotelyRequested: Bool,
        includesDeviceBoundSecret: Bool
    ) -> OwnerAuthenticationRoute {
        guard isPaired, !includesDeviceBoundSecret else {
            return .localPrompt
        }
        return approveRemotelyRequested || answersConfirmOnTheIPhone ? .pairedIPhone : .localPromptThenPairedIPhone
    }
}

/// Answers an authentication on the paired iPhone instead of at the Mac.
///
/// The request is prepared by the caller, which is the only place that knows the repository, the
/// secret names, and the command the user is about to run — the very things the iPhone shows and
/// the approval signature covers. `reason` is the wording of the local prompt and is not used.
public struct RemoteOwnerAuthenticator: OwnerAuthenticating {
    /// Files the request and waits for the verified approval.
    let session: RemoteApprovalSession
    /// What the iPhone is asked to approve.
    let request: RemoteApprovalRequest

    public init(session: RemoteApprovalSession, request: RemoteApprovalRequest) {
        self.session = session
        self.request = request
    }

    public func authenticate(reason: String) async throws -> OwnerAuthentication {
        try await session.waitForApproval(request: request)
        // No `LAContext`: a *confirm* item carries no access control, so the Keychain needs none to
        // return its value. A device-bound item does, which is why `OwnerAuthenticationRouting`
        // never sends one down this route.
        return OwnerAuthentication(context: nil)
    }
}

/// Asks on this Mac, and asks the paired iPhone when no prompt can be shown here (SSH).
///
/// Only `SecretStoreError.authenticationNotPossible` switches over. A prompt that nobody answers in
/// a graphical session keeps waiting (documents/PROJECT.md, "Measured behavior"), so being away
/// from the Mac cannot be detected this way and needs `--approve-remotely` or the per-Mac setting.
/// A failed or cancelled authentication is the user's answer and is not asked again elsewhere.
public struct LocalOrRemoteOwnerAuthenticator: OwnerAuthenticating {
    let localAuthenticator: any OwnerAuthenticating
    let remoteAuthenticator: any OwnerAuthenticating
    /// Receives the line that says the question moved to the iPhone. The command-line tool writes
    /// it to standard error.
    let report: @Sendable (String) -> Void

    public init(
        localAuthenticator: any OwnerAuthenticating,
        remoteAuthenticator: any OwnerAuthenticating,
        report: @escaping @Sendable (String) -> Void
    ) {
        self.localAuthenticator = localAuthenticator
        self.remoteAuthenticator = remoteAuthenticator
        self.report = report
    }

    public func authenticate(reason: String) async throws -> OwnerAuthentication {
        do {
            return try await localAuthenticator.authenticate(reason: reason)
        } catch SecretStoreError.authenticationNotPossible {
            report("no authentication prompt can be shown here, asking your paired iPhone instead")
            return try await remoteAuthenticator.authenticate(reason: reason)
        }
    }
}
