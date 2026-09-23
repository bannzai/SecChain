#if os(macOS)
import Foundation
import Testing

@testable import SecChainCore

/// These tests run the real `git` against throwaway repositories, because the behavior under test
/// is exactly how `git` answers from sub-directories, worktrees, and non-repositories.
@Suite
struct RepositoryIdentityResolverTests {
    /// What an absent `~/.secchain` declares.
    let emptyUserDefinition: UserDefinition

    // Parsing can throw, so the property is set by a throwing initializer, which Swift Testing
    // allows for a suite.
    init() throws {
        emptyUserDefinition = try UserDefinitionText.parse(text: "")
    }

    @Test
    func originRemoteIdentifiesTheRepository() throws {
        let repository = try makeRepository(originRemoteURL: "git@github.com:bannzai/SecChain.git")
        #expect(
            try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil, userDefinition: emptyUserDefinition).value
                == "github.com/bannzai/secchain"
        )
    }

    @Test
    func subdirectoryResolvesToTheSameRepository() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/bannzai/SecChain.git")
        let subdirectory = repository.appendingPathComponent("Sources/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        #expect(
            try RepositoryIdentityResolver.resolve(directory: subdirectory, explicitIdentifier: nil, userDefinition: emptyUserDefinition).value
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
            try RepositoryIdentityResolver.resolve(directory: worktree, explicitIdentifier: nil, userDefinition: emptyUserDefinition).value
                == "github.com/bannzai/secchain"
        )
    }

    @Test
    func repositoryWithoutOriginIsAnError() throws {
        let repository = try makeRepository(originRemoteURL: nil)
        #expect(throws: RepositoryIdentityError.noOriginRemote(directory: repository.path)) {
            try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil, userDefinition: emptyUserDefinition)
        }
    }

    @Test
    func localPathRemoteIsAnError() throws {
        let repository = try makeRepository(originRemoteURL: "/Users/someone/src/example.git")
        #expect(throws: RepositoryIdentityError.unstableRemote(sanitizedRemoteURL: "/Users/someone/src/example.git")) {
            try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil, userDefinition: emptyUserDefinition)
        }
    }

    @Test
    func directoryOutsideGitIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        #expect(throws: RepositoryIdentityError.notAGitRepository(directory: directory.path)) {
            try RepositoryIdentityResolver.resolve(directory: directory, explicitIdentifier: nil, userDefinition: emptyUserDefinition)
        }
    }

    @Test
    func explicitIdentifierWinsAndWorksOutsideGit() throws {
        #expect(
            try RepositoryIdentityResolver.resolve(
                directory: try makeTemporaryDirectory(),
                explicitIdentifier: "my-notes",
                userDefinition: emptyUserDefinition
            ).value == "my-notes"
        )
    }

    /// The hole `@repository` left open: a clone of an unknown repository could name itself after
    /// one of the user's and receive every scope an `@allow` wildcard passes to the user's
    /// repositories. The identity comes from what `git clone` recorded and from `~/.secchain`,
    /// never from a file of the working tree.
    @Test
    func aFileInTheRepositoryCannotChangeItsIdentity() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/stranger/cloned.git")
        try "@repository github.com/bannzai/anything\n".write(
            to: SecretDefinitionFile.url(workingTreeRoot: repository),
            atomically: true,
            encoding: .utf8
        )
        let userDefinition = try UserDefinitionText.parse(text: "OPENAI_API_KEY\n@allow github.com/bannzai/*\n")
        let repositoryIdentity = try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil, userDefinition: userDefinition)
        #expect(repositoryIdentity.value == "github.com/stranger/cloned")
        #expect(userDefinition.passedScopes(repositoryIdentity: repositoryIdentity) == [.repository(repositoryIdentity)])
    }

    @Test
    func aPathOfTheUserDefinitionIdentifiesADirectoryWithoutARemoteAndEverythingBelowIt() throws {
        let directory = try makeTemporaryDirectory()
        let subdirectory = directory.appendingPathComponent("drafts/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let userDefinition = try UserDefinitionText.parse(text: "@path \(directory.path) local/notes\n")
        for resolvedDirectory in [directory, subdirectory] {
            #expect(
                try RepositoryIdentityResolver.resolve(directory: resolvedDirectory, explicitIdentifier: nil, userDefinition: userDefinition).value
                    == "local/notes"
            )
        }
    }

    @Test
    func aPathWinsOverTheOriginRemoteOfARepositoryInsideIt() throws {
        let repository = try makeRepository(originRemoteURL: "https://github.com/bannzai/SecChain.git")
        let userDefinition = try UserDefinitionText.parse(text: "@path \(repository.path) local/notes\n")
        #expect(
            try RepositoryIdentityResolver.resolve(directory: repository, explicitIdentifier: nil, userDefinition: userDefinition).value
                == "local/notes"
        )
    }

    @Test
    func anAliasMakesAForkItsUpstreamAndAppliesToAnExplicitIdentifierToo() throws {
        let fork = try makeRepository(originRemoteURL: "git@github.com:bannzai/some-fork.git")
        let userDefinition = try UserDefinitionText.parse(text: "@alias github.com/bannzai/some-fork github.com/upstream/some-repo\n")
        #expect(
            try RepositoryIdentityResolver.resolve(directory: fork, explicitIdentifier: nil, userDefinition: userDefinition).value
                == "github.com/upstream/some-repo"
        )
        #expect(
            try RepositoryIdentityResolver.resolve(
                directory: try makeTemporaryDirectory(),
                explicitIdentifier: "github.com/bannzai/some-fork",
                userDefinition: userDefinition
            ).value == "github.com/upstream/some-repo"
        )
    }

    /// An upstream written the way the hosting service shows it, as `@alias` of a fork or as `@path`
    /// of a directory without a remote, is the repository of the upstream's own checkout: the same
    /// repository scope, and so the same Keychain items.
    @Test
    func anUpstreamSpelledInAnotherLetterCaseIsTheRepositoryOfItsCheckout() throws {
        let upstream = try makeRepository(originRemoteURL: "https://github.com/Upstream/Some-Repo.git")
        let fork = try makeRepository(originRemoteURL: "git@github.com:bannzai/some-fork.git")
        let copy = try makeTemporaryDirectory()
        let userDefinition = try UserDefinitionText.parse(
            text: "@alias github.com/bannzai/some-fork github.com/Upstream/Some-Repo\n@path \(copy.path) GitHub.com/Upstream/Some-Repo\n"
        )
        let upstreamScope = SecretScope.repository(
            try RepositoryIdentityResolver.resolve(directory: upstream, explicitIdentifier: nil, userDefinition: userDefinition)
        )
        for directory in [fork, copy] {
            #expect(
                SecretScope.repository(try RepositoryIdentityResolver.resolve(directory: directory, explicitIdentifier: nil, userDefinition: userDefinition))
                    == upstreamScope
            )
        }
        #expect(upstreamScope == .repository(RepositoryIdentity(value: "github.com/upstream/some-repo")))
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
