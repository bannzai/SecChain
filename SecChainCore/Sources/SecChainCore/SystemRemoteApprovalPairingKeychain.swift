import Foundation
import Security

/// The pairing in the real data protection keychain: SecChain's shared access group, one generic
/// password item, *this device only* and never synchronized, because each Mac decides for itself
/// which iPhone may answer its authentications (documents/PROJECT.md, design decision 5).
///
/// The item has no `kSecAttrAccessControl`: the enrolled key is public, and `secchain run` has to
/// read it in exactly the situations where no prompt can be shown. The authentication that guards
/// a change is asked for by `RemoteApprovalPairingStore`.
public struct SystemRemoteApprovalPairingKeychain: RemoteApprovalPairingKeychain {
    /// Service of the item. It is outside `SecChainSharedConfig.keychainServicePrefix`, so no list
    /// query of the secrets can match it.
    static let service = "com.bannzai.SecChain.remoteApproval"
    /// Account of the item. One pairing per Mac, so the account is fixed.
    static let account = "pairing"

    public init() {}

    public func enrolledPairing() throws -> EnrolledPairing? {
        var query = Self.itemQuery()
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.error(status: status, operation: "read the pairing")
        }
        do {
            return try JSONDecoder().decode(EnrolledPairing.self, from: data)
        } catch {
            // An item this version cannot read is reported rather than ignored: treating it as
            // "not paired" would silently stop sending authentications to the iPhone.
            throw SecretStoreError.keychainFailure(
                operation: "read the pairing",
                status: errSecDecode,
                message: "The stored pairing cannot be read by this version of SecChain. Run 'secchain pair remove' and pair again."
            )
        }
    }

    public func write(enrolledPairing: EnrolledPairing) throws {
        let data = try JSONEncoder().encode(enrolledPairing)
        let updateStatus = SecItemUpdate(
            Self.itemQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else {
            guard updateStatus == errSecSuccess else {
                throw Self.error(status: updateStatus, operation: "update the pairing")
            }
            return
        }
        var attributes = Self.itemQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "SecChain: the iPhone paired with this Mac"
        // After first unlock, so that a `secchain run` started before the screen locked can still
        // read the enrolled key. `ThisDeviceOnly` keeps the pairing out of backups that migrate to
        // another Mac, which would otherwise start trusting a key its owner never enrolled there.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.error(status: addStatus, operation: "store the pairing")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(Self.itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status: status, operation: "remove the pairing")
        }
    }

    static func itemQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: SecChainSharedConfig.keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func error(status: OSStatus, operation: String) -> SecretStoreError {
        SecretStoreErrorMapping.error(status: status, operation: operation, name: account, repository: service)
    }
}
