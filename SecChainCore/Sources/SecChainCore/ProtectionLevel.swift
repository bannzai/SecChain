/// How much user authentication a secret asks for (documents/PROJECT.md, "Protection levels").
/// The raw value is what is stored in the Keychain item's `kSecAttrDescription` and what the
/// command-line tool accepts, so it must stay stable.
public enum ProtectionLevel: String, CaseIterable, Sendable, Comparable {
    /// No prompt for `run`. Authentication only when a value is revealed in an app.
    case standard
    /// SecChain asks for authentication before every read by `run` and before update / delete.
    /// The item itself is unprotected, so it can synchronize.
    case confirm
    /// The Keychain itself demands user presence on every read, and the item never leaves the
    /// device.
    case deviceBound = "device-bound"

    /// Ordered by strictness, so that "lowering the level" can be detected with `<`.
    public static func < (lhs: ProtectionLevel, rhs: ProtectionLevel) -> Bool {
        lhs.strictness < rhs.strictness
    }

    var strictness: Int {
        switch self {
        case .standard: 0
        case .confirm: 1
        case .deviceBound: 2
        }
    }
}
