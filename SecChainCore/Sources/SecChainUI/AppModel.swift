import Foundation
import Observation
import SecChainCore

/// State shared by the screens of both apps. It holds no secret value: a revealed value lives
/// only in the view that asked for it, and only while it is shown.
@Observable
public final class AppModel {
    /// Where secrets are read and written. Only a debug build replaces it (`useDemoStore()`).
    private(set) var store: SecretStore
    /// Reads `~/.secchain`, `nil` when the file does not exist. The function itself is `nil` in the
    /// iOS app, which has no such file. Injected, like `store`, so that the tests and the demo data
    /// never touch the user's file.
    private var readUserDefinitionText: (() throws -> String?)?
    /// Writes `~/.secchain`. `nil` in the iOS app.
    private var writeUserDefinitionText: ((String) throws -> Void)?

    /// Scopes that have secrets on this device, the ones `~/.secchain` names on a Mac, and the ones
    /// added in this session that have none yet: the repositories first, then the user scope, then
    /// the custom scopes.
    public private(set) var scopes: [SecretScope] = []
    /// Secrets of the scopes loaded so far.
    public private(set) var storedSecretsByScope: [SecretScope: [StoredSecret]] = [:]
    /// What `~/.secchain` declares. `nil` in the iOS app and while the file cannot be read, so that
    /// no switch edits a file whose content the app does not know.
    public private(set) var userDefinition: UserDefinition?
    /// Why `~/.secchain` could not be read, or why the last edit of it failed. Shown next to the
    /// scopes instead of in an alert: the file stays broken until the user fixes it, while the
    /// Keychain part of the app keeps working.
    public private(set) var userDefinitionErrorDescription: String?
    /// Scope shown in the detail column.
    public var selectedScope: SecretScope?
    /// Failure to show to the user. Set by every operation that throws.
    public var presentedError: SecretStoreError?
    /// `true` when the Keychain refused the binary itself (code signing), which makes every
    /// operation pointless and gets a dedicated screen instead of an alert.
    public private(set) var isKeychainUnreachable = false

    /// Scopes the user added before storing a first secret. They exist nowhere else, so they are
    /// gone after a restart unless a secret was stored (or, for a custom scope, `~/.secchain` got a
    /// line of it).
    private var scopesWithoutSecrets: [SecretScope] = []

    // No `~/.secchain` by default: that is the iOS app, which never runs a command and so never
    // needs to know which scopes a repository gets. The macOS app passes both functions.
    public init(
        store: SecretStore,
        readUserDefinitionText: (() throws -> String?)? = nil,
        writeUserDefinitionText: ((String) throws -> Void)? = nil
    ) {
        self.store = store
        self.readUserDefinitionText = readUserDefinitionText
        self.writeUserDefinitionText = writeUserDefinitionText
    }

    /// The repositories among `scopes`.
    public var repositoryIdentities: [RepositoryIdentity] {
        scopes.compactMap(\.repositoryIdentity)
    }

    /// The user scope and the custom scopes among `scopes`.
    public var sharedScopes: [SharedScope] {
        scopes.compactMap(\.sharedScope)
    }

    /// Reloads everything from the Keychain and `~/.secchain`. Safe to call at any time
    /// (idempotent).
    public func reload() {
        reloadUserDefinition()
        do {
            // A scope another Mac created arrives through the Keychain alone, and one written in
            // `~/.secchain` may have no secret yet, so the list is the union of both.
            let knownScopes = try store.scopes() + definedScopes
            scopesWithoutSecrets.removeAll(where: knownScopes.contains)
            scopes = Array(Set(knownScopes + scopesWithoutSecrets))
                .sorted { listOrder(scope: $0) < listOrder(scope: $1) }
            storedSecretsByScope = try Dictionary(
                uniqueKeysWithValues: scopes.map { ($0, try store.storedSecrets(scope: $0)) }
            )
            isKeychainUnreachable = false
            if let selectedScope, !scopes.contains(selectedScope) {
                self.selectedScope = nil
            }
        } catch {
            present(error: error)
        }
    }

    /// The shared scopes `~/.secchain` names on a Mac: the user scope, which every Mac has, and the
    /// custom scopes of its `@scope` lines. None in the iOS app.
    var definedScopes: [SecretScope] {
        guard readUserDefinitionText != nil else {
            return []
        }
        return [.shared(.user)] + (userDefinition?.customScopes ?? []).map { .shared($0.scope) }
    }

    /// Reads `~/.secchain` apart from the Keychain, so that a broken file never hides a secret.
    func reloadUserDefinition() {
        guard let readUserDefinitionText else {
            return
        }
        do {
            userDefinition = try UserDefinitionText.parse(text: try readUserDefinitionText() ?? "")
            userDefinitionErrorDescription = nil
        } catch {
            userDefinition = nil
            userDefinitionErrorDescription = userDefinitionErrorMessage(error: error)
        }
    }

    #if DEBUG
    /// Replaces the Keychain with demo data, and on a Mac `~/.secchain` too. A build without
    /// SecChain's signature cannot reach the Keychain, and a remote session (simtunnel) cannot pass
    /// launch arguments, so the switch is offered on screen. Calling it again starts over from the
    /// same demo data (idempotent).
    func useDemoStore() {
        store = AppModelFactory.demoStore()
        if readUserDefinitionText != nil {
            // Edits made on the demo screens stay in memory, so that they never reach the user's
            // file.
            var demoUserDefinitionText: String? = AppModelFactory.demoUserDefinitionText
            readUserDefinitionText = { demoUserDefinitionText }
            writeUserDefinitionText = { demoUserDefinitionText = $0 }
        }
        scopesWithoutSecrets = []
        selectedScope = nil
        reload()
    }

    /// Shows how an unreadable `~/.secchain` looks, which demo data and a remote session cannot
    /// produce otherwise. The next reload reads the file again.
    func showSampleUserDefinitionError() {
        userDefinition = nil
        userDefinitionErrorDescription = userDefinitionErrorMessage(error: UserDefinitionError.valueNotAllowed(lineNumber: 3))
    }
    #endif

    /// Makes a repository or a shared scope appear in the list so that its first secret can be
    /// added.
    public func addScope(scope: SecretScope) {
        if !scopes.contains(scope) {
            scopesWithoutSecrets.append(scope)
        }
        reload()
        selectedScope = scope
    }

    /// Returns whether the operation succeeded, so that a sheet knows whether to close.
    public func save(
        name: SecretName,
        value: SecretValue,
        scope: SecretScope,
        protectionLevel: ProtectionLevel,
        isSynchronized: Bool
    ) async -> Bool {
        await perform {
            // The apps cannot choose an environment yet, so a new secret is one without an
            // environment. `SecretStore.set` refuses it in a scope that has environments.
            _ = try await self.store.set(
                name: name,
                value: value,
                scope: scope,
                environment: nil,
                protectionLevel: protectionLevel,
                isSynchronized: protectionLevel == .deviceBound ? nil : isSynchronized
            )
        }
    }

    public func changeProtection(storedSecret: StoredSecret, protectionLevel: ProtectionLevel, isSynchronized: Bool) async -> Bool {
        await perform {
            _ = try await self.store.changeProtection(
                name: storedSecret.name,
                scope: storedSecret.scope,
                environment: storedSecret.environment,
                protectionLevel: protectionLevel,
                isSynchronized: protectionLevel == .deviceBound ? false : isSynchronized
            )
        }
    }

    public func delete(storedSecret: StoredSecret) async -> Bool {
        await perform {
            try await self.store.delete(name: storedSecret.name, scope: storedSecret.scope, environment: storedSecret.environment)
        }
    }

    /// The value after the owner authenticated, or `nil` (with `presentedError` set) otherwise.
    /// A cancelled prompt is not an error worth an alert.
    public func revealedValue(storedSecret: StoredSecret) async -> SecretValue? {
        do {
            return try await store.revealedValue(name: storedSecret.name, scope: storedSecret.scope, environment: storedSecret.environment)
        } catch SecretStoreError.authenticationCancelled {
            return nil
        } catch {
            present(error: error)
            return nil
        }
    }

    // MARK: - Scopes passed to a repository

    /// Whether `secchain run` passes the shared scope to the repository, through any `@allow`.
    public func isPassed(sharedScope: SharedScope, repositoryIdentity: RepositoryIdentity) -> Bool {
        userDefinition?.scopeDefinition(scope: sharedScope)?.isAllowed(repositoryIdentity: repositoryIdentity) ?? false
    }

    /// The `@allow` pattern ending in `*` that passes the shared scope to the repository, `nil`
    /// when none does. Such a pattern names other repositories too, so a switch for this one
    /// repository must not remove it.
    public func wildcardAllowPattern(sharedScope: SharedScope, repositoryIdentity: RepositoryIdentity) -> String? {
        userDefinition?.scopeDefinition(scope: sharedScope)?.allowPatterns.first { allowPattern in
            allowPattern.hasSuffix("*") && repositoryPatternMatches(pattern: allowPattern, repositoryIdentity: repositoryIdentity)
        }
    }

    /// Whether `@allow <identifier>` names the repository alone. An identifier typed by hand may end
    /// in `*`, which the line would read as a wildcard that passes the scope to other repositories
    /// too, or contain `*` elsewhere, whitespace, or `=`, which no `@allow` line can hold.
    public func canAllowAlone(repositoryIdentity: RepositoryIdentity) -> Bool {
        !repositoryIdentity.value.contains("*") && isValidRepositoryPattern(pattern: repositoryIdentity.value)
    }

    /// Passes the shared scope to the repository, or stops passing it, by adding or removing the
    /// `@allow` line that names the repository alone, as `secchain scope allow` / `scope deny` do.
    /// A wildcard that also names it stays (`wildcardAllowPattern`). The file is read right before
    /// it is written, so that a change made in a terminal meanwhile is kept. Setting the state the
    /// file already has leaves it unchanged (idempotent). Does nothing in the iOS app, and adds no
    /// line for a repository that no line can name alone (`canAllowAlone`).
    public func setPassing(sharedScope: SharedScope, repositoryIdentity: RepositoryIdentity, isPassed: Bool) {
        guard let readUserDefinitionText, let writeUserDefinitionText else {
            return
        }
        guard !isPassed || canAllowAlone(repositoryIdentity: repositoryIdentity) else {
            return
        }
        do {
            let text = try readUserDefinitionText()
            let editedText: String?
            if isPassed {
                editedText = try UserDefinitionText.adding(allowPattern: repositoryIdentity.value, scope: sharedScope, text: text)
            } else if let text {
                // The identifier as the line spells it, which may differ in letter case.
                editedText = try (UserDefinitionText.parse(text: text).scopeDefinition(scope: sharedScope)?.allowPatterns ?? [])
                    .filter { !$0.hasSuffix("*") && repositoryPatternMatches(pattern: $0, repositoryIdentity: repositoryIdentity) }
                    .reduce(text) { editedText, allowPattern in
                        try UserDefinitionText.removing(allowPattern: allowPattern, scope: sharedScope, text: editedText)
                    }
            } else {
                editedText = nil
            }
            if let editedText {
                try writeUserDefinitionText(editedText)
            }
            reload()
        } catch {
            reload()
            userDefinitionErrorDescription = userDefinitionErrorMessage(error: error)
        }
    }

    func perform(operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            reload()
            return true
        } catch SecretStoreError.authenticationCancelled {
            return false
        } catch {
            present(error: error)
            return false
        }
    }

    func present(error: any Error) {
        let secretStoreError = (error as? SecretStoreError)
            ?? .keychainFailure(operation: "operation", status: 0, message: "\(error)")
        if secretStoreError == .missingEntitlement {
            isKeychainUnreachable = true
        } else {
            presentedError = secretStoreError
        }
    }
}

/// The message of a failure to read or edit `~/.secchain`, in the app's language where SecChain
/// words it. A file system failure keeps the system's wording, which names the file and the cause.
func userDefinitionErrorMessage(error: any Error) -> String {
    (error as? UserDefinitionError)?.message(bundle: .module) ?? error.localizedDescription
}

/// Position of a scope in the list. Repositories come first because they are what most secrets
/// belong to; the user scope precedes the custom scopes because it is the one every Mac has.
func listOrder(scope: SecretScope) -> (Int, String) {
    switch scope {
    case .repository(let repositoryIdentity):
        (0, repositoryIdentity.value)
    case .shared(.user):
        (1, SharedScope.userScopeName)
    case .shared(.custom(let customScopeName)):
        (2, customScopeName.value)
    }
}
