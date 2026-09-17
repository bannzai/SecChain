import Foundation
import LocalAuthentication
import Security

/// Failures of secret storage, phrased so that the user can act on them. No case carries a
/// secret value, and the descriptions are built from names and status codes only.
public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    /// No value is stored under this name for this repository.
    case secretNotFound(name: String, repository: String)
    /// The Keychain already holds the item that was about to be added.
    case duplicateSecret(name: String, repository: String)
    /// The running binary is not signed with SecChain's Keychain access group. This is a
    /// code-signing problem of the installation, not a missing secret.
    case missingEntitlement
    /// The user failed authentication.
    case authenticationFailed
    /// The user (or the system) dismissed the authentication prompt.
    case authenticationCancelled
    /// A prompt was needed but cannot be shown in this context (no graphical session, SSH).
    case authenticationNotPossible
    /// Authentication is not set up on this device (no passcode / password, or the policy cannot
    /// be evaluated). Device-bound secrets require a passcode.
    case authenticationUnavailable(reason: String)
    /// The Keychain is locked or not available to this process.
    case keychainUnavailable
    /// A device-bound secret cannot be synchronized; the combination was requested explicitly.
    case deviceBoundCannotSynchronize
    /// The value to store is empty.
    case emptyValue
    /// Any other Security framework failure, with the system's wording for the status.
    case keychainFailure(operation: String, status: OSStatus, message: String)

    public var description: String {
        switch self {
        case .secretNotFound(let name, let repository):
            "No value is stored for \(name) in \(repository). Store it with 'secchain set \(name)'."
        case .duplicateSecret(let name, let repository):
            "\(name) already exists in \(repository)."
        case .missingEntitlement:
            "This binary is not signed with SecChain's Keychain access group, so it cannot reach any secret (errSecMissingEntitlement). Use the secchain tool inside SecChain.app; a binary built with 'swift build' or signed by another team cannot share the app's secrets. Run 'secchain doctor' for details."
        case .authenticationFailed:
            "Authentication failed."
        case .authenticationCancelled:
            "Authentication was cancelled."
        case .authenticationNotPossible:
            "This secret requires authentication, but no prompt can be shown here (for example over SSH). Run the command in a logged-in graphical session."
        case .authenticationUnavailable(let reason):
            "Authentication is not available on this device: \(reason)"
        case .keychainUnavailable:
            "The Keychain is not available. Unlock the device or log in and try again."
        case .deviceBoundCannotSynchronize:
            "A device-bound secret cannot be synchronized. Choose either device-bound or synchronization."
        case .emptyValue:
            "The value is empty."
        case .keychainFailure(let operation, let status, let message):
            "Keychain \(operation) failed with status \(status): \(message)"
        }
    }
}

/// Translations from system error codes. Pure, so that every mapping is unit-tested.
public enum SecretStoreErrorMapping {
    public static func error(status: OSStatus, operation: String, name: String, repository: String) -> SecretStoreError {
        switch status {
        case errSecItemNotFound:
            .secretNotFound(name: name, repository: repository)
        case errSecDuplicateItem:
            .duplicateSecret(name: name, repository: repository)
        case errSecMissingEntitlement:
            .missingEntitlement
        case errSecAuthFailed:
            .authenticationFailed
        case errSecUserCanceled:
            .authenticationCancelled
        case errSecInteractionNotAllowed:
            .authenticationNotPossible
        case errSecNotAvailable:
            .keychainUnavailable
        default:
            .keychainFailure(
                operation: operation,
                status: status,
                message: (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
            )
        }
    }

    public static func error(localAuthenticationErrorCode: Int, message: String) -> SecretStoreError {
        switch LAError.Code(rawValue: localAuthenticationErrorCode) {
        case .authenticationFailed:
            .authenticationFailed
        case .userCancel, .appCancel, .systemCancel:
            .authenticationCancelled
        case .notInteractive:
            .authenticationNotPossible
        default:
            .authenticationUnavailable(reason: message)
        }
    }
}
