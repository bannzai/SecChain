#if os(iOS)
import Foundation
import Observation
import SecChainCore
import UIKit
import UserNotifications

/// State of the remote approval screens: whether this iPhone is paired, which requests a Mac is
/// waiting for, and what happened to the one on screen.
///
/// It holds no secret value, because no record of the protocol carries one
/// (documents/remote-approval-records.md). Only the iOS app has it: approving is what the paired
/// iPhone does, and the macOS app shows no approval screen (issue #39).
@Observable
public final class RemoteApprovalModel {
    /// Transport the requests and the answers travel through. Only the debug demo replaces it.
    private(set) var store: any RemoteApprovalStore
    /// Where this device's approval key lives. Only the debug demo replaces it.
    private(set) var keyStore: any RemoteApprovalKeyStore
    /// Installs the subscription that turns a filed request into a notification. Injected because
    /// it is the one call that reaches CloudKit directly, and the debug demo has no account.
    private(set) var installSubscription: @Sendable (_ alertTitle: String, _ alertBody: String) async throws -> Void

    /// The key of this device, `nil` while it is not paired.
    private(set) var pairedKey: (any RemoteApprovalKey)?
    /// Name this iPhone publishes so that the user recognizes it on the Mac.
    let deviceName: String

    /// What this iPhone publishes for a Mac to enroll, `nil` while it is not paired.
    public var pairing: RemoteApprovalPairing? {
        pairedKey?.pairing(deviceName: deviceName)
    }

    /// Whether the published key was found in the private database, which is what a Mac reads
    /// while pairing. `false` also when the database could not be reached.
    public private(set) var isPairingPublished = false
    /// Requests a Mac is still waiting for, the one that expires first at the front.
    public private(set) var openRequests: [RemoteApprovalRequest] = []
    /// The request the approval screen shows, `nil` when no screen is up.
    public internal(set) var presentedRequest: RemoteApprovalRequest?
    /// Why the presented request can no longer be answered, `nil` while the Mac is still waiting.
    public private(set) var unanswerableReason: RemoteApprovalInboxError?
    /// What was written for the presented request, so that the screen can say what happened.
    public private(set) var answeredOutcome: RemoteApprovalOutcome?
    /// `true` while an answer is being signed or written, so that the buttons cannot be used twice.
    public private(set) var isAnswering = false
    /// Whether the user allowed notifications, which is how a request reaches an iPhone that is not
    /// in the user's hand.
    public private(set) var isNotificationAllowed = false
    /// The last failure, in the system's wording. It never names a secret, because the records do
    /// not carry one.
    public private(set) var failureMessage: String?

    public init(
        store: any RemoteApprovalStore,
        keyStore: any RemoteApprovalKeyStore,
        deviceName: String,
        installSubscription: @escaping @Sendable (_ alertTitle: String, _ alertBody: String) async throws -> Void
    ) {
        self.store = store
        self.keyStore = keyStore
        self.deviceName = deviceName
        self.installSubscription = installSubscription
    }

    var inbox: RemoteApprovalInbox {
        RemoteApprovalInbox(store: store, now: Date.init)
    }

    /// Reads the key of this device and the requests waiting for it. Called when the app starts and
    /// whenever a notification arrives, because a notification can be coalesced or dropped
    /// (documents/PROJECT.md, design decision 5). Safe to call at any time (idempotent).
    public func refresh() async {
        do {
            pairedKey = try keyStore.existingKey()
        } catch {
            present(failure: error)
        }
        isNotificationAllowed = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        guard pairedKey != nil else {
            openRequests = []
            return
        }
        if isNotificationAllowed {
            UIApplication.shared.registerForRemoteNotifications()
            await refreshSubscription()
        }
        await refreshRequests()
        await refreshPublishedPairing()
    }

    /// Opens the approval screen on the request that expires first, which is the one the user has
    /// the least time to answer. Called when the app opens and when a notification arrives.
    public func presentFirstOpenRequest() {
        if let request = openRequests.first {
            present(request: request)
        }
    }

    /// Creates the key of this iPhone and publishes its public key, so that a Mac can enroll it.
    /// Called again to pair a second time, which replaces the key: every Mac then has to enroll the
    /// new one, which is what makes an old, copied key useless.
    public func pair() async {
        do {
            let key = try keyStore.createKey()
            try await store.save(pairing: key.pairing(deviceName: deviceName))
            pairedKey = key
            failureMessage = nil
        } catch {
            present(failure: error)
        }
        await refreshRequests()
        await refreshPublishedPairing()
    }

    /// Withdraws the published key and removes the key itself, so that this iPhone can no longer
    /// approve anything. Removing what is not there succeeds (idempotent).
    public func unpair() async {
        do {
            if let pairing {
                try await store.delete(pairing: pairing)
            }
            try keyStore.deleteKey()
            pairedKey = nil
            openRequests = []
            isPairingPublished = false
            failureMessage = nil
        } catch {
            present(failure: error)
        }
    }

    /// Asks for permission to show notifications and installs the subscription that fills them.
    /// The prompt appears once; afterwards the system answers with what the user chose then.
    public func enableNotifications() async {
        do {
            isNotificationAllowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            failureMessage = nil
        } catch {
            present(failure: error)
        }
        guard isNotificationAllowed else {
            return
        }
        // A subscription fires a push, which only reaches an app the system registered.
        UIApplication.shared.registerForRemoteNotifications()
        await refreshSubscription()
    }

    /// Saves the subscription that turns a filed request into a notification. Saving it replaces
    /// the one already there (idempotent), which is how its text follows the language the app runs
    /// in and how a subscription lost with a signed-out account comes back.
    func refreshSubscription() async {
        do {
            try await installSubscription(
                // The app's name is the same in every language, so it is not a translated text.
                "SecChain",
                String(localized: "A Mac is asking for your approval", bundle: .module)
            )
            failureMessage = nil
        } catch {
            present(failure: error)
        }
    }

    /// Shows `request` on the approval screen, from the list or from a notification.
    public func present(request: RemoteApprovalRequest) {
        presentedRequest = request
        unanswerableReason = nil
        answeredOutcome = nil
    }

    /// Closes the approval screen.
    public func dismissRequest() {
        presentedRequest = nil
        unanswerableReason = nil
        answeredOutcome = nil
    }

    /// Signs the request with the key of this iPhone and writes the approval. The signature is what
    /// the Mac accepts as "the user approved"; a failed or cancelled Face ID prompt writes nothing.
    public func approve(request: RemoteApprovalRequest) async {
        guard let pairedKey else {
            return
        }
        await answer(outcome: .approved) { inbox in
            try await inbox.approve(request: request, key: pairedKey)
        }
    }

    /// Writes the rejection, which carries no signature.
    public func reject(request: RemoteApprovalRequest) async {
        await answer(outcome: .rejected) { inbox in
            try await inbox.reject(request: request)
        }
    }

    func answer(
        outcome: RemoteApprovalOutcome,
        write: (RemoteApprovalInbox) async throws -> Void
    ) async {
        isAnswering = true
        defer {
            isAnswering = false
        }
        do {
            try await write(inbox)
            answeredOutcome = outcome
            failureMessage = nil
        } catch let reason as RemoteApprovalInboxError {
            unanswerableReason = reason
        } catch {
            present(failure: error)
        }
        await refreshRequests()
    }

    func refreshRequests() async {
        do {
            openRequests = try await inbox.openRequests()
            if let presentedRequest, answeredOutcome == nil {
                unanswerableReason = try await inbox.unanswerableReason(request: presentedRequest)
            }
        } catch {
            present(failure: error)
        }
    }

    func refreshPublishedPairing() async {
        do {
            isPairingPublished = try await store.pairings().contains { $0.publicKeyRepresentation == pairing?.publicKeyRepresentation }
        } catch {
            isPairingPublished = false
            present(failure: error)
        }
    }

    func present(failure: any Error) {
        failureMessage = "\(failure)"
    }

    #if DEBUG
    /// Replaces the transport and the key with ones that need neither an Apple Account nor a Secure
    /// Enclave, and files a request the way a Mac does. The Simulator has neither
    /// (documents/PROJECT.md, "Remote approval spike") and a remote session cannot pass launch
    /// arguments, so the screens are filled from a control on screen. Calling it again starts over
    /// from the same demo data (idempotent).
    public func useDemoData() async {
        store = InMemoryRemoteApprovalStore()
        keyStore = InMemoryRemoteApprovalKeyStore()
        installSubscription = { _, _ in }
        pairedKey = nil
        presentedRequest = nil
        unanswerableReason = nil
        answeredOutcome = nil
        failureMessage = nil
        await pair()
        try? await store.save(
            request: RemoteApprovalRequest.filed(
                repositoryIdentity: RepositoryIdentity(value: "github.com/example/web-app"),
                secretNames: [SecretName(rawName: "CLOUDFLARE_API_TOKEN"), SecretName(rawName: "OPENAI_API_KEY")].compactMap { $0 },
                commandArguments: ["npm", "run", "deploy", "--", "--env", "production"],
                requestingDeviceName: "Example MacBook Pro",
                now: Date(),
                expiryInterval: RemoteApprovalSession.expiryInterval
            )
        )
        await refreshRequests()
        presentedRequest = openRequests.first
    }
    #endif
}
#endif
