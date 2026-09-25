import Foundation
import Security
import Testing

@testable import SecChainCore

/// The item layout of the real Keychain, checked on the queries it builds: the queries themselves
/// need no signed build, only running them does (`make test-integration`).
@Suite
struct SystemSecretKeychainTests {
    /// A device-bound secret of the same name in `scope`, whose queries the tests compare.
    func storedSecret(scope: SecretScope) throws -> StoredSecret {
        StoredSecret(scope: scope, name: try #require(SecretName(rawName: "YOUTUBE_API_KEY")), environment: nil, protectionLevel: .deviceBound, isSynchronized: false, modificationDate: nil)
    }

    @Test
    func aScopeAndARepositoryOfTheSameNameLookUpDifferentProtectedValues() throws {
        let repositoryQuery = SystemSecretKeychain.protectedValueQuery(
            storedSecret: try storedSecret(scope: .repository(RepositoryIdentity(value: "youtube")))
        )
        let scopeQuery = SystemSecretKeychain.protectedValueQuery(
            storedSecret: try storedSecret(scope: .shared(.custom(try #require(CustomScopeName(rawName: "youtube")))))
        )
        #expect(repositoryQuery[kSecAttrServer as String] as? String == "youtube")
        #expect(scopeQuery[kSecAttrServer as String] as? String == "com.bannzai.SecChain.scope.youtube")
        #expect(scopeQuery[kSecAttrAccount as String] as? String == repositoryQuery[kSecAttrAccount as String] as? String)
    }

    @Test
    func theListingItemOfAScopeIsUnderTheScopesService() throws {
        let query = SystemSecretKeychain.itemQuery(storedSecret: try storedSecret(scope: .shared(.user)))
        #expect(query[kSecAttrService as String] as? String == "com.bannzai.SecChain.scope.user")
        #expect(query[kSecAttrAccount as String] as? String == "YOUTUBE_API_KEY")
    }

    @Test
    func listedAttributesOfAScopeItemBecomeASecretOfThatScope() throws {
        let storedSecret = try #require(
            SystemSecretKeychain.storedSecret(attributes: [
                kSecAttrService as String: "com.bannzai.SecChain.scope.youtube",
                kSecAttrAccount as String: "YOUTUBE_API_KEY",
                kSecAttrDescription as String: "confirm",
                kSecAttrSynchronizable as String: NSNumber(value: true),
            ])
        )
        #expect(storedSecret.scope == .shared(.custom(try #require(CustomScopeName(rawName: "youtube")))))
        #expect(storedSecret.protectionLevel == .confirm)
        #expect(storedSecret.isSynchronized)
        #expect(storedSecret.environment == nil)
        #expect(
            SystemSecretKeychain.storedSecret(attributes: [
                kSecAttrService as String: "com.bannzai.SecChain.remoteApproval",
                kSecAttrAccount as String: "pairing",
            ]) == nil
        )
    }

    /// The item of a secret of an environment is under the scope's service with `#<environment>`,
    /// its device-bound value under the scope's server with the same suffix, and listing reads both
    /// the scope and the environment back.
    @Test
    func aSecretOfAnEnvironmentIsUnderTheScopesServiceAndServerWithTheEnvironment() throws {
        let storedSecret = StoredSecret(
            scope: .repository(RepositoryIdentity(value: "github.com/example/a")),
            name: try #require(SecretName(rawName: "API_KEY")),
            environment: SecretEnvironment(rawName: "prod"),
            protectionLevel: .deviceBound,
            isSynchronized: false,
            modificationDate: nil
        )
        #expect(SystemSecretKeychain.itemQuery(storedSecret: storedSecret)[kSecAttrService as String] as? String == "com.bannzai.SecChain.repository.github.com/example/a#prod")
        #expect(SystemSecretKeychain.protectedValueQuery(storedSecret: storedSecret)[kSecAttrServer as String] as? String == "github.com/example/a#prod")
        #expect(
            SystemSecretKeychain.storedSecret(attributes: [
                kSecAttrService as String: "com.bannzai.SecChain.repository.github.com/example/a#prod",
                kSecAttrAccount as String: "API_KEY",
                kSecAttrDescription as String: "device-bound",
                kSecAttrSynchronizable as String: NSNumber(value: false),
            ]) == storedSecret
        )
        // An environment this version does not accept is ignored rather than read as none.
        #expect(
            SystemSecretKeychain.storedSecret(attributes: [
                kSecAttrService as String: "com.bannzai.SecChain.repository.github.com/example/a#Prod",
                kSecAttrAccount as String: "API_KEY",
            ]) == nil
        )
    }
}
