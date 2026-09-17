/// Identifiers that the command-line tool, the macOS app, and the iOS app must agree on to see
/// the same Keychain items. They are defined once here because a mismatch in any of them makes
/// the front ends silently look at different items.
public enum SecChainSharedConfig {
    /// Apple Developer team that signs the official builds. Keychain access groups are prefixed
    /// with the team identifier, so a build signed by another team uses a separate set of items.
    public static let teamIdentifier = "TQPN82UBBY"

    /// Keychain access group shared by every front end. The same literal appears in the
    /// entitlements files, because `codesign` does not expand build-setting variables.
    public static let keychainAccessGroup = "\(teamIdentifier).com.bannzai.SecChain.shared"

    /// Prefix of the `kSecAttrService` attribute. The repository identity is appended to it, so
    /// that one repository's secrets can be enumerated with a single service query.
    public static let keychainServicePrefix = "com.bannzai.SecChain.repository."

    /// CloudKit container whose private database carries remote approval requests between the
    /// user's devices (documents/PROJECT.md, "Remote approval"). The same literal appears in the
    /// entitlements files.
    public static let cloudKitContainerIdentifier = "iCloud.com.bannzai.SecChain"
}
