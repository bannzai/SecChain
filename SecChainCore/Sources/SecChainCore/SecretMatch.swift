import Foundation

/// Pure decisions of `secchain match`: which stored secrets a text holds the value of. It answers
/// with names only, so that another app can learn that a secret of the user's is in a text without
/// ever being handed a value (documents/PROJECT.md, design decision 8). The text is handled as
/// bytes, as `SecretMask` does, so that a text that is not UTF-8 is searched like any other.
public enum SecretMatch {
    /// The line `match` writes for a matched secret: the name, and where it is stored
    /// (`StoredSecret.locationDescription`), so that the same name in several scopes or
    /// environments is told apart. Carries nothing of the value, not even its length.
    public static func label(storedSecret: StoredSecret) -> String {
        "\(storedSecret.name.value) (\(storedSecret.locationDescription))"
    }

    /// The labels of the `standard` secrets among `valuesBySecret` whose value occurs in `data`,
    /// sorted. Values that `SecretMask.isLookedFor(valueData:)` rejects (shorter than
    /// `SecretMask.minimumValueLength`, or whitespace only) are not looked for, for the reason
    /// `mask` has: they occur in unrelated text, so a match would name a secret that is not there.
    /// Secrets of another level are skipped even when a value is passed for them, because reading
    /// their value asks for authentication and `match` never does.
    public static func matchedLabels(data: Data, valuesBySecret: [StoredSecret: SecretValue]) -> [String] {
        Set(
            valuesBySecret
                .filter { storedSecret, value in
                    storedSecret.protectionLevel == .standard
                        && SecretMask.isLookedFor(valueData: value.exposedData)
                        && data.range(of: value.exposedData) != nil
                }
                .keys
                .map(label(storedSecret:))
        ).sorted()
    }
}
