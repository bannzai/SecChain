import Foundation
import Testing

@testable import SecChainCore

/// Authenticator double that counts prompts and can be told to fail.
final class CountingOwnerAuthenticator: OwnerAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedReasons: [String] = []
    private let failure: SecretStoreError?

    init(failure: SecretStoreError?) {
        self.failure = failure
    }

    var reasons: [String] {
        lock.withLock { recordedReasons }
    }

    func authenticate(reason: String) async throws -> OwnerAuthentication {
        lock.withLock {
            recordedReasons.append(reason)
        }
        if let failure {
            throw failure
        }
        return OwnerAuthentication(context: nil)
    }
}

@Suite
struct SecretStoreTests {
    let keychain = InMemorySecretKeychain()
    let authenticator = CountingOwnerAuthenticator(failure: nil)
    let repositoryA = RepositoryIdentity(value: "github.com/example/a")
    let repositoryB = RepositoryIdentity(value: "github.com/example/b")
    let dummyValue = SecretValue(exposingString: "dummy-value-for-test")
    let otherDummyValue = SecretValue(exposingString: "other-dummy-value-for-test")

    var store: SecretStore {
        SecretStore(keychain: keychain, ownerAuthenticator: authenticator)
    }

    func name(_ rawName: String) throws -> SecretName {
        // The label is omitted because every call site passes a literal name.
        try #require(SecretName(rawName: rawName))
    }

    // MARK: - Add, update, delete, isolation

    @Test
    func aNewSecretIsStandardAndSynchronizedByDefault() async throws {
        let stored = try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        #expect(stored.protectionLevel == .standard)
        #expect(stored.isSynchronized)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).map(\.name.value) == ["API_KEY"])
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func theSameNameInTwoRepositoriesIsTwoSecrets() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .repository(repositoryB), environment: nil, protectionLevel: nil, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")[try name("API_KEY")] == dummyValue)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryB)], environment: nil, authenticationReason: "run")[try name("API_KEY")] == otherDummyValue)
        #expect(try store.repositoryIdentities() == [repositoryA, repositoryB])
    }

    @Test
    func settingAnExistingNameUpdatesItAndKeepsItsSettings() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: false)
        let updated = try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        #expect(!updated.isSynchronized)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).count == 1)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")[try name("API_KEY")] == otherDummyValue)
    }

    @Test
    func deleteRemovesTheSecretAndIsIdempotent() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.delete(name: try name("API_KEY"), scope: .repository(repositoryA), environment: nil)
        try await store.delete(name: try name("API_KEY"), scope: .repository(repositoryA), environment: nil)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).isEmpty)
        #expect(try store.repositoryIdentities().isEmpty)
    }

    @Test
    func readingAMissingSecretIsSecretNotFound() async throws {
        await #expect(throws: SecretStoreError.secretNotFound(name: "MISSING", repository: repositoryA.value)) {
            try await store.values(names: [try name("MISSING")], scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")
        }
        await #expect(throws: SecretStoreError.secretNotFound(name: "MISSING", repository: repositoryA.value)) {
            try await store.revealedValue(name: try name("MISSING"), scope: .repository(repositoryA), environment: nil)
        }
    }

    @Test
    func anEmptyValueIsRejected() async throws {
        await #expect(throws: SecretStoreError.emptyValue) {
            try await store.set(name: try name("API_KEY"), value: SecretValue(exposingString: ""), scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        }
    }

    // MARK: - Authentication policy

    @Test
    func standardSecretsAreReadWithoutAuthentication() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: nil)
        _ = try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func oneAuthenticationCoversEveryProtectedSecretOfARun() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
        try await store.set(name: try name("C"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run").count == 3)
        #expect(authenticator.reasons == ["run"])
    }

    @Test
    func selectingOnlyStandardSecretsDoesNotAuthenticate() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        try await store.set(name: try name("C"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: nil)
        #expect(try await store.values(names: [try name("C")], scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run").count == 1)
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func listingNeverAuthenticatesAndCarriesNoValue() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        let listed = try store.storedSecrets(scope: .repository(repositoryA))
        #expect(listed.map(\.name.value) == ["A", "B"])
        #expect(try store.repositoryIdentities() == [repositoryA])
        #expect(authenticator.reasons.isEmpty)
        // A listed secret is an attribute record: no member of it can hand out the value.
        #expect(!listed.contains { Mirror(reflecting: $0).children.contains { $0.value is SecretValue } })
    }

    @Test
    func aFailedAuthenticationReturnsNoValue() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        let rejectingStore = SecretStore(keychain: keychain, ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationCancelled))
        await #expect(throws: SecretStoreError.authenticationCancelled) {
            try await rejectingStore.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")
        }
    }

    @Test
    func revealAlwaysAuthenticates() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: nil)
        #expect(try await store.revealedValue(name: try name("A"), scope: .repository(repositoryA), environment: nil) == dummyValue)
        #expect(authenticator.reasons == ["reveal A"])
    }

    @Test
    func updatingOrDeletingAProtectedSecretAuthenticatesFirst() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        #expect(authenticator.reasons.isEmpty)
        try await store.set(name: try name("A"), value: otherDummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.delete(name: try name("A"), scope: .repository(repositoryA), environment: nil)
        #expect(authenticator.reasons == ["update A", "delete A"])
    }

    @Test
    func loweringTheLevelRequiresAuthenticationAndIsRefusedWithoutIt() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        let rejectingStore = SecretStore(keychain: keychain, ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationFailed))
        await #expect(throws: SecretStoreError.authenticationFailed) {
            try await rejectingStore.changeProtection(name: try name("A"), scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: true)
        }
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).first?.protectionLevel == .confirm)
        try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: true)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).first?.protectionLevel == .standard)
    }

    @Test
    func raisingTheLevelOfAStandardSecretNeedsNoAuthentication() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: nil)
        try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: true)
        #expect(authenticator.reasons.isEmpty)
    }

    // MARK: - Protection level and synchronization changes

    @Test
    func deviceBoundIsNeverSynchronized() async throws {
        let stored = try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
        #expect(!stored.isSynchronized)
        await #expect(throws: SecretStoreError.deviceBoundCannotSynchronize) {
            try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .deviceBound, isSynchronized: true)
        }
        await #expect(throws: SecretStoreError.deviceBoundCannotSynchronize) {
            try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), environment: nil, protectionLevel: .deviceBound, isSynchronized: true)
        }
    }

    @Test
    func changingSynchronizationKeepsTheValueAndLeavesOneVariant() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: true)
        try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: false)
        #expect(try keychain.storedSecrets(scope: .repository(repositoryA)).map(\.isSynchronized) == [false])
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")[try name("A")] == dummyValue)
    }

    @Test
    func theLocalVariantWinsOverASynchronizedOneAndSetRemovesTheStaleVariant() async throws {
        let local = StoredSecret(scope: .repository(repositoryA), name: try name("A"), environment: nil, protectionLevel: .standard, isSynchronized: false, modificationDate: nil)
        let synchronized = StoredSecret(scope: .repository(repositoryA), name: try name("A"), environment: nil, protectionLevel: .standard, isSynchronized: true, modificationDate: nil)
        try keychain.write(storedSecret: local, value: dummyValue, replacing: nil, ownerAuthentication: nil)
        try keychain.write(storedSecret: synchronized, value: otherDummyValue, replacing: nil, ownerAuthentication: nil)

        #expect(try store.storedSecrets(scope: .repository(repositoryA)).map(\.isSynchronized) == [false])
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")[try name("A")] == dummyValue)

        try await store.set(name: try name("A"), value: otherDummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: true)
        #expect(try keychain.storedSecrets(scope: .repository(repositoryA)).map(\.isSynchronized) == [true])
    }

    // MARK: - Scopes

    @Test
    func theSameNameInARepositoryAndInASharedScopeIsTwoSecrets() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .shared(.user), environment: nil, protectionLevel: nil, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")[try name("API_KEY")] == dummyValue)
        #expect(try await store.values(names: nil, scopes: [.shared(.user)], environment: nil, authenticationReason: "run")[try name("API_KEY")] == otherDummyValue)
        try await store.delete(name: try name("API_KEY"), scope: .shared(.user), environment: nil)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).map(\.name.value) == ["API_KEY"])
    }

    /// A name in several passed scopes comes from the first of them, which is how the repository's
    /// own secret overrides a shared one (`UserDefinition.passedScopes` puts it first).
    @Test
    func aNameInSeveralScopesComesFromTheFirst() async throws {
        let youtube = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "youtube"))))
        try await store.set(name: try name("SHARED"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("SHARED"), value: otherDummyValue, scope: youtube, environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("SHARED"), value: otherDummyValue, scope: .shared(.user), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("FROM_YOUTUBE"), value: dummyValue, scope: youtube, environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("FROM_YOUTUBE"), value: otherDummyValue, scope: .shared(.user), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("FROM_USER"), value: dummyValue, scope: .shared(.user), environment: nil, protectionLevel: nil, isSynchronized: nil)
        let scopes: [SecretScope] = [.repository(repositoryA), youtube, .shared(.user)]
        #expect(
            try store.storedSecrets(scopes: scopes, environment: nil).map { "\($0.name.value)=\($0.scope.name)" }
                == ["FROM_USER=user", "FROM_YOUTUBE=youtube", "SHARED=repository"]
        )
        #expect(
            try await store.values(names: nil, scopes: scopes, environment: nil, authenticationReason: "run")
                == [try name("SHARED"): dummyValue, try name("FROM_YOUTUBE"): dummyValue, try name("FROM_USER"): dummyValue]
        )
    }

    @Test
    func oneAuthenticationCoversTheProtectedSecretsOfEveryScope() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .shared(.user), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA), .shared(.user)], environment: nil, authenticationReason: "run").count == 2)
        #expect(authenticator.reasons == ["run"])
    }

    /// A repository named like a scope's service would keep its device-bound values in the scope's
    /// item, so a standard secret stored there and deleted again would take the scope's value with
    /// it, without the authentication a device-bound secret asks for. Nothing is stored for it.
    @Test
    func nothingIsStoredForARepositoryNamedLikeAScopesService() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .shared(.user), environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
        for identifier in ["com.bannzai.SecChain.scope.user", "com.bannzai.secchain.scope.youtube"] {
            await #expect(throws: SecretStoreError.reservedRepositoryIdentifier(repository: identifier)) {
                try await store.set(name: try name("A"), value: otherDummyValue, scope: .repository(RepositoryIdentity(value: identifier)), environment: nil, protectionLevel: nil, isSynchronized: nil)
            }
        }
        #expect(try store.repositoryIdentities().isEmpty)
        #expect(try await store.values(names: nil, scopes: [.shared(.user)], environment: nil, authenticationReason: "run")[try name("A")] == dummyValue)
    }

    @Test
    func scopesListEveryScopeAndRepositoriesOnlyTheRepositories() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .shared(.user), environment: nil, protectionLevel: nil, isSynchronized: nil)
        #expect(try store.scopes() == [.repository(repositoryA), .shared(.user)])
        #expect(try store.repositoryIdentities() == [repositoryA])
    }

    // MARK: - Environments

    func environment(_ rawName: String) throws -> SecretEnvironment {
        // The label is omitted because every call site passes a literal name.
        try #require(SecretEnvironment(rawName: rawName))
    }

    @Test
    func theSameNameInTwoEnvironmentsIsTwoSecrets() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: try environment("local"), protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .repository(repositoryA), environment: try environment("prod"), protectionLevel: nil, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: try environment("local"), authenticationReason: "run")[try name("API_KEY")] == dummyValue)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: try environment("prod"), authenticationReason: "run")[try name("API_KEY")] == otherDummyValue)
        #expect(try store.environments(scope: .repository(repositoryA)) == [try environment("local"), try environment("prod")])
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).map { $0.environment?.value } == ["local", "prod"])
        #expect(try store.scopes() == [.repository(repositoryA)])
    }

    @Test
    func aNameAnEnvironmentDoesNotHoldIsReportedWithTheEnvironment() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: try environment("local"), protectionLevel: nil, isSynchronized: nil)
        await #expect(throws: SecretStoreError.secretNotFoundInEnvironment(name: "API_KEY", repository: repositoryA.value, environment: "prod")) {
            try await store.values(names: [try name("API_KEY")], scopes: [.repository(repositoryA)], environment: try environment("prod"), authenticationReason: "run")
        }
        #expect(
            SecretStoreError.secretNotFoundInEnvironment(name: "API_KEY", repository: repositoryA.value, environment: "prod").description
                == "No value of the environment prod is stored for API_KEY in github.com/example/a. Store it with 'secchain set API_KEY --env prod'."
        )
    }

    /// Once a scope has an environment, a secret stored without one would never be passed by `run`,
    /// so storing one is refused; deleting one that is left over is how it is cleaned up.
    @Test
    func aScopeWithEnvironmentsNeedsOneNamedToStoreAndToDelete() async throws {
        try await store.set(name: try name("LEFT_OVER"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), environment: try environment("prod"), protectionLevel: nil, isSynchronized: nil)
        let environmentRequired = SecretStoreError.environmentRequired(repository: repositoryA.value, environments: ["prod"])
        await #expect(throws: environmentRequired) {
            try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        }
        #expect(environmentRequired.description == "github.com/example/a has the environments prod, so name one with '--env <environment>'.")
        try await store.delete(name: try name("LEFT_OVER"), scope: .repository(repositoryA), environment: nil)
        await #expect(throws: environmentRequired) {
            try await store.delete(name: try name("LEFT_OVER"), scope: .repository(repositoryA), environment: nil)
        }
        try await store.delete(name: try name("API_KEY"), scope: .repository(repositoryA), environment: try environment("prod"))
        try await store.delete(name: try name("API_KEY"), scope: .repository(repositoryA), environment: try environment("prod"))
        // Without any environment left, the scope is one without environments again.
        try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        #expect(try store.environments(scope: .repository(repositoryA)).isEmpty)
    }

    /// `#` separates the environment in a Keychain service, so the secrets of `…/a#prod` would be
    /// read back as the prod secrets of `…/a`.
    @Test
    func nothingIsStoredForARepositoryWhoseIdentifierContainsTheSeparatorOfAnEnvironment() async throws {
        await #expect(throws: SecretStoreError.repositoryIdentifierContainsEnvironmentSeparator(repository: "github.com/example/a#prod")) {
            try await store.set(name: try name("A"), value: dummyValue, scope: .repository(RepositoryIdentity(value: "github.com/example/a#prod")), environment: nil, protectionLevel: nil, isSynchronized: nil)
        }
        #expect(try store.scopes().isEmpty)
    }

    @Test
    func migratingMovesEverySecretWithoutAnEnvironmentUnderOneAuthentication() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .confirm, isSynchronized: nil)
        try await store.set(name: try name("B"), value: otherDummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: false)
        try await store.set(name: try name("C"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
        let moved = try await store.moveToEnvironment(names: nil, scope: .repository(repositoryA), environment: try environment("local"))
        #expect(moved.map(\.name.value) == ["A", "B", "C"])
        #expect(authenticator.reasons == ["move A, B, C to the environment local"])
        // The level and the synchronization move along, and nothing is left behind.
        #expect(
            try keychain.storedSecrets(scope: .repository(repositoryA)).sorted { $0.name < $1.name }.map { "\($0.name.value) \($0.environment?.value ?? "-") \($0.protectionLevel.rawValue) \($0.isSynchronized)" }
                == ["A local confirm true", "B local standard false", "C local device-bound false"]
        )
        #expect(
            try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: try environment("local"), authenticationReason: "run")
                == [try name("A"): dummyValue, try name("B"): otherDummyValue, try name("C"): dummyValue]
        )
        // Idempotent: nothing is left to move, and nobody is asked again.
        let reasonsBeforeRepeating = authenticator.reasons
        #expect(try await store.moveToEnvironment(names: nil, scope: .repository(repositoryA), environment: try environment("local")).isEmpty)
        #expect(authenticator.reasons == reasonsBeforeRepeating)
    }

    @Test
    func migratingOneSecretLeavesTheOthersAndCanBeRepeated() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .shared(.user), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("B"), value: otherDummyValue, scope: .shared(.user), environment: nil, protectionLevel: nil, isSynchronized: nil)
        #expect(try await store.moveToEnvironment(names: [try name("A")], scope: .shared(.user), environment: try environment("local")).map(\.name.value) == ["A"])
        #expect(try store.storedSecrets(scope: .shared(.user)).map { "\($0.name.value) \($0.environment?.value ?? "-")" } == ["B -", "A local"])
        #expect(try await store.moveToEnvironment(names: [try name("A")], scope: .shared(.user), environment: try environment("local")).isEmpty)
        await #expect(throws: SecretStoreError.secretNotFound(name: "MISSING", repository: "scope user")) {
            try await store.moveToEnvironment(names: [try name("MISSING")], scope: .shared(.user), environment: try environment("local"))
        }
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func migratingNeverOverwritesTheValueOfTheEnvironment() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("B"), value: otherDummyValue, scope: .repository(repositoryA), environment: try environment("prod"), protectionLevel: nil, isSynchronized: nil)
        await #expect(throws: SecretStoreError.duplicateSecret(name: "B", repository: "github.com/example/a, environment prod")) {
            try await store.moveToEnvironment(names: nil, scope: .repository(repositoryA), environment: try environment("prod"))
        }
        // Refused before anything moved, A included.
        #expect(try store.storedSecrets(scope: .repository(repositoryA), environment: nil).map(\.name.value) == ["A", "B"])
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: try environment("prod"), authenticationReason: "run") == [try name("B"): otherDummyValue])
    }

    /// Every value is read before anything is written, so a device-bound value that cannot be read
    /// leaves the other secrets where they were too.
    @Test
    func aRefusedAuthenticationMovesNothing() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .standard, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), environment: nil, protectionLevel: .deviceBound, isSynchronized: nil)
        let rejectingStore = SecretStore(keychain: keychain, ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationNotPossible))
        await #expect(throws: SecretStoreError.authenticationNotPossible) {
            try await rejectingStore.moveToEnvironment(names: nil, scope: .repository(repositoryA), environment: try environment("local"))
        }
        #expect(try keychain.storedSecrets(scope: .repository(repositoryA)).allSatisfy { $0.environment == nil })
        #expect(try store.environments(scope: .repository(repositoryA)).isEmpty)
    }

    // MARK: - Failures of the Keychain

    @Test
    func aMissingEntitlementIsReportedAsSuchNotAsAnEmptyList() async throws {
        keychain.setFailure(failure: .missingEntitlement)
        #expect(throws: SecretStoreError.missingEntitlement) {
            try store.storedSecrets(scope: .repository(repositoryA))
        }
        await #expect(throws: SecretStoreError.missingEntitlement) {
            try await store.values(names: nil, scopes: [.repository(repositoryA)], environment: nil, authenticationReason: "run")
        }
    }
}
