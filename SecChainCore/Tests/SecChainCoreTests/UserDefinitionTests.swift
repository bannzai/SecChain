import Foundation
import Testing

@testable import SecChainCore

@Suite
struct UserDefinitionTests {
    /// The example of the file format (documents/PROJECT.md, "The user's definition file"), with a
    /// second custom scope.
    let exampleText = """
        # user scope
        OPENAI_API_KEY
        ANTHROPIC_API_KEY
        @allow github.com/bannzai/*

        @scope youtube
        YOUTUBE_API_KEY
        @allow github.com/bannzai/youtuber
        @allow github.com/bannzai/shorts-*

        @scope video
        YOUTUBE_API_KEY
        @allow github.com/bannzai/youtuber

        @alias github.com/bannzai/some-fork github.com/upstream/some-repo
        @path /Users/bannzai/notes local/notes
        """

    func name(_ rawName: String) throws -> SecretName {
        // The label is omitted because every call site passes a literal name.
        try #require(SecretName(rawName: rawName))
    }

    func customScope(_ rawName: String) throws -> SharedScope {
        // The label is omitted because every call site passes a literal name.
        .custom(try #require(CustomScopeName(rawName: rawName)))
    }

    // MARK: - Parsing

    @Test
    func theLinesBeforeTheFirstScopeAreTheUserScope() throws {
        let userDefinition = try UserDefinitionText.parse(text: "# user scope\nOPENAI_API_KEY\n@allow github.com/bannzai/*\n@scope youtube\nYOUTUBE_API_KEY\n")
        #expect(userDefinition.userScope == ScopeDefinition(scope: .user, secretNames: [try name("OPENAI_API_KEY")], allowPatterns: ["github.com/bannzai/*"]))
        #expect(userDefinition.customScopes == [ScopeDefinition(scope: try customScope("youtube"), secretNames: [try name("YOUTUBE_API_KEY")], allowPatterns: [])])
    }

    @Test
    func customScopesKeepTheOrderOfTheFile() throws {
        #expect(try UserDefinitionText.parse(text: exampleText).customScopes.map(\.scope) == [try customScope("youtube"), try customScope("video")])
    }

    @Test
    func anEmptyFileDeclaresNothingAndPassesNothing() throws {
        let userDefinition = try UserDefinitionText.parse(text: "")
        #expect(userDefinition.userScope == ScopeDefinition(scope: .user, secretNames: [], allowPatterns: []))
        #expect(userDefinition.customScopes.isEmpty)
        #expect(userDefinition.passedScopes(repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/a")) == [.repository(RepositoryIdentity(value: "github.com/bannzai/a"))])
    }

    @Test
    func aLineWithAValueIsRejectedWithoutEchoingIt() {
        #expect(throws: UserDefinitionError.valueNotAllowed(lineNumber: 2)) {
            try UserDefinitionText.parse(text: "OPENAI_API_KEY\nOPENAI_API_KEY=dummy-value-for-test\n")
        }
        #expect(!UserDefinitionError.valueNotAllowed(lineNumber: 2).description.contains("dummy-value-for-test"))
    }

    @Test
    func theBuiltInScopesAndMalformedNamesAreNotCustomScopes() {
        for text in ["@scope user", "@scope repository", "@scope YouTube", "@scope -youtube"] {
            #expect(throws: UserDefinitionError.invalidScopeName(lineNumber: 1)) {
                try UserDefinitionText.parse(text: text)
            }
        }
    }

    @Test
    func aStarOnlyEndsAPattern() {
        for text in ["@allow github.com/*/repo", "@allow *repo", "@allow", "@allow github.com/a/b github.com/a/c", "@allow **"] {
            #expect(throws: UserDefinitionError.invalidAllowPattern(lineNumber: 1)) {
                try UserDefinitionText.parse(text: text)
            }
        }
    }

    /// A `=` would make the `@allow` line one that the parser refuses as a value, and the file would
    /// then refuse every command, `scope deny` included.
    @Test
    func aPatternThatWouldMakeTheFileUnreadableIsRefusedBeforeItIsWritten() {
        #expect(!isValidRepositoryPattern(pattern: "local/app=v2"))
        #expect(!isValidRepositoryPattern(pattern: "github.com/a b"))
        #expect(isValidRepositoryPattern(pattern: "github.com/bannzai/*"))
        #expect(throws: UserDefinitionError.self) {
            try UserDefinitionText.adding(allowPattern: "local/app=v2", scope: .user, text: "OPENAI_API_KEY\n")
        }
    }

    @Test
    func aliasesAndPathsBelongToNoScopeWhereverTheyAreWritten() throws {
        let userDefinition = try UserDefinitionText.parse(text: exampleText)
        #expect(userDefinition.upstreamRepositoryIdentities == ["github.com/bannzai/some-fork": RepositoryIdentity(value: "github.com/upstream/some-repo")])
        #expect(userDefinition.pathRepositoryIdentities == ["/Users/bannzai/notes": RepositoryIdentity(value: "local/notes")])
        #expect(userDefinition.scopeDefinition(scope: try customScope("video"))?.secretNames.map(\.value) == ["YOUTUBE_API_KEY"])
        #expect(userDefinition.scopeDefinition(scope: try customScope("video"))?.allowPatterns == ["github.com/bannzai/youtuber"])
    }

    @Test
    func unknownOrIncompleteDirectivesAreRejected() {
        for text in ["@repository github.com/bannzai/anything", "@unknown value", "@alias github.com/a/fork", "@path /Users/someone/notes", "@path notes local/notes", "@scope", "@scope a b"] {
            #expect(throws: UserDefinitionError.invalidDirective(lineNumber: 1)) {
                try UserDefinitionText.parse(text: text)
            }
        }
    }

    @Test
    func aSecondDeclarationOfOneScopeForkOrDirectoryIsRejected() {
        #expect(throws: UserDefinitionError.duplicateDeclaration(lineNumber: 3)) {
            try UserDefinitionText.parse(text: "@scope youtube\nA\n@scope youtube\n")
        }
        #expect(throws: UserDefinitionError.duplicateDeclaration(lineNumber: 2)) {
            try UserDefinitionText.parse(text: "@alias github.com/a/fork github.com/b/one\n@alias github.com/A/Fork github.com/b/two\n")
        }
        #expect(throws: UserDefinitionError.duplicateDeclaration(lineNumber: 2)) {
            try UserDefinitionText.parse(text: "@path /Users/someone/notes one\n@path /Users/someone/notes two\n")
        }
    }

    @Test
    func invalidNamesAreRejected() {
        #expect(throws: UserDefinitionError.invalidSecretName(lineNumber: 1)) {
            try UserDefinitionText.parse(text: "MY-KEY")
        }
        #expect(throws: UserDefinitionError.invalidSecretName(lineNumber: 1)) {
            try UserDefinitionText.parse(text: "MY KEY")
        }
    }

    // MARK: - Which scopes a repository gets

    @Test(arguments: ["github.com/bannzai/youtuber", "github.com/bannzai/shorts-2026", "github.com/Bannzai/YouTuber"])
    func aScopeIsPassedToTheRepositoriesItsPatternsName(identifier: String) throws {
        #expect(
            try UserDefinitionText.parse(text: exampleText)
                .passedScopes(repositoryIdentity: RepositoryIdentity(value: identifier))
                .contains(.shared(try customScope("youtube")))
        )
    }

    @Test(arguments: ["github.com/bannzai/other", "github.com/bannzai/youtuber-fork", "github.com/someone/youtuber", "gitlab.com/bannzai/youtuber"])
    func aScopeIsNotPassedToAnyOtherRepository(identifier: String) throws {
        #expect(
            !(try UserDefinitionText.parse(text: exampleText)
                .passedScopes(repositoryIdentity: RepositoryIdentity(value: identifier))
                .contains(.shared(try customScope("youtube"))))
        )
    }

    /// A wildcard ends where it is written: `github.com/bannzai/*` names the owner `bannzai` only.
    @Test
    func aWildcardStopsAtTheOwner() {
        #expect(repositoryPatternMatches(pattern: "github.com/bannzai/*", repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/x")))
        #expect(!repositoryPatternMatches(pattern: "github.com/bannzai/*", repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai-other/x")))
        #expect(!repositoryPatternMatches(pattern: "github.com/bannzai/*", repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai")))
        #expect(!repositoryPatternMatches(pattern: "github.com/bannzai/x", repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/x2")))
        #expect(repositoryPatternMatches(pattern: "*", repositoryIdentity: RepositoryIdentity(value: "local/notes")))
    }

    /// What `scope deny` checks before it says a scope no longer reaches what the removed line named:
    /// a remaining pattern that names some of it, wider or narrower, in any letter case.
    @Test
    func patternsOverlapWhenARepositoryCanBeNamedByBoth() {
        for (pattern, otherPattern) in [
            ("github.com/*", "github.com/bannzai/*"),
            ("GitHub.com/bannzai/*", "github.com/bannzai/*"),
            ("github.com/bannzai/*", "github.com/bannzai/youtuber"),
            ("github.com/Bannzai/YouTuber", "github.com/bannzai/youtuber"),
            ("*", "local/notes"),
        ] {
            #expect(repositoryPatternsOverlap(pattern: pattern, otherPattern: otherPattern))
            #expect(repositoryPatternsOverlap(pattern: otherPattern, otherPattern: pattern))
        }
        for (pattern, otherPattern) in [
            ("github.com/bannzai/*", "github.com/bannzai-other/*"),
            ("github.com/bannzai/*", "github.com/bannzai-other/youtuber"),
            ("github.com/bannzai/youtuber", "github.com/bannzai/tutorials"),
        ] {
            #expect(!repositoryPatternsOverlap(pattern: pattern, otherPattern: otherPattern))
            #expect(!repositoryPatternsOverlap(pattern: otherPattern, otherPattern: pattern))
        }
    }

    @Test
    func aScopeWithoutAllowIsPassedToNoRepository() throws {
        let userDefinition = try UserDefinitionText.parse(text: "OPENAI_API_KEY\n@scope youtube\nYOUTUBE_API_KEY\n")
        #expect(
            userDefinition.passedScopes(repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/youtuber"))
                == [.repository(RepositoryIdentity(value: "github.com/bannzai/youtuber"))]
        )
    }

    /// The repository's own scope first, then the custom scopes in the order of the file, then the
    /// user scope.
    @Test
    func passedScopesAreInTheOrderOfPrecedence() throws {
        let repositoryIdentity = RepositoryIdentity(value: "github.com/bannzai/youtuber")
        #expect(
            try UserDefinitionText.parse(text: exampleText).passedScopes(repositoryIdentity: repositoryIdentity)
                == [.repository(repositoryIdentity), .shared(try customScope("youtube")), .shared(try customScope("video")), .shared(.user)]
        )
        #expect(
            try UserDefinitionText.parse(text: exampleText).passedScopes(repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/other"))
                == [.repository(RepositoryIdentity(value: "github.com/bannzai/other")), .shared(.user)]
        )
    }

    // MARK: - Identity

    @Test
    func anAliasTurnsAForkIntoItsUpstreamOnce() throws {
        let userDefinition = try UserDefinitionText.parse(
            text: "@alias github.com/bannzai/some-fork github.com/upstream/some-repo\n@alias github.com/upstream/some-repo github.com/elsewhere/repo\n"
        )
        #expect(
            userDefinition.aliasedRepositoryIdentity(repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/some-fork"))
                == RepositoryIdentity(value: "github.com/upstream/some-repo")
        )
        #expect(
            userDefinition.aliasedRepositoryIdentity(repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/other"))
                == RepositoryIdentity(value: "github.com/bannzai/other")
        )
    }

    /// The identifier of a Git remote is lowercase and the Keychain compares services
    /// case-sensitively, so an upstream or an identifier spelled the way a hosting service shows it
    /// is folded too. The directory of `@path` is a path, which keeps its letter case.
    @Test
    func theUpstreamOfAnAliasAndTheIdentifierOfAPathAreFoldedToLowercase() throws {
        let userDefinition = try UserDefinitionText.parse(
            text: "@alias GitHub.com/bannzai/Some-Fork github.com/Upstream/Some-Repo\n@path /Users/someone/Notes Local/Notes\n"
        )
        #expect(userDefinition.upstreamRepositoryIdentities == ["github.com/bannzai/some-fork": RepositoryIdentity(value: "github.com/upstream/some-repo")])
        #expect(userDefinition.pathRepositoryIdentities == ["/Users/someone/Notes": RepositoryIdentity(value: "local/notes")])
    }

    @Test
    func aPathNamesItsDirectoryAndEverythingBelowItButNotASiblingWithTheSamePrefix() throws {
        let root = try makeTemporaryDirectory()
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let drafts = notes.appendingPathComponent("drafts", isDirectory: true)
        let sibling = root.appendingPathComponent("notes-old", isDirectory: true)
        for directory in [drafts, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let userDefinition = try UserDefinitionText.parse(text: "@path \(notes.path) local/notes\n@path \(drafts.path) local/drafts\n")
        #expect(userDefinition.pathRepository(directory: notes)?.repositoryIdentity == RepositoryIdentity(value: "local/notes"))
        // The most specific path wins.
        #expect(userDefinition.pathRepository(directory: drafts)?.repositoryIdentity == RepositoryIdentity(value: "local/drafts"))
        #expect(userDefinition.pathRepository(directory: sibling) == nil)
        #expect(userDefinition.pathRepository(directory: root) == nil)
    }

    @Test
    func aPathWithASpaceNeedsNoQuotingAndALinkLeadsToItsDirectory() throws {
        let root = try makeTemporaryDirectory()
        let notes = root.appendingPathComponent("My Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link-to-notes", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: notes)
        let userDefinition = try UserDefinitionText.parse(text: "@path \(link.path) local/notes\n")
        #expect(userDefinition.pathRepositoryIdentities == [link.path: RepositoryIdentity(value: "local/notes")])
        #expect(userDefinition.pathRepository(directory: notes)?.repositoryIdentity == RepositoryIdentity(value: "local/notes"))
        #expect(try UserDefinitionText.parse(text: "@path \(notes.path)   local/notes").pathRepositoryIdentities == [notes.path: RepositoryIdentity(value: "local/notes")])
    }

    // MARK: - Editing

    @Test
    func addingANameToTheUserScopeGoesBeforeTheFirstScope() throws {
        let added = try UserDefinitionText.adding(secretName: try name("GITHUB_TOKEN"), scope: .user, text: exampleText)
        let userDefinition = try UserDefinitionText.parse(text: added)
        #expect(userDefinition.userScope.secretNames.map(\.value) == ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN"])
        #expect(userDefinition.customScopes == (try UserDefinitionText.parse(text: exampleText)).customScopes)
        #expect(added.components(separatedBy: "\n").prefix(5) == ["# user scope", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "@allow github.com/bannzai/*", "GITHUB_TOKEN"])
    }

    @Test
    func addingANameToACustomScopeGoesToThatScopeOnly() throws {
        let added = try UserDefinitionText.adding(secretName: try name("YOUTUBE_CHANNEL_ID"), scope: try customScope("youtube"), text: exampleText)
        let userDefinition = try UserDefinitionText.parse(text: added)
        #expect(userDefinition.scopeDefinition(scope: try customScope("youtube"))?.secretNames.map(\.value) == ["YOUTUBE_API_KEY", "YOUTUBE_CHANNEL_ID"])
        #expect(userDefinition.scopeDefinition(scope: try customScope("video"))?.secretNames.map(\.value) == ["YOUTUBE_API_KEY"])
        #expect(try UserDefinitionText.adding(secretName: try name("YOUTUBE_CHANNEL_ID"), scope: try customScope("youtube"), text: added) == added)
    }

    @Test
    func addingToACustomScopeWithoutASectionCreatesIt() throws {
        let added = try UserDefinitionText.adding(secretName: try name("CLOUDFLARE_API_TOKEN"), scope: try customScope("cloudflare"), text: "OPENAI_API_KEY\n")
        #expect(added == "OPENAI_API_KEY\n\n@scope cloudflare\nCLOUDFLARE_API_TOKEN\n")
        #expect(try UserDefinitionText.parse(text: added).scopeDefinition(scope: try customScope("cloudflare"))?.secretNames.map(\.value) == ["CLOUDFLARE_API_TOKEN"])
    }

    @Test
    func addingWithoutAFileCreatesItWithAHeader() throws {
        let userScopeText = try UserDefinitionText.adding(secretName: try name("OPENAI_API_KEY"), scope: .user, text: nil)
        #expect(userScopeText.hasPrefix("# SecChain"))
        #expect(try UserDefinitionText.parse(text: userScopeText).userScope.secretNames.map(\.value) == ["OPENAI_API_KEY"])
        let customScopeText = try UserDefinitionText.adding(allowPattern: "github.com/bannzai/youtuber", scope: try customScope("youtube"), text: nil)
        #expect(customScopeText.hasPrefix("# SecChain"))
        #expect(try UserDefinitionText.parse(text: customScopeText).scopeDefinition(scope: try customScope("youtube"))?.allowPatterns == ["github.com/bannzai/youtuber"])
    }

    @Test
    func removingANameLeavesTheSameNameOfAnotherScope() throws {
        let removed = try UserDefinitionText.removing(secretName: try name("YOUTUBE_API_KEY"), scope: try customScope("video"), text: exampleText)
        let userDefinition = try UserDefinitionText.parse(text: removed)
        #expect(userDefinition.scopeDefinition(scope: try customScope("video"))?.secretNames == [])
        #expect(userDefinition.scopeDefinition(scope: try customScope("youtube"))?.secretNames.map(\.value) == ["YOUTUBE_API_KEY"])
        #expect(try UserDefinitionText.removing(secretName: try name("YOUTUBE_API_KEY"), scope: try customScope("video"), text: removed) == removed)
    }

    @Test
    func allowingAndDenyingEditOnlyThatLineAndAreIdempotent() throws {
        let allowed = try UserDefinitionText.adding(allowPattern: "github.com/bannzai/tutorials", scope: try customScope("video"), text: exampleText)
        #expect(try UserDefinitionText.adding(allowPattern: "github.com/bannzai/tutorials", scope: try customScope("video"), text: allowed) == allowed)
        #expect(
            try UserDefinitionText.parse(text: allowed).scopeDefinition(scope: try customScope("video"))?.allowPatterns
                == ["github.com/bannzai/youtuber", "github.com/bannzai/tutorials"]
        )
        let denied = try UserDefinitionText.removing(allowPattern: "github.com/bannzai/youtuber", scope: try customScope("video"), text: allowed)
        #expect(try UserDefinitionText.parse(text: denied).scopeDefinition(scope: try customScope("video"))?.allowPatterns == ["github.com/bannzai/tutorials"])
        // The same pattern of another scope stays.
        #expect(try UserDefinitionText.parse(text: denied).scopeDefinition(scope: try customScope("youtube"))?.allowPatterns.contains("github.com/bannzai/youtuber") == true)
        #expect(try UserDefinitionText.removing(allowPattern: "github.com/bannzai/youtuber", scope: try customScope("video"), text: denied) == denied)
    }

    @Test
    func anAllowGoesWithTheLinesOfItsScopeRatherThanAfterAnAliasThatFollowsThem() throws {
        #expect(
            try UserDefinitionText.adding(allowPattern: "github.com/bannzai/tutorials", scope: try customScope("video"), text: exampleText).hasSuffix(
                "@scope video\nYOUTUBE_API_KEY\n@allow github.com/bannzai/youtuber\n@allow github.com/bannzai/tutorials\n\n@alias github.com/bannzai/some-fork github.com/upstream/some-repo\n@path /Users/bannzai/notes local/notes\n"
            )
        )
    }

    @Test
    func editsKeepTheUsersCommentsAndOrder() throws {
        let text = "# mine\nB_KEY\n# about a\nA_KEY\n\n# youtube credentials\n@scope youtube\n# the channel\nYOUTUBE_API_KEY\n"
        let edited = try UserDefinitionText.adding(allowPattern: "github.com/bannzai/*", scope: .user, text: text)
        #expect(edited == "# mine\nB_KEY\n# about a\nA_KEY\n@allow github.com/bannzai/*\n\n# youtube credentials\n@scope youtube\n# the channel\nYOUTUBE_API_KEY\n")
        #expect(try UserDefinitionText.removing(allowPattern: "github.com/bannzai/*", scope: .user, text: edited) == text)
    }

    @Test
    func aNameIsAddedAfterTheOpeningCommentsWhenTheUserScopeHasNoEntry() throws {
        #expect(
            try UserDefinitionText.adding(secretName: try name("OPENAI_API_KEY"), scope: .user, text: "# header\n\n@scope youtube\nYOUTUBE_API_KEY\n")
                == "# header\nOPENAI_API_KEY\n\n@scope youtube\nYOUTUBE_API_KEY\n"
        )
    }

    @Test
    func aFileThisVersionCannotReadIsNotEdited() throws {
        #expect(throws: UserDefinitionError.invalidDirective(lineNumber: 1)) {
            try UserDefinitionText.adding(secretName: try name("A"), scope: .user, text: "@unknown\n")
        }
        #expect(throws: UserDefinitionError.invalidDirective(lineNumber: 1)) {
            try UserDefinitionText.removing(allowPattern: "github.com/a/*", scope: .user, text: "@unknown\n")
        }
    }

    // MARK: - File

    #if os(macOS)
    @Test
    func theFileIsReadFromTheHomeDirectoryAndWrittenThroughALink() throws {
        let homeDirectory = try makeTemporaryDirectory()
        #expect(try UserDefinitionFile.readText(homeDirectory: homeDirectory) == nil)
        // The shape of dotfiles kept in a repository: `~/.secchain` is a link into it.
        let dotfiles = try makeTemporaryDirectory()
        let dotfilesSecChain = dotfiles.appendingPathComponent(".secchain", isDirectory: false)
        try "OPENAI_API_KEY\n".write(to: dotfilesSecChain, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: UserDefinitionFile.url(homeDirectory: homeDirectory), withDestinationURL: dotfilesSecChain)
        try UserDefinitionFile.write(text: "OPENAI_API_KEY\n@allow github.com/bannzai/*\n", homeDirectory: homeDirectory)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: UserDefinitionFile.url(homeDirectory: homeDirectory).path) == dotfilesSecChain.path)
        #expect(try String(contentsOf: dotfilesSecChain, encoding: .utf8) == "OPENAI_API_KEY\n@allow github.com/bannzai/*\n")
        #expect(try UserDefinitionFile.readText(homeDirectory: homeDirectory) == "OPENAI_API_KEY\n@allow github.com/bannzai/*\n")
    }

    /// The `.secchain` of the home directory, and of a dotfiles repository that `~/.secchain` links
    /// into, is the user's file, which a command must not read or write as a repository's.
    @Test
    func theDefinitionFileOfTheHomeDirectoryOrOfTheLinkedDotfilesIsTheUsersFile() throws {
        let homeDirectory = try makeTemporaryDirectory()
        let dotfiles = try makeTemporaryDirectory()
        let repository = try makeTemporaryDirectory()
        try "OPENAI_API_KEY\n".write(to: dotfiles.appendingPathComponent(".secchain"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: UserDefinitionFile.url(homeDirectory: homeDirectory),
            withDestinationURL: dotfiles.appendingPathComponent(".secchain")
        )
        #expect(UserDefinitionFile.isUserDefinitionFile(url: SecretDefinitionFile.url(workingTreeRoot: homeDirectory), homeDirectory: homeDirectory))
        #expect(UserDefinitionFile.isUserDefinitionFile(url: SecretDefinitionFile.url(workingTreeRoot: dotfiles), homeDirectory: homeDirectory))
        #expect(!UserDefinitionFile.isUserDefinitionFile(url: SecretDefinitionFile.url(workingTreeRoot: repository), homeDirectory: homeDirectory))
    }
    #endif

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secchain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
