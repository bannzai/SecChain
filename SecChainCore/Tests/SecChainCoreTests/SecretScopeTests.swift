import Testing

@testable import SecChainCore

@Suite
struct SecretScopeTests {
    @Test(arguments: ["youtube", "a", "0x", "my-scope", "scope-2", "trailing-"])
    func validCustomScopeNames(name: String) {
        #expect(CustomScopeName(rawName: name)?.value == name)
    }

    /// Uppercase would split one scope between spellings, and `user` / `repository` name the
    /// built-in scopes.
    @Test(arguments: ["", "YouTube", "you tube", "-youtube", "you_tube", "you.tube", "ユーチューブ", "user", "repository"])
    func invalidCustomScopeNames(name: String) {
        #expect(CustomScopeName(rawName: name) == nil)
    }

    @Test
    func aNameOnTheCommandLineIsTheUserScopeOrACustomOne() throws {
        #expect(SharedScope(name: "user") == .user)
        #expect(SharedScope(name: "youtube") == .custom(try #require(CustomScopeName(rawName: "youtube"))))
        #expect(SharedScope(name: "repository") == nil)
        #expect(SharedScope(name: "You Tube") == nil)
    }

    @Test
    func keychainServicesRoundTripAndStayApart() throws {
        let repositoryScope = SecretScope.repository(RepositoryIdentity(value: "github.com/bannzai/secchain"))
        let customScope = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "youtube"))))
        #expect(repositoryScope.keychainService == "com.bannzai.SecChain.repository.github.com/bannzai/secchain")
        #expect(SecretScope.shared(.user).keychainService == "com.bannzai.SecChain.scope.user")
        #expect(customScope.keychainService == "com.bannzai.SecChain.scope.youtube")
        for scope in [repositoryScope, .shared(.user), customScope] {
            #expect(SecretScope(keychainService: scope.keychainService) == scope)
        }
        // A repository identifier cannot name a scope's service: its prefix is another one.
        #expect(SecretScope.repository(RepositoryIdentity(value: "user")).keychainService != SecretScope.shared(.user).keychainService)
    }

    @Test(arguments: ["com.bannzai.SecChain.doctor", "com.bannzai.SecChain.remoteApproval", "com.bannzai.SecChain.scope.YouTube", "com.bannzai.SecChain.scope.repository", "com.bannzai.SecChain.scope."])
    func servicesOfNoScopeAreIgnored(keychainService: String) {
        #expect(SecretScope(keychainService: keychainService) == nil)
    }

    /// The device-bound value of a repository is stored under its identifier, so a repository named
    /// like a scope would share that item with the scope if the scope used its name there too.
    @Test
    func aScopeAndARepositoryOfTheSameNameKeepTheirDeviceBoundValuesApart() throws {
        let customScope = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "youtube"))))
        #expect(SecretScope.repository(RepositoryIdentity(value: "youtube")).protectedValueServer == "youtube")
        #expect(customScope.protectedValueServer == "com.bannzai.SecChain.scope.youtube")
        #expect(SecretScope.shared(.user).protectedValueServer == "com.bannzai.SecChain.scope.user")
        #expect(SecretScope.repository(RepositoryIdentity(value: "user")).protectedValueServer != SecretScope.shared(.user).protectedValueServer)
    }

    /// Only an identifier that is a scope's service, in any letter case, is one; a Git remote's
    /// identifier, a scope name, or a longer identifier is not.
    @Test
    func aRepositoryIsNamedLikeASharedScopeOnlyWhenItsIdentifierIsAScopesService() {
        for identifier in ["com.bannzai.SecChain.scope.user", "com.bannzai.SecChain.scope.youtube", "COM.BANNZAI.SECCHAIN.SCOPE.USER"] {
            #expect(SecretScope.repository(RepositoryIdentity(value: identifier)).isRepositoryNamedLikeASharedScope)
        }
        for identifier in ["github.com/bannzai/secchain", "user", "com.bannzai.SecChain.scope.", "com.bannzai.SecChain.scope.user/x", "com.bannzai.SecChain.scope.You_Tube", "com.bannzai.SecChain.repository.user"] {
            #expect(!SecretScope.repository(RepositoryIdentity(value: identifier)).isRepositoryNamedLikeASharedScope)
        }
        #expect(!SecretScope.shared(.user).isRepositoryNamedLikeASharedScope)
    }

    @Test
    func namesAndDescriptionsSayWhichScopeItIs() throws {
        let repositoryScope = SecretScope.repository(RepositoryIdentity(value: "github.com/example/a"))
        #expect(repositoryScope.name == "repository")
        #expect(repositoryScope.description == "github.com/example/a")
        #expect(repositoryScope.repositoryIdentity == RepositoryIdentity(value: "github.com/example/a"))
        #expect(repositoryScope.sharedScope == nil)
        #expect(SecretScope.shared(.user).name == "user")
        #expect(SecretScope.shared(.user).description == "scope user")
        #expect(SecretScope.shared(.user).repositoryIdentity == nil)
    }
}
