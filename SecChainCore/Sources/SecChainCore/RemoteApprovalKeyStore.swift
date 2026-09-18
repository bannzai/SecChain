import Foundation
import Security

/// Where the approving device keeps its approval key between launches, and how it is created again
/// when the user pairs a second time.
///
/// A protocol for the same reason as `SecretKeychain`: the screens and the answering policy are
/// exercised without a Secure Enclave, which the Simulator does not offer for a key that requires
/// Face ID (documents/PROJECT.md, "Remote approval spike").
public protocol RemoteApprovalKeyStore: Sendable {
    /// The key this device created earlier, `nil` before the first pairing.
    func existingKey() throws -> (any RemoteApprovalKey)?

    /// A new key, replacing whatever was stored. Every Mac that enrolled the old key has to pair
    /// again, which is what makes this "pair again" rather than a silent repair.
    func createKey() throws -> any RemoteApprovalKey

    /// Removes the key. Removing what is not there succeeds (idempotent), so unpairing converges
    /// whatever state the device was in.
    func deleteKey() throws
}

/// The real key store: the key lives in the Secure Enclave and the Keychain holds only the blob
/// that turns it back into a usable key on this device.
///
/// The item carries no access group, so it stays in the app's own group instead of the one shared
/// with the Mac front ends (`SecChainSharedConfig.keychainAccessGroup`): a Mac enrolls the public
/// key through CloudKit and never needs to read anything of the iPhone's key.
public struct SecureEnclaveRemoteApprovalKeyStore: RemoteApprovalKeyStore {
    /// `kSecAttrService` of the item. It names the key rather than a repository, because the
    /// approval key belongs to the device and not to any of the stored secrets.
    static let keychainService = "com.bannzai.SecChain.remote-approval-key"
    /// `kSecAttrAccount` of the item. One device has one approval key, so the account is fixed.
    static let keychainAccount = "approval-key"

    /// Explanation shown in the Face ID / Touch ID prompt of every approval, in the app's language.
    let authenticationReason: String

    public init(authenticationReason: String) {
        self.authenticationReason = authenticationReason
    }

    public func existingKey() throws -> (any RemoteApprovalKey)? {
        var query = Self.itemQuery()
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let dataRepresentation = item as? Data else {
            throw RemoteApprovalKeyError.storageFailed(operation: "read", status: status)
        }
        return try SecureEnclaveRemoteApprovalKey(
            dataRepresentation: dataRepresentation,
            authenticationReason: authenticationReason
        )
    }

    public func createKey() throws -> any RemoteApprovalKey {
        let key = try SecureEnclaveRemoteApprovalKey.created(authenticationReason: authenticationReason)
        try deleteKey()
        var attributes = Self.itemQuery()
        attributes[kSecValueData as String] = key.dataRepresentation
        // The blob is worthless on another device, and the enclave key behind it requires a
        // passcode anyway, so the item is stored with the strictest class that still allows the app
        // to read it while the device is unlocked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RemoteApprovalKeyError.storageFailed(operation: "save", status: status)
        }
        return key
    }

    public func deleteKey() throws {
        let status = SecItemDelete(Self.itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteApprovalKeyError.storageFailed(operation: "delete", status: status)
        }
    }

    /// The one item the store owns.
    static func itemQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            // The key cannot be used on another device, so synchronizing the blob would only put a
            // useless item into iCloud Keychain.
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// A key store that keeps a key in memory for as long as the process runs, for unit tests and for
/// the debug demo of the approval screen. A class with a lock, because it is mutable state with
/// identity, the same reason `InMemoryRemoteApprovalStore` is one.
public final class InMemoryRemoteApprovalKeyStore: RemoteApprovalKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: (any RemoteApprovalKey)?

    public init() {}

    public func existingKey() throws -> (any RemoteApprovalKey)? {
        lock.withLock {
            key
        }
    }

    public func createKey() throws -> any RemoteApprovalKey {
        lock.withLock {
            let createdKey = SoftwareRemoteApprovalKey()
            key = createdKey
            return createdKey
        }
    }

    public func deleteKey() throws {
        lock.withLock {
            key = nil
        }
    }
}
