import Foundation

/// The non-secret facts about one secret, exactly as the Keychain item's attributes hold them.
/// It is what listing returns; the value is never part of it.
public struct StoredSecret: Hashable, Sendable, Identifiable {
    /// Repository the secret belongs to (from `kSecAttrService`).
    public let repositoryIdentity: RepositoryIdentity
    /// Secret name (from `kSecAttrAccount`).
    public let name: SecretName
    /// Protection level (from `kSecAttrDescription`).
    public let protectionLevel: ProtectionLevel
    /// Whether the item is eligible for iCloud Keychain (`kSecAttrSynchronizable`). The Keychain
    /// treats the synchronized and the local variant of one name as two different items.
    public let isSynchronized: Bool
    /// Last modification (from `kSecAttrModificationDate`), `nil` for a secret not yet written.
    public let modificationDate: Date?

    public init(
        repositoryIdentity: RepositoryIdentity,
        name: SecretName,
        protectionLevel: ProtectionLevel,
        isSynchronized: Bool,
        modificationDate: Date?
    ) {
        self.repositoryIdentity = repositoryIdentity
        self.name = name
        self.protectionLevel = protectionLevel
        self.isSynchronized = isSynchronized
        self.modificationDate = modificationDate
    }

    /// Identity of the Keychain item: repository, name and the synchronizable flag.
    public var id: String {
        "\(repositoryIdentity.value)\u{0}\(name.value)\u{0}\(isSynchronized)"
    }
}
