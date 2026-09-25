/// A deployment target a secret's value is meant for, such as `local`, `dev`, or `prod`
/// (documents/PROJECT.md, "Environments"). It is the third part of what identifies a secret, next to
/// the scope and the name, so that one name can hold a value per deployment target while the
/// environment variable the command gets keeps that name.
///
/// The name becomes part of a Keychain service and an argument on the command line, so it follows
/// the rules of a custom scope name (`CustomScopeName`): lowercase ASCII letters, digits, and
/// hyphens, starting with a letter or a digit. No name is reserved.
public struct SecretEnvironment: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The validated name.
    public let value: String

    /// Separates a scope's Keychain service from the environment appended to it. Neither a
    /// repository identifier nor a scope name can contain it: a Git remote's identifier has no `#`
    /// (the fragment is not part of a remote URL), a scope name allows no punctuation but the hyphen,
    /// and an identifier given by hand that contains one is refused.
    public static let keychainServiceSeparator: Character = "#"

    // Only names that follow the rules above are accepted, so creation can fail.
    public init?(rawName: String) {
        guard
            let first = rawName.unicodeScalars.first,
            isLowercaseASCIILetterOrDigit(scalar: first),
            rawName.unicodeScalars.allSatisfy({ $0 == "-" || isLowercaseASCIILetterOrDigit(scalar: $0) })
        else {
            return nil
        }
        self.value = rawName
    }

    /// The environment of an item whose service is `keychainService`, `nil` for an item without
    /// one and for a service whose environment part is not a valid name. `SecretScope(keychainService:)`
    /// refuses the latter, so such an item is ignored rather than read as having no environment.
    public init?(keychainService: String) {
        guard let rawName = splitKeychainService(keychainService: keychainService).environmentName else {
            return nil
        }
        self.init(rawName: rawName)
    }

    public var description: String {
        value
    }

    public static func < (lhs: SecretEnvironment, rhs: SecretEnvironment) -> Bool {
        lhs.value < rhs.value
    }
}

/// A Keychain service split at its first `SecretEnvironment.keychainServiceSeparator`: the scope's
/// own service, and the name of the environment after it, `nil` when the service has none.
func splitKeychainService(keychainService: String) -> (scopeKeychainService: String, environmentName: String?) {
    guard let separatorIndex = keychainService.firstIndex(of: SecretEnvironment.keychainServiceSeparator) else {
        return (keychainService, nil)
    }
    return (
        String(keychainService[..<separatorIndex]),
        String(keychainService[keychainService.index(after: separatorIndex)...])
    )
}
