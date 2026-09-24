/// Where a secret belongs (documents/PROJECT.md, "Secret scopes"). A repository's own secrets are in
/// its repository scope. A shared scope holds secrets that several repositories use, and only
/// `~/.secchain` decides which repositories it is passed to.
public enum SecretScope: Hashable, Sendable, CustomStringConvertible {
    /// The secrets of one repository. What every command acts on unless told otherwise.
    case repository(RepositoryIdentity)
    /// The user scope or a custom scope.
    case shared(SharedScope)

    /// Name of the repository scope on the command line. Reserved: no custom scope can take it.
    public static let repositoryScopeName = "repository"

    /// The scope's name as the command line and `list` spell it.
    public var name: String {
        switch self {
        case .repository:
            Self.repositoryScopeName
        case .shared(let sharedScope):
            sharedScope.name
        }
    }

    /// The scope as messages name it: the repository identifier, or `scope <name>`.
    public var description: String {
        switch self {
        case .repository(let repositoryIdentity):
            repositoryIdentity.value
        case .shared(let sharedScope):
            "scope \(sharedScope.name)"
        }
    }

    /// The repository of a repository scope, `nil` for a shared scope.
    public var repositoryIdentity: RepositoryIdentity? {
        guard case .repository(let repositoryIdentity) = self else {
            return nil
        }
        return repositoryIdentity
    }

    /// The shared scope, `nil` for a repository scope.
    public var sharedScope: SharedScope? {
        guard case .shared(let sharedScope) = self else {
            return nil
        }
        return sharedScope
    }

    /// `kSecAttrService` of every secret of the scope. One service per scope lets a single query
    /// enumerate the scope's secrets; the secret name is `kSecAttrAccount`.
    public var keychainService: String {
        switch self {
        case .repository(let repositoryIdentity):
            repositoryIdentity.keychainService
        case .shared(let sharedScope):
            SecChainSharedConfig.scopeKeychainServicePrefix + sharedScope.name
        }
    }

    /// Inverse of `keychainService`, used when enumerating every scope known to the Keychain.
    /// `nil` for services that belong to no scope (the doctor's, the pairing's) and for a scope
    /// name this version does not accept, which is ignored rather than guessed at.
    public init?(keychainService: String) {
        if let repositoryIdentity = RepositoryIdentity(keychainService: keychainService) {
            self = .repository(repositoryIdentity)
            return
        }
        guard
            keychainService.hasPrefix(SecChainSharedConfig.scopeKeychainServicePrefix),
            let sharedScope = SharedScope(name: String(keychainService.dropFirst(SecChainSharedConfig.scopeKeychainServicePrefix.count)))
        else {
            return nil
        }
        self = .shared(sharedScope)
    }

    /// `kSecAttrServer` of the internet password that holds a device-bound value
    /// (`SystemSecretKeychain`). A repository keeps its identifier there, as every earlier version
    /// wrote it. A shared scope uses its whole service instead of its name, so that a repository
    /// whose identifier happens to be a scope's name never shares that item with the scope. The
    /// one repository identifier that could still name it, one that starts like a scope's service,
    /// is refused (`isRepositoryNamedLikeASharedScope`).
    var protectedValueServer: String {
        switch self {
        case .repository(let repositoryIdentity):
            repositoryIdentity.value
        case .shared:
            keychainService
        }
    }

    /// Whether this is a repository whose identifier is the service of a shared scope, so that its
    /// device-bound values would be kept under that scope's `protectedValueServer`. Only an
    /// identifier given by hand (`--repository`, or typed in an app) can be one:
    /// a Git remote's identifier always contains a slash, which no scope's service does. Letter case
    /// is ignored, so that the answer does not depend on how the Keychain compares servers.
    var isRepositoryNamedLikeASharedScope: Bool {
        guard
            let lowercasedIdentifier = repositoryIdentity?.value.lowercased(),
            lowercasedIdentifier.hasPrefix(SecChainSharedConfig.scopeKeychainServicePrefix.lowercased())
        else {
            return false
        }
        return SharedScope(name: String(lowercasedIdentifier.dropFirst(SecChainSharedConfig.scopeKeychainServicePrefix.count))) != nil
    }
}

/// A scope whose secrets several repositories use. `~/.secchain` names the repositories each one is
/// passed to; a repository's own files cannot (documents/PROJECT.md, design decision 6).
public enum SharedScope: Hashable, Sendable, CustomStringConvertible {
    /// The one built-in shared scope, for secrets that are the same in every repository.
    case user
    /// A shared scope the user named, for the secrets of one purpose.
    case custom(CustomScopeName)

    /// Name of the user scope on the command line and in its Keychain service. Reserved for the
    /// built-in scope: no custom scope can take it.
    public static let userScopeName = "user"

    // `user` names the built-in scope and every other name must be a valid custom scope name, so
    // the conversion from a typed name can fail.
    public init?(name: String) {
        if name == Self.userScopeName {
            self = .user
            return
        }
        guard let customScopeName = CustomScopeName(rawName: name) else {
            return nil
        }
        self = .custom(customScopeName)
    }

    /// The scope's name as the command line and `~/.secchain` spell it.
    public var name: String {
        switch self {
        case .user:
            Self.userScopeName
        case .custom(let customScopeName):
            customScopeName.value
        }
    }

    public var description: String {
        name
    }
}

/// Name of a custom scope. It becomes part of a Keychain service, a line of `~/.secchain`, and an
/// argument on the command line, so only names that need no quoting anywhere are valid: lowercase
/// ASCII letters, digits, and hyphens, starting with a letter or a digit.
///
/// Lowercase only, for the reason repository identifiers are folded to lowercase: the Keychain would
/// keep `YouTube` and `youtube` apart and split one scope's secrets between the two spellings.
public struct CustomScopeName: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The validated name.
    public let value: String

    // Only names that follow the rules above are accepted, and the names of the built-in scopes are
    // not custom names, so creation can fail.
    public init?(rawName: String) {
        guard
            let first = rawName.unicodeScalars.first,
            isLowercaseASCIILetterOrDigit(scalar: first),
            rawName.unicodeScalars.allSatisfy({ $0 == "-" || isLowercaseASCIILetterOrDigit(scalar: $0) }),
            rawName != SharedScope.userScopeName,
            rawName != SecretScope.repositoryScopeName
        else {
            return nil
        }
        self.value = rawName
    }

    public var description: String {
        value
    }

    public static func < (lhs: CustomScopeName, rhs: CustomScopeName) -> Bool {
        lhs.value < rhs.value
    }
}

/// The characters a custom scope name is made of, besides the hyphen.
func isLowercaseASCIILetterOrDigit(scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
}
