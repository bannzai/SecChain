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
        StoredSecret(scope: scope, name: try #require(SecretName(rawName: "YOUTUBE_API_KEY")), protectionLevel: .deviceBound, isSynchronized: false, modificationDate: nil)
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
        #expect(
            SystemSecretKeychain.storedSecret(attributes: [
                kSecAttrService as String: "com.bannzai.SecChain.remoteApproval",
                kSecAttrAccount as String: "pairing",
            ]) == nil
        )
    }
}
