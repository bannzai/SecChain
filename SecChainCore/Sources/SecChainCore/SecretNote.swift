/// The user's note about a secret, such as what the key is for ("the API key for video
/// generation"). It is not a secret: it is kept in the Keychain item's `kSecAttrComment`, which
/// Apple describes as the user-editable comment of the item, travels with the item through iCloud
/// Keychain, and is shown in every app and by `secchain list --long` (documents/PROJECT.md, design
/// decision 9).
public struct SecretNote: Hashable, Sendable, CustomStringConvertible {
    /// The validated note.
    public let value: String

    // A note is one line of `secchain list --long`, whose columns are separated by tabs, so a note
    // with a line break or a tab is refused instead of breaking the row. A note of whitespace alone
    // says nothing, and removing a note is a separate operation, so creation can fail.
    public init?(rawNote: String) {
        guard isValidSecretNote(note: rawNote) else {
            return nil
        }
        self.value = rawNote
    }

    public var description: String {
        value
    }
}

/// Whether `note` can be a `SecretNote`: something other than whitespace, and no control character
/// or line separator (line breaks and tabs included).
public func isValidSecretNote(note: String) -> Bool {
    !note.allSatisfy(\.isWhitespace)
        && !note.unicodeScalars.contains { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
}
