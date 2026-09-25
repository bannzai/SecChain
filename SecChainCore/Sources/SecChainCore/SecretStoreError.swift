import Foundation
import LocalAuthentication
import Security

/// Failures of secret storage, phrased so that the user can act on them. No case carries a
/// secret value, and the descriptions are built from names and status codes only.
public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    /// No value is stored under this name for this repository.
    case secretNotFound(name: String, repository: String)
    /// No value of this environment is stored under this name in the scopes named by `repository`.
    case secretNotFoundInEnvironment(name: String, repository: String, environment: String)
    /// The scope has secrets of environments, so an operation on it has to name one: a secret
    /// stored without an environment would never be passed by `run` (documents/PROJECT.md,
    /// "Environments"). `environments` are the scope's environments, for the message.
    case environmentRequired(repository: String, environments: [String])
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
    /// The repository identifier is the service of a shared scope, whose device-bound values would
    /// share Keychain items with the repository's (`SecretScope.isRepositoryNamedLikeASharedScope`).
    case reservedRepositoryIdentifier(repository: String)
    /// The repository identifier contains the separator of an environment, so its secrets would be
    /// read back as those of an environment of another repository
    /// (`SecretScope.isRepositoryNamedWithAnEnvironmentSeparator`).
    case repositoryIdentifierContainsEnvironmentSeparator(repository: String)
    /// Any other Security framework failure, with the system's wording for the status.
    case keychainFailure(operation: String, status: OSStatus, message: String)

    /// The message in English, as the command-line tool prints it: no SecChain binary has
    /// translations in `Bundle.main`.
    public var description: String {
        message(bundle: .main)
    }

    /// The message translated by the String Catalog in `bundle`, for the apps, which show it in the
    /// user's language. English where the catalog has no translation.
    public func message(bundle: Bundle) -> String {
        switch self {
        case .secretNotFound(let name, let repository):
            String(localized: "No value is stored for \(name) in \(repository). Store it with 'secchain set \(name)'.", bundle: bundle)
        case .secretNotFoundInEnvironment(let name, let repository, let environment):
            String(localized: "No value of the environment \(environment) is stored for \(name) in \(repository). Store it with 'secchain set \(name) --env \(environment)'.", bundle: bundle)
        case .environmentRequired(let repository, let environments):
            String(localized: "\(repository) has the environments \(environments.joined(separator: ", ")), so name one with '--env <environment>'.", bundle: bundle)
        case .duplicateSecret(let name, let repository):
            String(localized: "\(name) already exists in \(repository).", bundle: bundle)
        case .missingEntitlement:
            String(localized: "This binary is not signed with SecChain's Keychain access group, so it cannot reach any secret (errSecMissingEntitlement). Use the secchain tool inside SecChain.app; a binary built with 'swift build' or signed by another team cannot share the app's secrets. Run 'secchain doctor' for details.", bundle: bundle)
        case .authenticationFailed:
            String(localized: "Authentication failed.", bundle: bundle)
        case .authenticationCancelled:
            String(localized: "Authentication was cancelled.", bundle: bundle)
        case .authenticationNotPossible:
            String(localized: "This secret requires authentication, but no prompt can be shown here (for example over SSH). Run the command in a logged-in graphical session.", bundle: bundle)
        case .authenticationUnavailable(let reason):
            String(localized: "Authentication is not available on this device: \(reason)", bundle: bundle)
        case .keychainUnavailable:
            String(localized: "The Keychain is not available. Unlock the device or log in and try again.", bundle: bundle)
        case .deviceBoundCannotSynchronize:
            String(localized: "A device-bound secret cannot be synchronized. Choose either device-bound or synchronization.", bundle: bundle)
        case .emptyValue:
            String(localized: "The value is empty.", bundle: bundle)
        case .reservedRepositoryIdentifier(let repository):
            String(localized: "\(repository) cannot be a repository identifier: it is the name SecChain gives the Keychain items of a shared scope.", bundle: bundle)
        case .repositoryIdentifierContainsEnvironmentSeparator(let repository):
            String(localized: "\(repository) cannot be a repository identifier: '#' separates the environment in the names SecChain gives its Keychain items.", bundle: bundle)
        case .keychainFailure(let operation, let status, let message):
            String(localized: "Keychain \(operation) failed with status \(status): \(message)", bundle: bundle)
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
