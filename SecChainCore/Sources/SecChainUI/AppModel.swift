import Foundation
import Observation
import SecChainCore

/// State shared by the screens of both apps. It holds no secret value: a revealed value lives
/// only in the view that asked for it, and only while it is shown.
@Observable
public final class AppModel {
    /// Where secrets are read and written. Only a debug build replaces it (`useDemoStore()`).
    private(set) var store: SecretStore

    /// Repositories that have secrets, plus the ones added in this session that have none yet.
    public private(set) var repositoryIdentities: [RepositoryIdentity] = []
    /// Secrets of the repositories loaded so far.
    public private(set) var storedSecretsByRepository: [RepositoryIdentity: [StoredSecret]] = [:]
    /// Repository shown in the detail column.
    public var selectedRepositoryIdentity: RepositoryIdentity?
    /// Failure to show to the user. Set by every operation that throws.
    public var presentedError: SecretStoreError?
    /// `true` when the Keychain refused the binary itself (code signing), which makes every
    /// operation pointless and gets a dedicated screen instead of an alert.
    public private(set) var isKeychainUnreachable = false

    /// Repositories the user added before storing a first secret. They exist nowhere else, so
    /// they are gone after a restart unless a secret was stored.
    private var repositoryIdentitiesWithoutSecrets: [RepositoryIdentity] = []

    public init(store: SecretStore) {
        self.store = store
    }

    /// Reloads everything from the Keychain. Safe to call at any time (idempotent).
    public func reload() {
        do {
            let storedRepositoryIdentities = try store.repositoryIdentities()
            repositoryIdentitiesWithoutSecrets.removeAll(where: storedRepositoryIdentities.contains)
            repositoryIdentities = (storedRepositoryIdentities + repositoryIdentitiesWithoutSecrets)
                .sorted { $0.value < $1.value }
            storedSecretsByRepository = try Dictionary(
                uniqueKeysWithValues: repositoryIdentities.map { ($0, try store.storedSecrets(repositoryIdentity: $0)) }
            )
            isKeychainUnreachable = false
            if let selectedRepositoryIdentity, !repositoryIdentities.contains(selectedRepositoryIdentity) {
                self.selectedRepositoryIdentity = nil
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
        repositoryIdentitiesWithoutSecrets = []
        selectedRepositoryIdentity = nil
        reload()
    }
    #endif

    /// Makes a repository appear in the list so that its first secret can be added.
    public func addRepository(repositoryIdentity: RepositoryIdentity) {
        if !repositoryIdentities.contains(repositoryIdentity) {
            repositoryIdentitiesWithoutSecrets.append(repositoryIdentity)
        }
        reload()
        selectedRepositoryIdentity = repositoryIdentity
    }

    /// Returns whether the operation succeeded, so that a sheet knows whether to close.
    public func save(
        name: SecretName,
        value: SecretValue,
        repositoryIdentity: RepositoryIdentity,
        protectionLevel: ProtectionLevel,
        isSynchronized: Bool
    ) async -> Bool {
        await perform {
            _ = try await self.store.set(
                name: name,
                value: value,
                repositoryIdentity: repositoryIdentity,
                protectionLevel: protectionLevel,
                isSynchronized: protectionLevel == .deviceBound ? nil : isSynchronized
            )
        }
    }

    public func changeProtection(storedSecret: StoredSecret, protectionLevel: ProtectionLevel, isSynchronized: Bool) async -> Bool {
        await perform {
            _ = try await self.store.changeProtection(
                name: storedSecret.name,
                repositoryIdentity: storedSecret.repositoryIdentity,
                protectionLevel: protectionLevel,
                isSynchronized: protectionLevel == .deviceBound ? false : isSynchronized
            )
        }
    }

    public func delete(storedSecret: StoredSecret) async -> Bool {
        await perform {
            try await self.store.delete(name: storedSecret.name, repositoryIdentity: storedSecret.repositoryIdentity)
        }
    }

    /// The value after the owner authenticated, or `nil` (with `presentedError` set) otherwise.
    /// A cancelled prompt is not an error worth an alert.
    public func revealedValue(storedSecret: StoredSecret) async -> SecretValue? {
        do {
            return try await store.revealedValue(name: storedSecret.name, repositoryIdentity: storedSecret.repositoryIdentity)
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
