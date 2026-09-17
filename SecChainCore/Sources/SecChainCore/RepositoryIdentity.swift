import Foundation

/// Identifies a repository independently of where it is checked out, so that the same repository
/// maps to the same Keychain items on every Mac (and in every worktree of one Mac).
public struct RepositoryIdentity: Hashable, Sendable, CustomStringConvertible {
    /// Normalized identifier, for example `github.com/owner/repo`, or the identifier the user
    /// declared explicitly for a directory without a usable Git remote.
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public var description: String {
        value
    }

    /// `kSecAttrService` of every secret of this repository. One service per repository lets a
    /// single query enumerate the repository's secrets; the secret name is `kSecAttrAccount`.
    public var keychainService: String {
        SecChainSharedConfig.keychainServicePrefix + value
    }

    /// Inverse of `keychainService`, used when enumerating every repository known to the
    /// Keychain. Returns `nil` for services that do not belong to a repository.
    public init?(keychainService: String) {
        guard keychainService.hasPrefix(SecChainSharedConfig.keychainServicePrefix) else {
            return nil
        }
        self.value = String(keychainService.dropFirst(SecChainSharedConfig.keychainServicePrefix.count))
    }
}

/// Why a directory could not be mapped to a repository identity. SecChain refuses to guess in
/// these cases, because a guessed identity would silently split or merge secrets.
public enum RepositoryIdentityError: Error, Equatable, CustomStringConvertible {
    /// The directory is not inside a Git repository and declares no explicit identifier.
    case notAGitRepository(directory: String)
    /// The Git repository has no `origin` remote and declares no explicit identifier.
    case noOriginRemote(directory: String)
    /// The `origin` remote points to something that is not stable across Macs (a local path).
    /// The URL is reported without credentials.
    case unstableRemote(sanitizedRemoteURL: String)
    /// The `git` executable could not be run.
    case gitUnavailable(reason: String)

    public var description: String {
        switch self {
        case .notAGitRepository(let directory):
            "\(directory) is not inside a Git repository. Run secchain inside a repository, or declare an identifier in the secret definition file."
        case .noOriginRemote(let directory):
            "The Git repository at \(directory) has no 'origin' remote, so it cannot be identified on other Macs. Add the remote, or declare an identifier in the secret definition file."
        case .unstableRemote(let sanitizedRemoteURL):
            "The 'origin' remote (\(sanitizedRemoteURL)) is a local path, which differs between Macs. Declare an identifier in the secret definition file."
        case .gitUnavailable(let reason):
            "git could not be run: \(reason)"
        }
    }
}

/// Pure normalization rules for Git remote URLs.
public enum RepositoryRemoteURL {
    /// Maps the spellings of one remote (`git@host:owner/repo.git`, `https://host/owner/repo`,
    /// `ssh://git@host:22/owner/repo/`, with or without credentials, in any letter case) to one
    /// identifier `host/owner/repo`. Returns `nil` for remotes that are local paths.
    ///
    /// Letter case is folded because the large hosting services treat owner and repository names
    /// case-insensitively; keeping the case would split one repository's secrets in two when two
    /// clones were made with different spellings.
    public static func normalizedIdentifier(remoteURL: String) -> String? {
        let trimmedRemoteURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hostAndPath = hostAndPath(remoteURL: trimmedRemoteURL) else {
            return nil
        }
        let pathComponents = hostAndPath.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !hostAndPath.host.isEmpty, !pathComponents.isEmpty else {
            return nil
        }
        var identifier = ([hostAndPath.host] + pathComponents).joined(separator: "/").lowercased()
        if identifier.hasSuffix(".git") {
            identifier.removeLast(".git".count)
        }
        return identifier
    }

    /// The remote URL without user name, password, or token, for use in messages.
    public static func sanitized(remoteURL: String) -> String {
        guard let hostAndPath = hostAndPath(remoteURL: remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            // Local paths carry no credentials.
            return remoteURL
        }
        return hostAndPath.host + "/" + hostAndPath.path.drop(while: { $0 == "/" })
    }

    /// Splits a network remote into host (without user info and port) and path. `nil` means the
    /// remote is a local path or a `file:` URL.
    static func hostAndPath(remoteURL: String) -> (host: String, path: String)? {
        if let schemeRange = remoteURL.range(of: "://") {
            guard remoteURL[..<schemeRange.lowerBound].lowercased() != "file" else {
                return nil
            }
            let afterScheme = remoteURL[schemeRange.upperBound...]
            guard let firstSlash = afterScheme.firstIndex(of: "/") else {
                return nil
            }
            return (
                host: hostWithoutUserInfoAndPort(authority: String(afterScheme[..<firstSlash])),
                path: String(afterScheme[firstSlash...])
            )
        }
        // scp-like syntax `[user@]host:path`. A colon that comes after a slash belongs to a local
        // path, and a single letter before the colon would be a Windows drive, not a host.
        guard
            let colon = remoteURL.firstIndex(of: ":"),
            !remoteURL[..<colon].contains("/"),
            remoteURL[..<colon].count > 1
        else {
            return nil
        }
        return (
            host: hostWithoutUserInfoAndPort(authority: String(remoteURL[..<colon])),
            path: String(remoteURL[remoteURL.index(after: colon)...])
        )
    }

    static func hostWithoutUserInfoAndPort(authority: String) -> String {
        let hostAndPort = authority.split(separator: "@").last.map(String.init) ?? authority
        return hostAndPort.split(separator: ":").first.map(String.init) ?? hostAndPort
    }
}
