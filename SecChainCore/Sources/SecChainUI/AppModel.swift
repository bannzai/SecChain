import Foundation
import Observation
import SecChainCore

/// State shared by the screens of both apps. It holds no secret value: a revealed value lives
/// only in the view that asked for it, and only while it is shown.
@Observable
public final class AppModel {
    /// Where secrets are read and written. Only a debug build replaces it (`useDemoStore()`).
    private(set) var store: SecretStore
    /// Reads `~/.secchain`, `nil` when the file does not exist. Injected, like `store`, so that the
    /// tests and the demo data never touch the user's file.
    private var readUserDefinitionText: () throws -> String?
    /// Writes `~/.secchain`.
    private var writeUserDefinitionText: (String) throws -> Void

    /// Repositories that have secrets, plus the ones added in this session that have none yet.
    public private(set) var repositoryIdentities: [RepositoryIdentity] = []
    /// Every shared scope (`UserDefinition.sharedScopes`), plus the custom scopes added in this
    /// session that neither the Keychain nor `~/.secchain` knows yet.
    public private(set) var sharedScopes: [SharedScope] = []
    /// Secrets of the scopes loaded so far, repositories and shared scopes.
    public private(set) var storedSecretsByScope: [SecretScope: [StoredSecret]] = [:]
    /// What `~/.secchain` declares. `nil` while the file cannot be read, so that no toggle edits a
    /// file whose content the app does not know.
    public private(set) var userDefinition: UserDefinition?
    /// Why `~/.secchain` could not be read, or why the last edit of it failed. Shown next to the
    /// scopes instead of in an alert: the file stays broken until the user fixes it, while the
    /// Keychain part of the app keeps working.
    public private(set) var userDefinitionErrorDescription: String?
    /// Scope shown in the detail column: a repository or a shared scope.
    public var selectedScope: SecretScope?
    /// Failure to show to the user. Set by every operation that throws.
    public var presentedError: SecretStoreError?
    /// `true` when the Keychain refused the binary itself (code signing), which makes every
    /// operation pointless and gets a dedicated screen instead of an alert.
    public private(set) var isKeychainUnreachable = false

    /// Repositories and custom scopes the user added before storing a first secret. They exist
    /// nowhere else, so they are gone after a restart unless a secret was stored (or, for a custom
    /// scope, `~/.secchain` got a line of it).
    private var scopesWithoutSecrets: [SecretScope] = []

    public init(
        store: SecretStore,
        readUserDefinitionText: @escaping () throws -> String?,
        writeUserDefinitionText: @escaping (String) throws -> Void
    ) {
        self.store = store
        self.readUserDefinitionText = readUserDefinitionText
        self.writeUserDefinitionText = writeUserDefinitionText
    }

    /// Every scope of the sidebar: the repositories, then the shared scopes.
    public var scopes: [SecretScope] {
        repositoryIdentities.map(SecretScope.repository) + sharedScopes.map(SecretScope.shared)
    }

    /// Reloads everything from the Keychain and `~/.secchain`. Safe to call at any time
    /// (idempotent).
    public func reload() {
        reloadUserDefinition()
        do {
            let storedScopes = try store.scopes()
            scopesWithoutSecrets.removeAll { scope in
                storedScopes.contains(scope) || scope.sharedScope.flatMap { userDefinition?.scopeDefinition(scope: $0) } != nil
            }
            repositoryIdentities = (storedScopes + scopesWithoutSecrets)
                .compactMap(\.repositoryIdentity)
                .sorted { $0.value < $1.value }
            // An unreadable `~/.secchain` still leaves the scopes the Keychain knows.
            let listedSharedScopes = try (userDefinition ?? UserDefinitionText.parse(text: ""))
                .sharedScopes(storedScopes: storedScopes.compactMap(\.sharedScope))
            sharedScopes = listedSharedScopes
                + scopesWithoutSecrets.compactMap(\.sharedScope).filter { !listedSharedScopes.contains($0) }
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

    /// Reads `~/.secchain` apart from the Keychain, so that a broken file never hides a secret.
    func reloadUserDefinition() {
        do {
            userDefinition = try UserDefinitionText.parse(text: try readUserDefinitionText() ?? "")
            userDefinitionErrorDescription = nil
        } catch {
            userDefinition = nil
            userDefinitionErrorDescription = userDefinitionErrorMessage(error: error)
        }
    }

    #if DEBUG
    /// Replaces the Keychain and `~/.secchain` with demo data. A build without SecChain's signature
    /// cannot reach the Keychain, and a remote session (simtunnel) cannot pass launch arguments, so
    /// the switch is offered on screen. Calling it again starts over from the same demo data
    /// (idempotent).
    func useDemoStore() {
        store = AppModelFactory.demoStore()
        // Edits made on the demo screens stay in memory, so that they never reach the user's file.
        var demoUserDefinitionText: String? = AppModelFactory.demoUserDefinitionText
        readUserDefinitionText = { demoUserDefinitionText }
        writeUserDefinitionText = { demoUserDefinitionText = $0 }
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

    /// Makes a repository or a custom scope appear in the list so that its first secret can be
    /// added.
    public func add(scope: SecretScope) {
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
            _ = try await self.store.set(
                name: name,
                value: value,
                scope: scope,
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
                protectionLevel: protectionLevel,
                isSynchronized: protectionLevel == .deviceBound ? false : isSynchronized
            )
        }
    }

    public func delete(storedSecret: StoredSecret) async -> Bool {
        await perform {
            try await self.store.delete(name: storedSecret.name, scope: storedSecret.scope)
        }
    }

    /// The value after the owner authenticated, or `nil` (with `presentedError` set) otherwise.
    /// A cancelled prompt is not an error worth an alert.
    public func revealedValue(storedSecret: StoredSecret) async -> SecretValue? {
        do {
            return try await store.revealedValue(name: storedSecret.name, scope: storedSecret.scope)
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

    /// Passes the shared scope to the repository, or stops passing it, by adding or removing the
    /// `@allow` line that names the repository alone, as `secchain scope allow` / `scope deny` do.
    /// A wildcard that also names it stays (`wildcardAllowPattern`). The file is read right before
    /// it is written, so that a change made in a terminal meanwhile is kept. Setting the state the
    /// file already has leaves it unchanged (idempotent).
    public func setPassing(sharedScope: SharedScope, repositoryIdentity: RepositoryIdentity, isPassed: Bool) {
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
