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

/// `~/.secchain` double: the text in memory, with an optional failure for reading and for writing.
final class InMemoryUserDefinitionFile {
    /// The file's text, `nil` while the file does not exist.
    var text: String?
    /// Thrown by every read while set.
    var readFailure: (any Error)?
    /// Thrown by every write while set.
    var writeFailure: (any Error)?

    func read() throws -> String? {
        if let readFailure {
            throw readFailure
        }
        return text
    }

    func write(text: String) throws {
        if let writeFailure {
            throw writeFailure
        }
        self.text = text
    }
}

@MainActor
@Suite
struct AppModelTests {
    let keychain = InMemorySecretKeychain()
    /// The `~/.secchain` every model of `makeMacModel` reads and writes.
    let userDefinitionFile = InMemoryUserDefinitionFile()
    let repositoryIdentity = RepositoryIdentity(value: "github.com/example/a")
    let dummyValue = SecretValue(exposingString: "dummy-value-for-test")

    /// A model without `~/.secchain`, as the iOS app has it.
    func makeModel(authenticationFailure: SecretStoreError?) -> AppModel {
        AppModel(store: SecretStore(keychain: keychain, ownerAuthenticator: FixedOwnerAuthenticator(failure: authenticationFailure)))
    }

    /// A model with `~/.secchain`, as the macOS app has it.
    func makeMacModel() -> AppModel {
        AppModel(
            store: SecretStore(keychain: keychain, ownerAuthenticator: FixedOwnerAuthenticator(failure: nil)),
            readUserDefinitionText: userDefinitionFile.read,
            writeUserDefinitionText: userDefinitionFile.write(text:)
        )
    }

    func customScope(_ rawName: String) throws -> SharedScope {
        // The label is omitted because every call site passes a literal name.
        .custom(try #require(CustomScopeName(rawName: rawName)))
    }

    // MARK: - ~/.secchain on the Mac

    @Test
    func theMacListsTheUserScopeAndTheCustomScopesOfTheFileAndOfTheKeychain() async throws {
        userDefinitionFile.text = "@scope youtube\n@scope design\n"
        let model = makeMacModel()
        // A scope that another Mac created arrives through the Keychain alone.
        #expect(await model.save(name: try #require(SecretName(rawName: "A")), value: dummyValue, scope: .shared(try customScope("newsletter")), protectionLevel: .standard, isSynchronized: true))
        #expect(model.sharedScopes == [.user, try customScope("design"), try customScope("newsletter"), try customScope("youtube")])
        #expect(model.storedSecretsByScope[.shared(try customScope("newsletter"))]?.map(\.name.value) == ["A"])
        #expect(model.storedSecretsByScope[.shared(.user)] == [])
    }

    @Test
    func aCustomScopeAddedOnTheMacLeavesTheFileAlone() throws {
        let model = makeMacModel()
        model.addScope(scope: .shared(try customScope("youtube")))
        model.addScope(scope: .shared(try customScope("youtube")))
        #expect(model.sharedScopes == [.user, try customScope("youtube")])
        #expect(model.selectedScope == .shared(try customScope("youtube")))
        #expect(userDefinitionFile.text == nil)
    }

    @Test
    func anUnreadableFileIsReportedAndLeavesTheKeychainsScopes() async throws {
        let model = makeMacModel()
        #expect(await model.save(name: try #require(SecretName(rawName: "A")), value: dummyValue, scope: .shared(try customScope("newsletter")), protectionLevel: .standard, isSynchronized: true))
        userDefinitionFile.text = "@scope youtube\nYOUTUBE_API_KEY=dummy-value-for-test\n"
        model.reload()
        #expect(model.userDefinition == nil)
        #expect(model.userDefinitionErrorDescription == userDefinitionErrorMessage(error: UserDefinitionError.valueNotAllowed(lineNumber: 2)))
        // The message never echoes the line.
        #expect(model.userDefinitionErrorDescription?.contains("dummy-value-for-test") == false)
        #expect(model.sharedScopes == [.user, try customScope("newsletter")])
        #expect(model.presentedError == nil)
        #expect(!model.isKeychainUnreachable)
        userDefinitionFile.text = "@scope youtube\n"
        model.reload()
        #expect(model.userDefinitionErrorDescription == nil)
    }

    @Test
    func turningAScopeOnAndOffAddsAndRemovesTheLineOfTheRepositoryAlone() throws {
        userDefinitionFile.text = "# mine\n@allow github.com/other/b\n\n@scope youtube\n"
        let model = makeMacModel()
        model.reload()
        model.setPassing(sharedScope: .user, repositoryIdentity: repositoryIdentity, isPassed: true)
        model.setPassing(sharedScope: .user, repositoryIdentity: repositoryIdentity, isPassed: true)
        #expect(userDefinitionFile.text == "# mine\n@allow github.com/other/b\n@allow github.com/example/a\n\n@scope youtube\n")
        #expect(model.isPassed(sharedScope: .user, repositoryIdentity: repositoryIdentity))
        #expect(!model.isPassed(sharedScope: try customScope("youtube"), repositoryIdentity: repositoryIdentity))
        model.setPassing(sharedScope: .user, repositoryIdentity: repositoryIdentity, isPassed: false)
        model.setPassing(sharedScope: .user, repositoryIdentity: repositoryIdentity, isPassed: false)
        #expect(userDefinitionFile.text == "# mine\n@allow github.com/other/b\n\n@scope youtube\n")
        #expect(!model.isPassed(sharedScope: .user, repositoryIdentity: repositoryIdentity))
    }

    @Test
    func turningAScopeOnWithoutAFileCreatesIt() throws {
        let model = makeMacModel()
        model.reload()
        model.setPassing(sharedScope: try customScope("youtube"), repositoryIdentity: repositoryIdentity, isPassed: true)
        let text = try #require(userDefinitionFile.text)
        #expect(try UserDefinitionText.parse(text: text).passedScopes(repositoryIdentity: repositoryIdentity) == [.repository(repositoryIdentity), .shared(try customScope("youtube"))])
        #expect(model.sharedScopes == [.user, try customScope("youtube")])
    }

    @Test
    func turningAScopeOffRemovesTheLineWhateverItsLetterCase() throws {
        userDefinitionFile.text = "@allow github.com/Example/A\n"
        let model = makeMacModel()
        model.reload()
        #expect(model.isPassed(sharedScope: .user, repositoryIdentity: repositoryIdentity))
        model.setPassing(sharedScope: .user, repositoryIdentity: repositoryIdentity, isPassed: false)
        #expect(userDefinitionFile.text == "")
    }

    @Test
    func aWildcardThatPassesTheScopeIsReportedAndKept() throws {
        userDefinitionFile.text = "@allow github.com/example/*\n@allow github.com/example/a\n"
        let model = makeMacModel()
        model.reload()
        #expect(model.wildcardAllowPattern(sharedScope: .user, repositoryIdentity: repositoryIdentity) == "github.com/example/*")
        #expect(model.wildcardAllowPattern(sharedScope: .user, repositoryIdentity: RepositoryIdentity(value: "github.com/example-other/a")) == nil)
        model.setPassing(sharedScope: .user, repositoryIdentity: repositoryIdentity, isPassed: false)
        #expect(userDefinitionFile.text == "@allow github.com/example/*\n")
        #expect(model.isPassed(sharedScope: .user, repositoryIdentity: repositoryIdentity))
    }

    @Test
    func anIdentifierThatALineCannotNameAloneIsNeverAllowed() throws {
        let model = makeMacModel()
        model.reload()
        // Typed by hand in Add Repository. As a line it would pass the scope to every repository
        // of the owner.
        let wildcardLikeIdentity = RepositoryIdentity(value: "github.com/example/*")
        #expect(!model.canAllowAlone(repositoryIdentity: wildcardLikeIdentity))
        #expect(!model.canAllowAlone(repositoryIdentity: RepositoryIdentity(value: "my notes")))
        #expect(model.canAllowAlone(repositoryIdentity: repositoryIdentity))
        model.setPassing(sharedScope: .user, repositoryIdentity: wildcardLikeIdentity, isPassed: true)
        #expect(userDefinitionFile.text == nil)
        #expect(!model.isPassed(sharedScope: .user, repositoryIdentity: RepositoryIdentity(value: "github.com/example/b")))
    }

    @Test
    func aFailedWriteIsReportedAndChangesNothing() throws {
        userDefinitionFile.text = "@scope youtube\n"
        let model = makeMacModel()
        model.reload()
        userDefinitionFile.writeFailure = CocoaError(.fileWriteNoPermission)
        model.setPassing(sharedScope: try customScope("youtube"), repositoryIdentity: repositoryIdentity, isPassed: true)
        #expect(userDefinitionFile.text == "@scope youtube\n")
        #expect(model.userDefinitionErrorDescription == CocoaError(.fileWriteNoPermission).localizedDescription)
        #expect(!model.isPassed(sharedScope: try customScope("youtube"), repositoryIdentity: repositoryIdentity))
        #expect(model.presentedError == nil)
    }

    @Test
    func aFileThatCannotBeReadIsNotEdited() throws {
        userDefinitionFile.text = "@scope youtube\n"
        let model = makeMacModel()
        model.reload()
        userDefinitionFile.readFailure = CocoaError(.fileReadNoPermission)
        model.setPassing(sharedScope: try customScope("youtube"), repositoryIdentity: repositoryIdentity, isPassed: true)
        #expect(userDefinitionFile.text == "@scope youtube\n")
        #expect(model.userDefinition == nil)
        #expect(model.userDefinitionErrorDescription == CocoaError(.fileReadNoPermission).localizedDescription)
    }

    @Test
    func demoDataOnTheMacNeverReachesTheUsersFile() throws {
        let model = makeMacModel()
        model.useDemoStore()
        // The scopes of the demo `~/.secchain`, and the demo Keychain's.
        #expect(model.sharedScopes == [.user, try customScope("design"), try customScope("youtube")])
        model.setPassing(sharedScope: try customScope("design"), repositoryIdentity: repositoryIdentity, isPassed: true)
        #expect(model.isPassed(sharedScope: try customScope("design"), repositoryIdentity: repositoryIdentity))
        #expect(userDefinitionFile.text == nil)
        model.useDemoStore()
        #expect(!model.isPassed(sharedScope: try customScope("design"), repositoryIdentity: repositoryIdentity))
    }

    @Test
    func withoutAFileNothingIsReadOrEdited() throws {
        let model = makeModel(authenticationFailure: nil)
        model.reload()
        model.setPassing(sharedScope: .user, repositoryIdentity: repositoryIdentity, isPassed: true)
        #expect(model.scopes.isEmpty)
        #expect(model.userDefinition == nil)
        #expect(model.userDefinitionErrorDescription == nil)
    }

    // MARK: - Scopes and secrets

    @Test
    func aRepositoryAddedInTheAppIsListedBeforeItHasSecrets() {
        let model = makeModel(authenticationFailure: nil)
        model.addScope(scope: .repository(repositoryIdentity))
        #expect(model.repositoryIdentities == [repositoryIdentity])
        #expect(model.selectedScope == .repository(repositoryIdentity))
        #expect(model.storedSecretsByScope[.repository(repositoryIdentity)] == [])
    }

    @Test
    func aCustomScopeAddedInTheAppIsListedBeforeItHasSecrets() throws {
        let model = makeModel(authenticationFailure: nil)
        let youtubeScope = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "youtube"))))
        model.addScope(scope: youtubeScope)
        #expect(model.scopes == [youtubeScope])
        #expect(model.repositoryIdentities.isEmpty)
        #expect(model.selectedScope == youtubeScope)
        #expect(model.storedSecretsByScope[youtubeScope] == [])
    }

    @Test
    func sharedScopesAreListedAfterTheRepositoriesWithTheUserScopeFirst() async throws {
        let model = makeModel(authenticationFailure: nil)
        let name = try #require(SecretName(rawName: "API_KEY"))
        let awsScope = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "aws"))))
        let zooScope = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "zoo"))))
        // "aws" sorts before "user" by name, and the Keychain service of a repository before both.
        for scope in [zooScope, .shared(.user), awsScope, .repository(repositoryIdentity)] {
            #expect(await model.save(name: name, value: dummyValue, scope: scope, protectionLevel: .standard, isSynchronized: true))
        }
        #expect(model.scopes == [.repository(repositoryIdentity), .shared(.user), awsScope, zooScope])
        #expect(model.repositoryIdentities == [repositoryIdentity])
        #expect(model.sharedScopes == [.user, try #require(awsScope.sharedScope), try #require(zooScope.sharedScope)])
    }

    @Test
    func aSharedScopeSecretIsSavedRevealedAndDeletedInItsScope() async throws {
        let model = makeModel(authenticationFailure: nil)
        let name = try #require(SecretName(rawName: "API_KEY"))
        #expect(await model.save(name: name, value: dummyValue, scope: .shared(.user), protectionLevel: .confirm, isSynchronized: true))
        // The same name in a repository is another secret.
        #expect(model.storedSecretsByScope[.repository(repositoryIdentity)] == nil)
        let storedSecret = try #require(model.storedSecretsByScope[.shared(.user)]?.first)
        #expect(storedSecret.scope == .shared(.user))
        #expect(await model.revealedValue(storedSecret: storedSecret) == dummyValue)
        #expect(await model.delete(storedSecret: storedSecret))
        #expect(model.scopes.isEmpty)
    }

    @Test
    func savingAndDeletingRefreshTheLists() async throws {
        let model = makeModel(authenticationFailure: nil)
        let name = try #require(SecretName(rawName: "API_KEY"))
        #expect(await model.save(name: name, value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .confirm, isSynchronized: true))
        let storedSecret = try #require(model.storedSecretsByScope[.repository(repositoryIdentity)]?.first)
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
        #expect(model.storedSecretsByScope[.repository(repositoryIdentity)]?.map(\.name.value) == ["FROM_CLI"])
    }

    @Test
    func aDeviceBoundSecretIsSavedWithoutSynchronization() async throws {
        let model = makeModel(authenticationFailure: nil)
        #expect(await model.save(name: try #require(SecretName(rawName: "A")), value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .deviceBound, isSynchronized: true))
        #expect(model.storedSecretsByScope[.repository(repositoryIdentity)]?.first?.isSynchronized == false)
        #expect(model.presentedError == nil)
    }

    @Test
    func aCancelledPromptIsNotShownAsAnError() async throws {
        let name = try #require(SecretName(rawName: "A"))
        #expect(await makeModel(authenticationFailure: nil).save(name: name, value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .standard, isSynchronized: true))
        let model = makeModel(authenticationFailure: .authenticationCancelled)
        model.reload()
        let storedSecret = try #require(model.storedSecretsByScope[.repository(repositoryIdentity)]?.first)
        #expect(await model.revealedValue(storedSecret: storedSecret) == nil)
        #expect(model.presentedError == nil)
    }

    @Test
    func aFailedAuthenticationIsShownAndRevealsNothing() async throws {
        let name = try #require(SecretName(rawName: "A"))
        #expect(await makeModel(authenticationFailure: nil).save(name: name, value: dummyValue, scope: .repository(repositoryIdentity), protectionLevel: .standard, isSynchronized: true))
        let model = makeModel(authenticationFailure: .authenticationFailed)
        model.reload()
        let storedSecret = try #require(model.storedSecretsByScope[.repository(repositoryIdentity)]?.first)
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
        let storedSecret = try #require(model.storedSecretsByScope[.repository(repositoryIdentity)]?.first)
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
        // Like `--repository`, an identifier typed by hand is folded to lowercase, and so is a text
        // that only looks like a remote.
        #expect(SecChainUI.repositoryIdentity(enteredText: "My-Notes").value == "my-notes")
        #expect(SecChainUI.repositoryIdentity(enteredText: "Foo@Bar").value == "foo@bar")
        #expect(SecChainUI.repositoryIdentity(enteredText: "Example.COM/").value == "example.com/")
    }
}
