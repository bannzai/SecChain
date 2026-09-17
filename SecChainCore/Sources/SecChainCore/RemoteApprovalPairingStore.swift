import CryptoKit
import Foundation

/// What one Mac keeps about the iPhone it is paired with. It is per Mac, never synchronized: each
/// Mac decides for itself which key may answer its authentications (documents/PROJECT.md, design
/// decision 5).
public struct EnrolledPairing: Codable, Sendable, Equatable {
    /// The published key this Mac enrolled after the user compared the number on both screens.
    public let pairing: RemoteApprovalPairing
    /// Whether a *confirm* authentication goes to the iPhone without `--approve-remotely`, for a
    /// Mac without Touch ID and for commands started by an AI coding agent while the user is away.
    public let answersConfirmOnTheIPhone: Bool

    public init(pairing: RemoteApprovalPairing, answersConfirmOnTheIPhone: Bool) {
        self.pairing = pairing
        self.answersConfirmOnTheIPhone = answersConfirmOnTheIPhone
    }
}

/// Where a Mac keeps its pairing. A protocol so that the rules of `RemoteApprovalPairingStore` are
/// unit-tested without the Keychain and without a signed build.
public protocol RemoteApprovalPairingKeychain: Sendable {
    /// The pairing of this Mac, `nil` when none was enrolled.
    func enrolledPairing() throws -> EnrolledPairing?
    /// Stores the pairing, replacing the one that was there (idempotent).
    func write(enrolledPairing: EnrolledPairing) throws
    /// Removes the pairing. Removing when none is stored succeeds (idempotent).
    func delete() throws
}

/// Why a pairing operation did not happen. Separate from `RemoteApprovalError`, which is about one
/// approval, because these are answered by pairing rather than by retrying.
public enum RemoteApprovalPairingError: Error, Equatable, CustomStringConvertible {
    /// No iPhone has published a key to the private database.
    case noPublishedKey
    /// The number the user gave matches none of the published keys.
    case noKeyWithThatNumber(publishedNumbers: [String])
    /// This Mac has no pairing, so there is nothing to change.
    case notPaired

    public var description: String {
        switch self {
        case .noPublishedKey:
            "No iPhone has published an approval key. Open SecChain on your iPhone and start pairing there."
        case .noKeyWithThatNumber(let publishedNumbers):
            "No published key has that number. The keys published now show \(publishedNumbers.joined(separator: ", ")). Check the number on your iPhone, and pair again if it is not listed."
        case .notPaired:
            "This Mac is not paired with an iPhone. Run 'secchain pair' first."
        }
    }
}

/// The pairing of this Mac: which iPhone's key may answer its authentications, and whether
/// *confirm* goes to that iPhone by default.
///
/// Reading needs no authentication, because `secchain run` has to know whether it may ask the
/// iPhone in exactly the situations where no prompt can be shown, and because an enrolled **public**
/// key is not a secret. Every change does need one. SecChain asks for it itself, the same way the
/// *confirm* level does (documents/PROJECT.md, design decision 4): the Keychain item lives in the
/// shared access group, so only a binary signed by the SecChain team can write it at all, and what
/// is left to stop is a program that runs `secchain` as the user — which is what the authentication
/// stops.
public struct RemoteApprovalPairingStore: Sendable {
    let keychain: any RemoteApprovalPairingKeychain
    let ownerAuthenticator: any OwnerAuthenticating

    public init(keychain: any RemoteApprovalPairingKeychain, ownerAuthenticator: any OwnerAuthenticating) {
        self.keychain = keychain
        self.ownerAuthenticator = ownerAuthenticator
    }

    /// The store the shipping front ends use.
    public static var system: RemoteApprovalPairingStore {
        RemoteApprovalPairingStore(
            keychain: SystemRemoteApprovalPairingKeychain(),
            ownerAuthenticator: SystemOwnerAuthenticator()
        )
    }

    /// The pairing of this Mac, `nil` when none. Never prompts.
    public func enrolledPairing() throws -> EnrolledPairing? {
        try keychain.enrolledPairing()
    }

    /// The key an approval is verified against, `nil` when this Mac is not paired.
    public func enrolledPublicKey() throws -> P256.Signing.PublicKey? {
        try enrolledPairing()?.pairing.publicKey()
    }

    /// Enrolls the published key whose number the user read off their iPhone.
    ///
    /// `number` is compared after dropping everything but digits, so that the groups the two
    /// screens show do not have to be typed. Enrolling the same key again succeeds and keeps the
    /// setting (idempotent).
    @discardableResult
    public func enroll(publishedPairings: [RemoteApprovalPairing], number: String) async throws -> EnrolledPairing {
        guard !publishedPairings.isEmpty else {
            throw RemoteApprovalPairingError.noPublishedKey
        }
        guard let pairing = publishedPairings.first(where: { Self.digits(text: $0.verificationNumber) == Self.digits(text: number) }) else {
            throw RemoteApprovalPairingError.noKeyWithThatNumber(publishedNumbers: publishedPairings.map(\.verificationNumber))
        }
        // Refuse a key that cannot verify anything before asking the user to authenticate.
        _ = try pairing.publicKey()
        let previousPairing = try enrolledPairing()
        _ = try await ownerAuthenticator.authenticate(reason: "pair this Mac with \(pairing.deviceName)")
        let enrolledPairing = EnrolledPairing(
            pairing: pairing,
            // Remote approval stays opt-in (design decision 5): pairing alone does not start
            // sending every confirm authentication to the iPhone. Enrolling the key that is
            // already enrolled keeps the setting the user chose.
            answersConfirmOnTheIPhone: previousPairing?.pairing == pairing && previousPairing?.answersConfirmOnTheIPhone == true
        )
        try keychain.write(enrolledPairing: enrolledPairing)
        return enrolledPairing
    }

    /// Removes the pairing. Removing when none is enrolled succeeds without a prompt, because
    /// there is nothing to protect (idempotent).
    public func remove() async throws {
        guard try enrolledPairing() != nil else {
            return
        }
        _ = try await ownerAuthenticator.authenticate(reason: "stop letting your iPhone answer authentications on this Mac")
        try keychain.delete()
    }

    /// Turns the per-Mac setting on or off.
    @discardableResult
    public func setAnswersConfirmOnTheIPhone(answersConfirmOnTheIPhone: Bool) async throws -> EnrolledPairing {
        guard let enrolledPairing = try enrolledPairing() else {
            throw RemoteApprovalPairingError.notPaired
        }
        _ = try await ownerAuthenticator.authenticate(
            reason: answersConfirmOnTheIPhone
                ? "answer authentications on \(enrolledPairing.pairing.deviceName) by default"
                : "ask for authentication on this Mac again"
        )
        let changedPairing = EnrolledPairing(pairing: enrolledPairing.pairing, answersConfirmOnTheIPhone: answersConfirmOnTheIPhone)
        try keychain.write(enrolledPairing: changedPairing)
        return changedPairing
    }

    /// Only the digits of `text`, so that `1234-5678-9012`, `1234 5678 9012`, and `123456789012`
    /// are the same number.
    static func digits(text: String) -> String {
        text.filter(\.isNumber)
    }
}

/// Pairing storage that keeps the pairing in memory, for unit tests and the apps' previews (the
/// same reason `InMemorySecretKeychain` is part of the library). A class with a lock, because the
/// storage is shared mutable state with identity.
public final class InMemoryRemoteApprovalPairingKeychain: RemoteApprovalPairingKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPairing: EnrolledPairing?

    public init(enrolledPairing: EnrolledPairing? = nil) {
        self.storedPairing = enrolledPairing
    }

    public func enrolledPairing() throws -> EnrolledPairing? {
        lock.withLock {
            storedPairing
        }
    }

    public func write(enrolledPairing: EnrolledPairing) throws {
        lock.withLock {
            storedPairing = enrolledPairing
        }
    }

    public func delete() throws {
        lock.withLock {
            storedPairing = nil
        }
    }
}
