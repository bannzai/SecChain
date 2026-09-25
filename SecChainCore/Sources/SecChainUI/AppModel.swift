import Foundation
import Observation
import SecChainCore

/// State shared by the screens of both apps. It holds no secret value: a revealed value lives
/// only in the view that asked for it, and only while it is shown.
@Observable
public final class AppModel {
    /// Where secrets are read and written. Only a debug build replaces it (`useDemoStore()`).
    private(set) var store: SecretStore

    /// Scopes that have secrets on this device, plus the ones added in this session that have none
    /// yet: the repositories first, then the user scope, then the custom scopes.
    public private(set) var scopes: [SecretScope] = []
    /// Secrets of the scopes loaded so far.
    public private(set) var storedSecretsByScope: [SecretScope: [StoredSecret]] = [:]
    /// Scope shown in the detail column.
    public var selectedScope: SecretScope?
    /// Failure to show to the user. Set by every operation that throws.
    public var presentedError: SecretStoreError?
    /// `true` when the Keychain refused the binary itself (code signing), which makes every
    /// operation pointless and gets a dedicated screen instead of an alert.
    public private(set) var isKeychainUnreachable = false

    /// Scopes the user added before storing a first secret. They exist nowhere else, so they are
    /// gone after a restart unless a secret was stored.
    private var scopesWithoutSecrets: [SecretScope] = []

    public init(store: SecretStore) {
        self.store = store
    }

    /// The repositories among `scopes`.
    public var repositoryIdentities: [RepositoryIdentity] {
        scopes.compactMap(\.repositoryIdentity)
    }

    /// The user scope and the custom scopes among `scopes`.
    public var sharedScopes: [SharedScope] {
        scopes.compactMap(\.sharedScope)
    }

    /// Reloads everything from the Keychain. Safe to call at any time (idempotent).
    public func reload() {
        do {
            let storedScopes = try store.scopes()
            scopesWithoutSecrets.removeAll(where: storedScopes.contains)
            scopes = (storedScopes + scopesWithoutSecrets)
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

    #if DEBUG
    /// Replaces the Keychain with demo data. A build without SecChain's signature cannot reach the
    /// Keychain, and a remote session (simtunnel) cannot pass launch arguments, so the switch is
    /// offered on screen. Calling it again starts over from the same demo data (idempotent).
    func useDemoStore() {
        store = AppModelFactory.demoStore()
        scopesWithoutSecrets = []
        selectedScope = nil
        reload()
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
