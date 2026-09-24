import Foundation
import SecChainCore
import Testing

@testable import SecChainUI

/// Authenticator double: succeeds or throws the configured error, never prompts.
struct FixedOwnerAuthenticator: OwnerAuthenticating {
    let failure: SecretStoreError?

    func authenticate(reason: String) async throws -> OwnerAuthentication {
        if let failure {
            throw failure
        }
        return OwnerAuthentication(context: nil)
    }
}

@MainActor
@Suite
struct AppModelTests {
    let keychain = InMemorySecretKeychain()
    let repositoryIdentity = RepositoryIdentity(value: "github.com/example/a")
    let dummyValue = SecretValue(exposingString: "dummy-value-for-test")

    func makeModel(authenticationFailure: SecretStoreError?) -> AppModel {
        AppModel(store: SecretStore(keychain: keychain, ownerAuthenticator: FixedOwnerAuthenticator(failure: authenticationFailure)))
    }

    @Test
    func aRepositoryAddedInTheAppIsListedBeforeItHasSecrets() {
        let model = makeModel(authenticationFailure: nil)
        model.addRepository(repositoryIdentity: repositoryIdentity)
        #expect(model.repositoryIdentities == [repositoryIdentity])
        #expect(model.selectedRepositoryIdentity == repositoryIdentity)
        #expect(model.storedSecretsByRepository[repositoryIdentity] == [])
    }

    @Test
    func savingAndDeletingRefreshTheLists() async throws {
        let model = makeModel(authenticationFailure: nil)
        let name = try #require(SecretName(rawName: "API_KEY"))
        #expect(await model.save(name: name, value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .confirm, isSynchronized: true))
        let storedSecret = try #require(model.storedSecretsByRepository[repositoryIdentity]?.first)
        #expect(storedSecret.protectionLevel == .confirm)
        #expect(await model.delete(storedSecret: storedSecret))
        #expect(model.repositoryIdentities.isEmpty)
    }

    @Test
    func secretsStoredByAnotherFrontEndAppearAfterReload() async throws {
        let model = makeModel(authenticationFailure: nil)
        model.reload()
        #expect(model.repositoryIdentities.isEmpty)
        // What the command-line tool does: write through its own SecretStore.
        try await SecretStore(keychain: keychain, ownerAuthenticator: FixedOwnerAuthenticator(failure: nil))
            .set(name: try #require(SecretName(rawName: "FROM_CLI")), value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: nil, isSynchronized: nil)
        model.reload()
        #expect(model.storedSecretsByRepository[repositoryIdentity]?.map(\.name.value) == ["FROM_CLI"])
    }

    @Test
    func aDeviceBoundSecretIsSavedWithoutSynchronization() async throws {
        let model = makeModel(authenticationFailure: nil)
        #expect(await model.save(name: try #require(SecretName(rawName: "A")), value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .deviceBound, isSynchronized: true))
        #expect(model.storedSecretsByRepository[repositoryIdentity]?.first?.isSynchronized == false)
        #expect(model.presentedError == nil)
    }

    @Test
    func aCancelledPromptIsNotShownAsAnError() async throws {
        let name = try #require(SecretName(rawName: "A"))
        #expect(await makeModel(authenticationFailure: nil).save(name: name, value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .standard, isSynchronized: true))
        let model = makeModel(authenticationFailure: .authenticationCancelled)
        model.reload()
        let storedSecret = try #require(model.storedSecretsByRepository[repositoryIdentity]?.first)
        #expect(await model.revealedValue(storedSecret: storedSecret) == nil)
        #expect(model.presentedError == nil)
    }

    @Test
    func aFailedAuthenticationIsShownAndRevealsNothing() async throws {
        let name = try #require(SecretName(rawName: "A"))
        #expect(await makeModel(authenticationFailure: nil).save(name: name, value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .standard, isSynchronized: true))
        let model = makeModel(authenticationFailure: .authenticationFailed)
        model.reload()
        let storedSecret = try #require(model.storedSecretsByRepository[repositoryIdentity]?.first)
        #expect(await model.revealedValue(storedSecret: storedSecret) == nil)
        #expect(model.presentedError == .authenticationFailed)
    }

    @Test
    func aMissingEntitlementSwitchesToTheUnreachableScreen() {
        keychain.setFailure(failure: .missingEntitlement)
        let model = makeModel(authenticationFailure: nil)
        model.reload()
        #expect(model.isKeychainUnreachable)
        #expect(model.presentedError == nil)
        keychain.setFailure(failure: nil)
        model.reload()
        #expect(!model.isKeychainUnreachable)
    }

    @Test
    func revealingAValueLeavesNothingInTheModel() async throws {
        let model = makeModel(authenticationFailure: nil)
        let name = try #require(SecretName(rawName: "API_KEY"))
        #expect(await model.save(name: name, value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .standard, isSynchronized: true))
        let storedSecret = try #require(model.storedSecretsByRepository[repositoryIdentity]?.first)
        #expect(await model.revealedValue(storedSecret: storedSecret) == dummyValue)
        // The revealed value belongs to the view that asked for it; the model that outlives every
        // sheet must not hold one.
        #expect(!Mirror(reflecting: model).children.contains { $0.value is SecretValue })
    }

    @Test
    func demoDataReplacesAnUnreachableKeychain() {
        keychain.setFailure(failure: .missingEntitlement)
        let model = makeModel(authenticationFailure: nil)
        model.reload()
        #expect(model.isKeychainUnreachable)
        model.useDemoStore()
        #expect(!model.isKeychainUnreachable)
        #expect(model.presentedError == nil)
        let demoRepositoryIdentities = model.repositoryIdentities
        #expect(!demoRepositoryIdentities.isEmpty)
        model.useDemoStore()
        #expect(model.repositoryIdentities == demoRepositoryIdentities)
    }

    @Test
    func enteredRemoteURLsAreNormalizedLikeTheCommandLineTool() {
        // Qualified with the module name because the suite has a property of the same name.
        #expect(SecChainUI.repositoryIdentity(enteredText: " git@github.com:Example/A.git ").value == "github.com/example/a")
        #expect(SecChainUI.repositoryIdentity(enteredText: "https://github.com/example/a").value == "github.com/example/a")
        #expect(SecChainUI.repositoryIdentity(enteredText: "GitHub.com/Example/A").value == "github.com/example/a")
        // Like `--repository`, an identifier typed by hand is folded to lowercase.
        #expect(SecChainUI.repositoryIdentity(enteredText: "My-Notes").value == "my-notes")
    }
}
