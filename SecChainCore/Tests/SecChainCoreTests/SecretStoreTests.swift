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
        let stored = try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        #expect(stored.protectionLevel == .standard)
        #expect(stored.isSynchronized)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).map(\.name.value) == ["API_KEY"])
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func theSameNameInTwoRepositoriesIsTwoSecrets() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .repository(repositoryB), protectionLevel: nil, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")[try name("API_KEY")] == dummyValue)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryB)], authenticationReason: "run")[try name("API_KEY")] == otherDummyValue)
        #expect(try store.repositoryIdentities() == [repositoryA, repositoryB])
    }

    @Test
    func settingAnExistingNameUpdatesItAndKeepsItsSettings() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: false)
        let updated = try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        #expect(!updated.isSynchronized)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).count == 1)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")[try name("API_KEY")] == otherDummyValue)
    }

    @Test
    func deleteRemovesTheSecretAndIsIdempotent() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        try await store.delete(name: try name("API_KEY"), scope: .repository(repositoryA))
        try await store.delete(name: try name("API_KEY"), scope: .repository(repositoryA))
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).isEmpty)
        #expect(try store.repositoryIdentities().isEmpty)
    }

    @Test
    func readingAMissingSecretIsSecretNotFound() async throws {
        await #expect(throws: SecretStoreError.secretNotFound(name: "MISSING", repository: repositoryA.value)) {
            try await store.values(names: [try name("MISSING")], scopes: [.repository(repositoryA)], authenticationReason: "run")
        }
        await #expect(throws: SecretStoreError.secretNotFound(name: "MISSING", repository: repositoryA.value)) {
            try await store.revealedValue(name: try name("MISSING"), scope: .repository(repositoryA))
        }
    }

    @Test
    func anEmptyValueIsRejected() async throws {
        await #expect(throws: SecretStoreError.emptyValue) {
            try await store.set(name: try name("API_KEY"), value: SecretValue(exposingString: ""), scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        }
    }

    // MARK: - Authentication policy

    @Test
    func standardSecretsAreReadWithoutAuthentication() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: nil)
        _ = try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func oneAuthenticationCoversEveryProtectedSecretOfARun() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .deviceBound, isSynchronized: nil)
        try await store.set(name: try name("C"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run").count == 3)
        #expect(authenticator.reasons == ["run"])
    }

    @Test
    func selectingOnlyStandardSecretsDoesNotAuthenticate() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: nil)
        try await store.set(name: try name("C"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: nil)
        #expect(try await store.values(names: [try name("C")], scopes: [.repository(repositoryA)], authenticationReason: "run").count == 1)
        #expect(authenticator.reasons.isEmpty)
    }

    @Test
    func listingNeverAuthenticatesAndCarriesNoValue() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .deviceBound, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: nil)
        let listed = try store.storedSecrets(scope: .repository(repositoryA))
        #expect(listed.map(\.name.value) == ["A", "B"])
        #expect(try store.repositoryIdentities() == [repositoryA])
        #expect(authenticator.reasons.isEmpty)
        // A listed secret is an attribute record: no member of it can hand out the value.
        #expect(!listed.contains { Mirror(reflecting: $0).children.contains { $0.value is SecretValue } })
    }

    @Test
    func aFailedAuthenticationReturnsNoValue() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: nil)
        let rejectingStore = SecretStore(keychain: keychain, ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationCancelled))
        await #expect(throws: SecretStoreError.authenticationCancelled) {
            try await rejectingStore.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")
        }
    }

    @Test
    func revealAlwaysAuthenticates() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: nil)
        #expect(try await store.revealedValue(name: try name("A"), scope: .repository(repositoryA)) == dummyValue)
        #expect(authenticator.reasons == ["reveal A"])
    }

    @Test
    func updatingOrDeletingAProtectedSecretAuthenticatesFirst() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: nil)
        #expect(authenticator.reasons.isEmpty)
        try await store.set(name: try name("A"), value: otherDummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        try await store.delete(name: try name("A"), scope: .repository(repositoryA))
        #expect(authenticator.reasons == ["update A", "delete A"])
    }

    @Test
    func loweringTheLevelRequiresAuthenticationAndIsRefusedWithoutIt() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: nil)
        let rejectingStore = SecretStore(keychain: keychain, ownerAuthenticator: CountingOwnerAuthenticator(failure: .authenticationFailed))
        await #expect(throws: SecretStoreError.authenticationFailed) {
            try await rejectingStore.changeProtection(name: try name("A"), scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: true)
        }
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).first?.protectionLevel == .confirm)
        try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: true)
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).first?.protectionLevel == .standard)
    }

    @Test
    func raisingTheLevelOfAStandardSecretNeedsNoAuthentication() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: nil)
        try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: true)
        #expect(authenticator.reasons.isEmpty)
    }

    // MARK: - Protection level and synchronization changes

    @Test
    func deviceBoundIsNeverSynchronized() async throws {
        let stored = try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .deviceBound, isSynchronized: nil)
        #expect(!stored.isSynchronized)
        await #expect(throws: SecretStoreError.deviceBoundCannotSynchronize) {
            try await store.set(name: try name("B"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .deviceBound, isSynchronized: true)
        }
        await #expect(throws: SecretStoreError.deviceBoundCannotSynchronize) {
            try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), protectionLevel: .deviceBound, isSynchronized: true)
        }
    }

    @Test
    func changingSynchronizationKeepsTheValueAndLeavesOneVariant() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: true)
        try await store.changeProtection(name: try name("A"), scope: .repository(repositoryA), protectionLevel: .standard, isSynchronized: false)
        #expect(try keychain.storedSecrets(scope: .repository(repositoryA)).map(\.isSynchronized) == [false])
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")[try name("A")] == dummyValue)
    }

    @Test
    func theLocalVariantWinsOverASynchronizedOneAndSetRemovesTheStaleVariant() async throws {
        let local = StoredSecret(scope: .repository(repositoryA), name: try name("A"), protectionLevel: .standard, isSynchronized: false, modificationDate: nil)
        let synchronized = StoredSecret(scope: .repository(repositoryA), name: try name("A"), protectionLevel: .standard, isSynchronized: true, modificationDate: nil)
        try keychain.write(storedSecret: local, value: dummyValue, replacing: nil, ownerAuthentication: nil)
        try keychain.write(storedSecret: synchronized, value: otherDummyValue, replacing: nil, ownerAuthentication: nil)

        #expect(try store.storedSecrets(scope: .repository(repositoryA)).map(\.isSynchronized) == [false])
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")[try name("A")] == dummyValue)

        try await store.set(name: try name("A"), value: otherDummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: true)
        #expect(try keychain.storedSecrets(scope: .repository(repositoryA)).map(\.isSynchronized) == [true])
    }

    // MARK: - Scopes

    @Test
    func theSameNameInARepositoryAndInASharedScopeIsTwoSecrets() async throws {
        try await store.set(name: try name("API_KEY"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("API_KEY"), value: otherDummyValue, scope: .shared(.user), protectionLevel: nil, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")[try name("API_KEY")] == dummyValue)
        #expect(try await store.values(names: nil, scopes: [.shared(.user)], authenticationReason: "run")[try name("API_KEY")] == otherDummyValue)
        try await store.delete(name: try name("API_KEY"), scope: .shared(.user))
        #expect(try store.storedSecrets(scope: .repository(repositoryA)).map(\.name.value) == ["API_KEY"])
    }

    /// A name in several passed scopes comes from the first of them, which is how the repository's
    /// own secret overrides a shared one (`UserDefinition.passedScopes` puts it first).
    @Test
    func aNameInSeveralScopesComesFromTheFirst() async throws {
        let youtube = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "youtube"))))
        try await store.set(name: try name("SHARED"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("SHARED"), value: otherDummyValue, scope: youtube, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("SHARED"), value: otherDummyValue, scope: .shared(.user), protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("FROM_YOUTUBE"), value: dummyValue, scope: youtube, protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("FROM_YOUTUBE"), value: otherDummyValue, scope: .shared(.user), protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("FROM_USER"), value: dummyValue, scope: .shared(.user), protectionLevel: nil, isSynchronized: nil)
        let scopes: [SecretScope] = [.repository(repositoryA), youtube, .shared(.user)]
        #expect(
            try store.storedSecrets(scopes: scopes).map { "\($0.name.value)=\($0.scope.name)" }
                == ["FROM_USER=user", "FROM_YOUTUBE=youtube", "SHARED=repository"]
        )
        #expect(
            try await store.values(names: nil, scopes: scopes, authenticationReason: "run")
                == [try name("SHARED"): dummyValue, try name("FROM_YOUTUBE"): dummyValue, try name("FROM_USER"): dummyValue]
        )
    }

    @Test
    func oneAuthenticationCoversTheProtectedSecretsOfEveryScope() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: .confirm, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .shared(.user), protectionLevel: .confirm, isSynchronized: nil)
        #expect(try await store.values(names: nil, scopes: [.repository(repositoryA), .shared(.user)], authenticationReason: "run").count == 2)
        #expect(authenticator.reasons == ["run"])
    }

    @Test
    func scopesListEveryScopeAndRepositoriesOnlyTheRepositories() async throws {
        try await store.set(name: try name("A"), value: dummyValue, scope: .repository(repositoryA), protectionLevel: nil, isSynchronized: nil)
        try await store.set(name: try name("B"), value: dummyValue, scope: .shared(.user), protectionLevel: nil, isSynchronized: nil)
        #expect(try store.scopes() == [.repository(repositoryA), .shared(.user)])
        #expect(try store.repositoryIdentities() == [repositoryA])
    }

    // MARK: - Failures of the Keychain

    @Test
    func aMissingEntitlementIsReportedAsSuchNotAsAnEmptyList() async throws {
        keychain.setFailure(failure: .missingEntitlement)
        #expect(throws: SecretStoreError.missingEntitlement) {
            try store.storedSecrets(scope: .repository(repositoryA))
        }
        await #expect(throws: SecretStoreError.missingEntitlement) {
            try await store.values(names: nil, scopes: [.repository(repositoryA)], authenticationReason: "run")
        }
    }
}
