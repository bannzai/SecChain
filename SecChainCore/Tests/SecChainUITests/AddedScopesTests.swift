import Foundation
import SecChainCore
import Testing

@testable import SecChainUI

/// The list of scopes added by hand, as the apps keep it in `UserDefaults`.
@MainActor
@Suite
struct AddedScopesTests {
    /// A defaults domain of its own, so that the test never reads or writes the app's list.
    func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "SecChainUITests.AddedScopes.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @Test
    func everyKindOfScopeIsReadBackAsWritten() throws {
        let userDefaults = try makeUserDefaults()
        let scopes: [SecretScope] = [
            .repository(RepositoryIdentity(value: "github.com/example/a")),
            // Typed by hand: read as a service, the part after `#` would be an environment.
            .repository(RepositoryIdentity(value: "notes#draft")),
            .shared(.user),
            .shared(.custom(try #require(CustomScopeName(rawName: "youtube")))),
        ]
        writeAddedScopes(scopes: scopes, userDefaults: userDefaults)
        writeAddedScopes(scopes: scopes, userDefaults: userDefaults)
        #expect(addedScopes(userDefaults: userDefaults) == scopes)
    }

    @Test
    func anEntryThatNamesNoScopeIsLeftOut() throws {
        let userDefaults = try makeUserDefaults()
        #expect(addedScopes(userDefaults: userDefaults).isEmpty)
        userDefaults.set(["com.example.other", SecretScope.shared(.user).keychainService], forKey: addedScopesDefaultsKey)
        #expect(addedScopes(userDefaults: userDefaults) == [.shared(.user)])
    }
}
