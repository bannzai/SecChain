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

/// Whether `note` can be a `SecretNote`: something other than whitespace, and no control character,
/// line separator (line breaks and tabs included), or bidirectional control, which would make a
/// terminal show the row of `secchain list --long` in another order than the characters it holds.
/// Other format characters stay allowed, because the zero width joiner is part of emoji sequences.
public func isValidSecretNote(note: String) -> Bool {
    !note.allSatisfy(\.isWhitespace)
        && !note.unicodeScalars.contains { scalar in
            [.control, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
                || scalar.properties.isBidiControl
        }
}
