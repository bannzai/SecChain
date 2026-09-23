import Foundation

/// Keychain double that keeps items in memory and reproduces the rules of the real one that
/// matter to callers: the synchronized and the local variant of a name are different items, and
/// a device-bound value is only returned together with an owner authentication.
///
/// It is part of the library (not the test target) because SwiftUI previews and UI tests of the
/// apps need it too. A class with a lock, because a Keychain is shared mutable state with
/// identity: every holder must observe the same items.
public final class InMemorySecretKeychain: SecretKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (storedSecret: StoredSecret, value: SecretValue)] = [:]
    /// When set, every call throws it. Lets callers rehearse failures such as a missing
    /// entitlement.
    private var failure: SecretStoreError?

    public init() {}

    public func setFailure(failure: SecretStoreError?) {
        lock.withLock {
            self.failure = failure
        }
    }

    public func storedSecrets(scope: SecretScope?) throws -> [StoredSecret] {
        try lock.withLock {
            try throwFailureIfSet()
            return items.values
                .map(\.storedSecret)
                .filter { scope == nil || $0.scope == scope }
        }
    }

    public func value(storedSecret: StoredSecret, ownerAuthentication: OwnerAuthentication?) throws -> SecretValue {
        try lock.withLock {
            try throwFailureIfSet()
            guard let item = items[storedSecret.id] else {
                throw SecretStoreError.secretNotFound(
                    name: storedSecret.name.value,
                    repository: storedSecret.scope.description
                )
            }
            guard item.storedSecret.protectionLevel != .deviceBound || ownerAuthentication != nil else {
                throw SecretStoreError.authenticationNotPossible
            }
            return item.value
        }
    }

    public func write(
        storedSecret: StoredSecret,
        value: SecretValue,
        replacing: StoredSecret?,
        ownerAuthentication: OwnerAuthentication?
    ) throws {
        try lock.withLock {
            try throwFailureIfSet()
            guard replacing != nil || items[storedSecret.id] == nil else {
                throw SecretStoreError.duplicateSecret(
                    name: storedSecret.name.value,
                    repository: storedSecret.scope.description
                )
            }
            if let replacing {
                items[replacing.id] = nil
            }
            items[storedSecret.id] = (
                storedSecret: StoredSecret(
                    scope: storedSecret.scope,
                    name: storedSecret.name,
                    protectionLevel: storedSecret.protectionLevel,
                    isSynchronized: storedSecret.isSynchronized,
                    modificationDate: Date()
                ),
                value: value
            )
        }
    }

    public func delete(storedSecret: StoredSecret) throws {
        try lock.withLock {
            try throwFailureIfSet()
            items[storedSecret.id] = nil
        }
    }

    private func throwFailureIfSet() throws {
        if let failure {
            throw failure
        }
    }
}
