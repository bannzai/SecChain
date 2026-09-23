#if os(macOS)
import Foundation

/// Result of one `git` invocation. Only what identity resolution needs.
struct GitCommandResult {
    /// Process termination status.
    let exitCode: Int32
    /// Standard output, trimmed.
    let standardOutput: String
}

/// Resolves the identity of the repository that contains a directory by asking `git`.
/// Only available on macOS: the iOS app never resolves a working directory, it lists the
/// repositories already present in the Keychain.
public enum RepositoryIdentityResolver {
    /// Resolution order: `explicitIdentifier` (`--repository`), then the `@path` of `~/.secchain`
    /// that contains the directory, then the normalized `origin` remote. Whichever answers goes
    /// through `@alias`. Anything else is an error rather than a guess.
    ///
    /// Nothing inside the repository takes part (documents/PROJECT.md, design decision 6): the
    /// identity decides which repository's secrets and which shared scopes a command gets, and a
    /// repository's files are written by whoever wrote the repository.
    public static func resolve(directory: URL, explicitIdentifier: String?, userDefinition: UserDefinition) throws -> RepositoryIdentity {
        userDefinition.aliasedRepositoryIdentity(
            repositoryIdentity: try explicitIdentifier.flatMap { $0.isEmpty ? nil : RepositoryIdentity(value: $0) }
                ?? userDefinition.pathRepository(directory: directory)?.repositoryIdentity
                ?? originRemoteIdentity(directory: directory)
        )
    }

    /// The identity the normalized `origin` remote gives the repository that contains `directory`.
    ///
    /// `git config` is asked instead of reading `.git/config`, because it answers correctly from
    /// sub-directories and from linked worktrees, whose `.git` is a file.
    static func originRemoteIdentity(directory: URL) throws -> RepositoryIdentity {
        guard try runGit(arguments: ["rev-parse", "--is-inside-work-tree"], directory: directory).exitCode == 0 else {
            throw RepositoryIdentityError.notAGitRepository(directory: directory.path)
        }
        let originRemote = try runGit(arguments: ["config", "--get", "remote.origin.url"], directory: directory)
        guard originRemote.exitCode == 0, !originRemote.standardOutput.isEmpty else {
            throw RepositoryIdentityError.noOriginRemote(directory: directory.path)
        }
        guard let identifier = RepositoryRemoteURL.normalizedIdentifier(remoteURL: originRemote.standardOutput) else {
            throw RepositoryIdentityError.unstableRemote(
                sanitizedRemoteURL: RepositoryRemoteURL.sanitized(remoteURL: originRemote.standardOutput)
            )
        }
        return RepositoryIdentity(value: identifier)
    }

    /// Top-level directory of the working tree that contains `directory`, or `nil` outside Git.
    /// The secret definition file lives there.
    public static func workingTreeRoot(directory: URL) throws -> URL? {
        let topLevel = try runGit(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
        guard topLevel.exitCode == 0, !topLevel.standardOutput.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: topLevel.standardOutput, isDirectory: true)
    }

    static func runGit(arguments: [String], directory: URL) throws -> GitCommandResult {
        let process = Process()
        // `env` resolves git through PATH, so that the user's own git (Homebrew, Xcode) is used.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RepositoryIdentityError.gitUnavailable(reason: error.localizedDescription)
        }
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
#endif
