import Testing

@testable import SecChainCore

@Suite
struct RepositoryIdentityTests {
    @Test(arguments: [
        "git@github.com:bannzai/SecChain.git",
        "https://github.com/bannzai/SecChain",
        "https://github.com/bannzai/SecChain.git",
        "https://github.com/bannzai/SecChain/",
        "https://GitHub.com/Bannzai/secchain.git",
        "https://user:dummy-token@github.com/bannzai/SecChain.git",
        "ssh://git@github.com/bannzai/SecChain.git",
        "ssh://git@github.com:22/bannzai/SecChain.git",
        "git://github.com/bannzai/SecChain.git",
        "  git@github.com:bannzai/SecChain.git\n",
    ])
    func spellingsOfOneRemoteNormalizeToOneIdentifier(remoteURL: String) {
        #expect(RepositoryRemoteURL.normalizedIdentifier(remoteURL: remoteURL) == "github.com/bannzai/secchain")
    }

    @Test
    func nestedGroupsAreKept() {
        #expect(
            RepositoryRemoteURL.normalizedIdentifier(remoteURL: "git@gitlab.com:group/subgroup/project.git")
                == "gitlab.com/group/subgroup/project"
        )
    }

    @Test(arguments: [
        "/Users/someone/src/example.git",
        "../example",
        "file:///Users/someone/src/example.git",
        "C:/src/example",
        "",
    ])
    func localPathsAreNotStableIdentifiers(remoteURL: String) {
        #expect(RepositoryRemoteURL.normalizedIdentifier(remoteURL: remoteURL) == nil)
    }

    @Test
    func sanitizedRemoteURLDropsCredentials() {
        #expect(
            RepositoryRemoteURL.sanitized(remoteURL: "https://user:dummy-token@github.com/bannzai/SecChain.git")
                == "github.com/bannzai/SecChain.git"
        )
    }

    @Test
    func keychainServiceRoundTrips() {
        let repositoryIdentity = RepositoryIdentity(value: "github.com/bannzai/secchain")
        #expect(repositoryIdentity.keychainService == "com.bannzai.SecChain.repository.github.com/bannzai/secchain")
        #expect(RepositoryIdentity(keychainService: repositoryIdentity.keychainService) == repositoryIdentity)
        #expect(RepositoryIdentity(keychainService: "com.bannzai.SecChain.doctor") == nil)
    }
}
