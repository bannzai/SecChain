import Foundation
import LocalAuthentication
import Security

/// The real Keychain: data protection keychain, SecChain's shared access group, `SecItem` API.
///
/// Item layout:
///
/// - Every secret has a **generic password** item: service = the repository's service, account =
///   the secret name, `kSecAttrDescription` = the protection level, data = the value.
/// - A device-bound secret keeps an empty value in that item (it is only the listable marker) and
///   stores the real value in an **internet password** item (server = repository identity,
///   account = secret name) protected by an access control that demands user presence.
///
/// The split exists because a list query fails as a whole when it matches an access-controlled
/// item (measured by `KeychainDoctor.listingFailsWhenAnAccessControlledItemMatches`). Keeping the
/// protected values in another item class means that no generic-password query can ever match
/// them, so listing never prompts and never fails because of them.
public struct SystemSecretKeychain: SecretKeychain {
    public init() {}

    public func storedSecrets(repositoryIdentity: RepositoryIdentity?) throws -> [StoredSecret] {
        var query = Self.baseQuery(itemClass: kSecClassGenericPassword)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        if let repositoryIdentity {
            query[kSecAttrService as String] = repositoryIdentity.keychainService
        }
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status != errSecItemNotFound else {
            return []
        }
        guard status == errSecSuccess else {
            throw SecretStoreErrorMapping.error(
                status: status,
                operation: "list",
                name: "*",
                repository: repositoryIdentity?.value ?? "*"
            )
        }
        return ((items as? [[String: Any]]) ?? []).compactMap(Self.storedSecret(attributes:))
    }

    public func value(storedSecret: StoredSecret, ownerAuthentication: OwnerAuthentication?) throws -> SecretValue {
        var query = storedSecret.protectionLevel == .deviceBound
            ? Self.protectedValueQuery(storedSecret: storedSecret)
            : Self.itemQuery(storedSecret: storedSecret)
        query[kSecReturnData as String] = true
        if let context = ownerAuthentication?.context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.error(status: status, operation: "read", storedSecret: storedSecret)
        }
        return SecretValue(exposingData: data)
    }

    public func write(
        storedSecret: StoredSecret,
        value: SecretValue,
        replacing: StoredSecret?,
        ownerAuthentication: OwnerAuthentication?
    ) throws {
        // 1. The protected value first: if anything below fails, the old variant still exists.
        if storedSecret.protectionLevel == .deviceBound {
            try writeProtectedValue(storedSecret: storedSecret, value: value, ownerAuthentication: ownerAuthentication)
        }

        // 2. The generic password item (the value itself, or the marker of a device-bound secret).
        let itemData = storedSecret.protectionLevel == .deviceBound ? Data() : value.exposedData
        if let replacing, replacing.isSynchronized == storedSecret.isSynchronized {
            // Same Keychain item: one atomic update of value and protection level.
            let status = SecItemUpdate(
                Self.itemQuery(storedSecret: replacing) as CFDictionary,
                [
                    kSecValueData as String: itemData,
                    kSecAttrDescription as String: storedSecret.protectionLevel.rawValue,
                ] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw Self.error(status: status, operation: "update", storedSecret: storedSecret)
            }
        } else {
            var attributes = Self.itemQuery(storedSecret: storedSecret)
            attributes[kSecValueData as String] = itemData
            attributes[kSecAttrDescription as String] = storedSecret.protectionLevel.rawValue
            attributes[kSecAttrLabel as String] = "SecChain: \(storedSecret.repositoryIdentity.value) / \(storedSecret.name.value)"
            // After first unlock, so that long-running commands and builds keep working while the
            // screen is locked. The `ThisDeviceOnly` variant keeps a local secret out of backups
            // that migrate to another device, which is what "this device only" promises.
            attributes[kSecAttrAccessible as String] = storedSecret.isSynchronized
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw Self.error(status: status, operation: "add", storedSecret: storedSecret)
            }
            if let replacing {
                try deleteItem(query: Self.itemQuery(storedSecret: replacing), operation: "delete", storedSecret: replacing)
            }
        }

        // 3. A secret that stops being device-bound no longer needs its protected value.
        if let replacing, replacing.protectionLevel == .deviceBound, storedSecret.protectionLevel != .deviceBound {
            try deleteItem(query: Self.protectedValueQuery(storedSecret: replacing), operation: "delete", storedSecret: replacing)
        }
    }

    public func delete(storedSecret: StoredSecret) throws {
        try deleteItem(query: Self.protectedValueQuery(storedSecret: storedSecret), operation: "delete", storedSecret: storedSecret)
        try deleteItem(query: Self.itemQuery(storedSecret: storedSecret), operation: "delete", storedSecret: storedSecret)
    }

    // MARK: - Protected value

    func writeProtectedValue(
        storedSecret: StoredSecret,
        value: SecretValue,
        ownerAuthentication: OwnerAuthentication?
    ) throws {
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            // Requires a passcode / password to exist and never leaves the device, which is the
            // definition of the device-bound level.
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessControlError
        ) else {
            throw SecretStoreError.keychainFailure(
                operation: "create access control",
                status: errSecParam,
                message: "SecAccessControlCreateWithFlags failed"
            )
        }
        // Delete-then-add instead of update: updating an access-controlled item would itself
        // demand authentication, and the caller has already decided whether to authenticate.
        try deleteItem(query: Self.protectedValueQuery(storedSecret: storedSecret), operation: "delete", storedSecret: storedSecret)
        var attributes = Self.protectedValueQuery(storedSecret: storedSecret)
        attributes[kSecValueData as String] = value.exposedData
        attributes[kSecAttrAccessControl as String] = accessControl
        if let context = ownerAuthentication?.context {
            attributes[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            // errSecNotAvailable-like failures here usually mean that no passcode is set.
            throw Self.error(status: status, operation: "add device-bound value", storedSecret: storedSecret)
        }
    }

    // MARK: - Queries

    static func baseQuery(itemClass: CFString) -> [String: Any] {
        [
            kSecClass as String: itemClass,
            kSecAttrAccessGroup as String: SecChainSharedConfig.keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func itemQuery(storedSecret: StoredSecret) -> [String: Any] {
        var query = baseQuery(itemClass: kSecClassGenericPassword)
        query[kSecAttrService as String] = storedSecret.repositoryIdentity.keychainService
        query[kSecAttrAccount as String] = storedSecret.name.value
        query[kSecAttrSynchronizable as String] = storedSecret.isSynchronized
        return query
    }

    static func protectedValueQuery(storedSecret: StoredSecret) -> [String: Any] {
        var query = baseQuery(itemClass: kSecClassInternetPassword)
        query[kSecAttrServer as String] = storedSecret.repositoryIdentity.value
        query[kSecAttrAccount as String] = storedSecret.name.value
        query[kSecAttrSynchronizable as String] = false
        return query
    }

    /// Items that do not follow SecChain's layout (foreign services such as the doctor's, or an
    /// account that is not a valid secret name) are ignored rather than reported as secrets.
    static func storedSecret(attributes: [String: Any]) -> StoredSecret? {
        guard
            let service = attributes[kSecAttrService as String] as? String,
            let repositoryIdentity = RepositoryIdentity(keychainService: service),
            let account = attributes[kSecAttrAccount as String] as? String,
            let name = SecretName(rawName: account)
        else {
            return nil
        }
        return StoredSecret(
            repositoryIdentity: repositoryIdentity,
            name: name,
            // Items written before protection levels existed, or by hand, carry no description;
            // `standard` is the level whose behavior equals a plain item.
            protectionLevel: (attributes[kSecAttrDescription as String] as? String).flatMap(ProtectionLevel.init(rawValue:)) ?? .standard,
            isSynchronized: (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false,
            modificationDate: attributes[kSecAttrModificationDate as String] as? Date
        )
    }

    func deleteItem(query: [String: Any], operation: String, storedSecret: StoredSecret) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status: status, operation: operation, storedSecret: storedSecret)
        }
    }

    static func error(status: OSStatus, operation: String, storedSecret: StoredSecret) -> SecretStoreError {
        SecretStoreErrorMapping.error(
            status: status,
            operation: operation,
            name: storedSecret.name.value,
            repository: storedSecret.repositoryIdentity.value
        )
    }
}
