import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Why the approving device cannot create, read, or use its approval key. The cases are separate
/// because the user acts differently on each: a device without a Secure Enclave can never approve,
/// while a refused authentication is a prompt that was not answered.
public enum RemoteApprovalKeyError: Error, Equatable, CustomStringConvertible {
    /// The device has no Secure Enclave, so no key that stays on the device can be created.
    case secureEnclaveUnavailable
    /// The Secure Enclave refused to create the key, with the system's explanation.
    case creationFailed(message: String)
    /// The Secure Enclave refused to sign, which is also what a cancelled Face ID prompt looks like.
    case signingFailed(message: String)
    /// The Keychain call that keeps the key between launches failed.
    case storageFailed(operation: String, status: OSStatus)
    /// The stored bytes are not a key of this device's Secure Enclave any more.
    case storedKeyUnusable(message: String)

    public var description: String {
        switch self {
        case .secureEnclaveUnavailable:
            "This device has no Secure Enclave, so it cannot hold an approval key."
        case .creationFailed(let message):
            "The approval key could not be created: \(message)"
        case .signingFailed(let message):
            "The approval was not signed: \(message)"
        case .storageFailed(let operation, let status):
            "Keychain \(operation) of the approval key failed with status \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error")"
        case .storedKeyUnusable(let message):
            "The stored approval key cannot be used on this device any more: \(message)"
        }
    }
}

/// The private key an approval is signed with. Only the paired device holds it, which is what makes
/// "approved" mean "that device, after a biometric match" (documents/PROJECT.md, design decision 5).
///
/// It is a protocol because the Simulator cannot create a Secure Enclave key that requires Face ID
/// (documents/PROJECT.md, "Remote approval spike"), so unit tests and the debug demo sign with a key
/// in memory while the app signs with the enclave.
public protocol RemoteApprovalKey: Sendable {
    /// P-256 public key in the X9.63 representation `RemoteApprovalPairing` publishes.
    var publicKeyRepresentation: Data { get }

    /// Signs `message`. The Secure Enclave asks for Face ID / Touch ID first, so the call does not
    /// return until the user has answered the prompt.
    func signature(message: Data) throws -> P256.Signing.ECDSASignature
}

extension RemoteApprovalKey {
    /// The approval signature over `request`, in the raw representation the answer record carries.
    public func approvalSignature(request: RemoteApprovalRequest) throws -> Data {
        try RemoteApproval.signature(request: request) { message in
            try signature(message: message)
        }
    }

    /// What this device publishes so that a Mac can enroll the key.
    public func pairing(deviceName: String) -> RemoteApprovalPairing {
        RemoteApprovalPairing(publicKeyRepresentation: publicKeyRepresentation, deviceName: deviceName)
    }
}

/// A key held in memory for as long as the process runs. It signs without asking anybody, so it is
/// only ever used where no enclave key can exist: unit tests, and the debug demo that shows the
/// approval screen on the Simulator.
public struct SoftwareRemoteApprovalKey: RemoteApprovalKey {
    /// The key itself. Never written anywhere, because a key that is not in the Secure Enclave must
    /// not outlive the process that made it.
    let privateKey: P256.Signing.PrivateKey

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    public var publicKeyRepresentation: Data {
        privateKey.publicKey.x963Representation
    }

    public func signature(message: Data) throws -> P256.Signing.ECDSASignature {
        do {
            return try privateKey.signature(for: message)
        } catch {
            throw RemoteApprovalKeyError.signingFailed(message: "\(error)")
        }
    }
}

/// The key SecChain ships with: a P-256 key of the device's Secure Enclave that never leaves it and
/// demands Face ID / Touch ID for every signature.
public struct SecureEnclaveRemoteApprovalKey: RemoteApprovalKey {
    /// The key as the Secure Enclave hands it out for storage: a blob only this device's enclave can
    /// turn back into a usable key, which is why it may be kept in the Keychain.
    public let dataRepresentation: Data
    public let publicKeyRepresentation: Data
    /// Explanation shown in the Face ID / Touch ID prompt of every signature, in the app's language.
    let authenticationReason: String

    /// Derives the public key and the storable representation from a key of the enclave. Not the
    /// memberwise initializer, because the two representations must come from the same key.
    init(privateKey: SecureEnclave.P256.Signing.PrivateKey, authenticationReason: String) {
        dataRepresentation = privateKey.dataRepresentation
        publicKeyRepresentation = privateKey.publicKey.x963Representation
        self.authenticationReason = authenticationReason
    }

    /// The key behind `dataRepresentation`, as it was read back from the Keychain.
    public init(dataRepresentation: Data, authenticationReason: String) throws {
        do {
            self.init(
                privateKey: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation),
                authenticationReason: authenticationReason
            )
        } catch {
            throw RemoteApprovalKeyError.storedKeyUnusable(message: "\(error)")
        }
    }

    /// A new key of this device's enclave, guarded by `.privateKeyUsage` and `.biometryAny`:
    /// `.biometryAny` rather than `.biometryCurrentSet` so that enrolling another face or finger does
    /// not force the user to pair every Mac again (documents/PROJECT.md, design decision 5).
    public static func created(authenticationReason: String) throws -> SecureEnclaveRemoteApprovalKey {
        guard SecureEnclave.isAvailable else {
            throw RemoteApprovalKeyError.secureEnclaveUnavailable
        }
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            // The key is useless without a passcode and must never travel to another device, which
            // is what this accessibility class enforces for the blob kept in the Keychain.
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .biometryAny],
            &accessControlError
        ) else {
            throw RemoteApprovalKeyError.creationFailed(
                message: accessControlError.map { "\($0.takeRetainedValue())" } ?? "the access control could not be created"
            )
        }
        do {
            return SecureEnclaveRemoteApprovalKey(
                privateKey: try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl),
                authenticationReason: authenticationReason
            )
        } catch {
            throw RemoteApprovalKeyError.creationFailed(message: "\(error)")
        }
    }

    public func signature(message: Data) throws -> P256.Signing.ECDSASignature {
        // A context of its own for every approval: an authentication has to cover exactly the
        // request the user is looking at, never one they answered a moment ago.
        let context = LAContext()
        context.localizedReason = authenticationReason
        do {
            return try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: dataRepresentation,
                authenticationContext: context
            ).signature(for: message)
        } catch {
            throw RemoteApprovalKeyError.signingFailed(message: "\(error)")
        }
    }
}
