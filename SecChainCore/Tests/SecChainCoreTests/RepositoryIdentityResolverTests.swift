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
            try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil).value
                == "github.com/bannzai/secchain"
        )
    }

    @Test
    func subdirectoryResolvesToTheSameRepository() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/bannzai/SecChain.git")
        let subdirectory = repository.appendingPathComponent("Sources/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        #expect(
            try RepositoryIdentityResolver.resolve(directory: subdirectory, explicitIdentifier: nil).value
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
            try RepositoryIdentityResolver.resolve(directory: worktree, explicitIdentifier: nil).value
                == "github.com/bannzai/secchain"
        )
    }

    @Test
    func repositoryWithoutOriginIsAnError() throws {
        let repository = try makeRepository(originRemoteURL: nil)
        #expect(throws: RepositoryIdentityError.noOriginRemote(directory: repository.path)) {
            try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil)
        }
    }

    @Test
    func localPathRemoteIsAnError() throws {
        let repository = try makeRepository(originRemoteURL: "/Users/someone/src/example.git")
        #expect(throws: RepositoryIdentityError.unstableRemote(sanitizedRemoteURL: "/Users/someone/src/example.git")) {
            try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil)
        }
    }

    @Test
    func directoryOutsideGitIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        #expect(throws: RepositoryIdentityError.notAGitRepository(directory: directory.path)) {
            try RepositoryIdentityResolver.resolve(directory: directory, explicitIdentifier: nil)
        }
    }

    @Test
    func explicitIdentifierWinsAndWorksOutsideGit() throws {
        #expect(
            try RepositoryIdentityResolver.resolve(directory: try makeTemporaryDirectory(), explicitIdentifier: "my-notes").value
                == "my-notes"
        )
        let repository = try makeRepository(originRemoteURL: "https://github.com/bannzai/SecChain.git")
        #expect(try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: "my-notes").value == "my-notes")
    }

    /// `--repository` spelled the way the hosting service shows the name, or in any other letter
    /// case, is the repository of a checkout of it: the same identifier, and so the same Keychain
    /// items, as the lowercase one its remote gives.
    @Test
    func anExplicitIdentifierInAnotherLetterCaseIsTheRepositoryOfItsCheckout() throws {
        let checkout = try makeRepository(originRemoteURL: "https://github.com/Bannzai/SecChain.git")
        #expect(
            try RepositoryIdentityResolver.resolve(directory: try makeTemporaryDirectory(), explicitIdentifier: "GitHub.com/Bannzai/SecChain")
                == RepositoryIdentityResolver.resolve(directory: checkout, explicitIdentifier: nil)
        )
        #expect(try RepositoryIdentityResolver.resolve(directory: try makeTemporaryDirectory(), explicitIdentifier: "My-Notes").value == "my-notes")
    }

    /// The hole `@repository` left open: a clone of an unknown repository could name itself after
    /// one of the user's and receive every scope an `@allow` wildcard passes to the user's
    /// repositories. The identity comes from what `git clone` recorded, never from a file of the
    /// working tree.
    @Test
    func aFileInTheRepositoryCannotChangeItsIdentity() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/stranger/cloned.git")
        try "@repository github.com/bannzai/anything\n".write(
            to: SecretDefinitionFile.url(workingTreeRoot: repository),
            atomically: true,
            encoding: .utf8
        )
        let userDefinition = try UserDefinitionText.parse(text: "OPENAI_API_KEY\n@allow github.com/bannzai/*\n")
        let repositoryIdentity = try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil)
        #expect(repositoryIdentity.value == "github.com/stranger/cloned")
        #expect(userDefinition.passedScopes(repositoryIdentity: repositoryIdentity) == [.repository(repositoryIdentity)])
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

    /// The `.secchain` that the command-line tool and the macOS app both read for a directory: the
    /// one of its working tree root, or of the directory itself outside Git, and none when that
    /// file is `~/.secchain`.
    @Test
    func theDefinitionFileOfADirectoryIsTheOneOfItsWorkingTreeOrItself() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/bannzai/SecChain.git")
        let subdirectory = repository.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let plain = try makeTemporaryDirectory()
        let home = try makeTemporaryDirectory()
        for (directory, definitionDirectory) in [(subdirectory, repository), (plain, plain)] {
            #expect(
                try RepositoryIdentityResolver.definitionDirectory(directory: directory, homeDirectory: home)?.resolvingSymlinksInPath().path
                    == definitionDirectory.resolvingSymlinksInPath().path
            )
        }
        #expect(try RepositoryIdentityResolver.definitionDirectory(directory: home, homeDirectory: home) == nil)
    }

    /// A folder chosen in the macOS app whose `.secchain` still has the `@repository` of an earlier
    /// build is refused, as every `secchain` command refuses it, instead of becoming the fork's own
    /// repository without a word.
    @Test
    func theDefinitionOfAFolderWithTheRemovedDirectiveIsRefused() throws {
        let fork = try makeRepository(originRemoteURL: "git@github.com:bannzai/some-fork.git")
        let subdirectory = fork.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        #expect(try RepositoryIdentityResolver.definition(directory: subdirectory, homeDirectory: try makeTemporaryDirectory()) == nil)
        try "@repository github.com/upstream/some-repo\n".write(
            to: SecretDefinitionFile.url(workingTreeRoot: fork),
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: SecretDefinitionError.repositoryDirectiveRemoved(lineNumber: 1)) {
            try RepositoryIdentityResolver.definition(directory: subdirectory, homeDirectory: try makeTemporaryDirectory())
        }
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
