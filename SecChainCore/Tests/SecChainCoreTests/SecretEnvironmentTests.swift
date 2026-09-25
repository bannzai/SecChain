import Testing

@testable import SecChainCore

/// The rules of an environment name and how it is read back from a Keychain service.
@Suite
struct SecretEnvironmentTests {
    /// The rules of a custom scope name, without reserved names: `user` and `repository` are
    /// environments like any other.
    @Test(arguments: ["local", "prod", "dev", "a", "0", "staging-2", "trailing-", "user", "repository"])
    func validEnvironmentNames(name: String) {
        #expect(SecretEnvironment(rawName: name)?.value == name)
    }

    @Test(arguments: ["", "Prod", "PROD", "-prod", "pro_d", "pro.d", "pro d", "prod#1", "本番"])
    func invalidEnvironmentNames(name: String) {
        #expect(SecretEnvironment(rawName: name) == nil)
    }

    @Test
    func theEnvironmentOfAServiceIsWhatFollowsTheSeparator() {
        #expect(SecretEnvironment(keychainService: "com.bannzai.SecChain.repository.github.com/a/b#prod")?.value == "prod")
        #expect(SecretEnvironment(keychainService: "com.bannzai.SecChain.scope.user#local")?.value == "local")
        #expect(SecretEnvironment(keychainService: "com.bannzai.SecChain.scope.user") == nil)
        #expect(SecretEnvironment(keychainService: "com.bannzai.SecChain.scope.user#Prod") == nil)
    }
}
