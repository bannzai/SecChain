#if os(macOS)
import Foundation
import Testing

@testable import SecChainCore

/// These tests run the real `git` against throwaway repositories, because the behavior under test
/// is exactly how `git` answers from sub-directories, worktrees, and non-repositories.
@Suite
struct RepositoryIdentityResolverTests {
    @Test
    func originRemoteIdentifiesTheRepository() throws {
        let repository = try makeRepository(originRemoteURL: "git@github.com:bannzai/SecChain.git")
        #expect(
            try RepositoryIdentityResolver.resolve(directory: repository, declaredIdentifier: nil).value
                == "github.com/bannzai/secchain"
        )
    }

    @Test
    func subdirectoryResolvesToTheSameRepository() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/bannzai/SecChain.git")
        let subdirectory = repository.appendingPathComponent("Sources/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        #expect(
            try RepositoryIdentityResolver.resolve(directory: subdirectory, declaredIdentifier: nil).value
                == "github.com/bannzai/secchain"
        )
    }

    @Test
    func linkedWorktreeResolvesToTheSameRepository() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/bannzai/SecChain.git")
        try git(arguments: ["commit", "--allow-empty", "-m", "initial"], directory: repository)
        let worktree = repository.deletingLastPathComponent()
            .appendingPathComponent("worktree-\(UUID().uuidString)", isDirectory: true)
        try git(arguments: ["worktree", "add", worktree.path], directory: repository)
        #expect(
            try RepositoryIdentityResolver.resolve(directory: worktree, declaredIdentifier: nil).value
                == "github.com/bannzai/secchain"
        )
    }

    @Test
    func repositoryWithoutOriginIsAnError() throws {
        let repository = try makeRepository(originRemoteURL: nil)
        #expect(throws: RepositoryIdentityError.noOriginRemote(directory: repository.path)) {
            try RepositoryIdentityResolver.resolve(directory: repository, declaredIdentifier: nil)
        }
    }

    @Test
    func localPathRemoteIsAnError() throws {
        let repository = try makeRepository(originRemoteURL: "/Users/someone/src/example.git")
        #expect(throws: RepositoryIdentityError.unstableRemote(sanitizedRemoteURL: "/Users/someone/src/example.git")) {
            try RepositoryIdentityResolver.resolve(directory: repository, declaredIdentifier: nil)
        }
    }

    @Test
    func directoryOutsideGitIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        #expect(throws: RepositoryIdentityError.notAGitRepository(directory: directory.path)) {
            try RepositoryIdentityResolver.resolve(directory: directory, declaredIdentifier: nil)
        }
    }

    @Test
    func declaredIdentifierWinsAndWorksOutsideGit() throws {
        #expect(
            try RepositoryIdentityResolver.resolve(
                directory: try makeTemporaryDirectory(),
                declaredIdentifier: "my-notes"
            ).value == "my-notes"
        )
    }

    @Test
    func workingTreeRootIsFoundFromASubdirectory() throws {
        let repository = try makeRepository(originRemoteURL: nil)
        let subdirectory = repository.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        #expect(
            try RepositoryIdentityResolver.workingTreeRoot(directory: subdirectory)?.resolvingSymlinksInPath().path
                == repository.resolvingSymlinksInPath().path
        )
        #expect(try RepositoryIdentityResolver.workingTreeRoot(directory: try makeTemporaryDirectory()) == nil)
    }

    // MARK: - Fixtures

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secchain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func makeRepository(originRemoteURL: String?) throws -> URL {
        let repository = try makeTemporaryDirectory()
        try git(arguments: ["init", "--quiet"], directory: repository)
        // Commits in the fixtures must not depend on the machine's Git identity.
        try git(arguments: ["config", "user.email", "tests@example.invalid"], directory: repository)
        try git(arguments: ["config", "user.name", "SecChain Tests"], directory: repository)
        try git(arguments: ["config", "commit.gpgsign", "false"], directory: repository)
        if let originRemoteURL {
            try git(arguments: ["remote", "add", "origin", originRemoteURL], directory: repository)
        }
        return repository
    }

    func git(arguments: [String], directory: URL) throws {
        let result = try RepositoryIdentityResolver.runGit(arguments: arguments, directory: directory)
        try #require(result.exitCode == 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
#endif
