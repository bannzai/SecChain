import Foundation

/// Pure decisions of `secchain mask`: which secrets' values are looked for in a text, and what the
/// text becomes once they are hidden (documents/PROJECT.md, design decision 8). The text is handled
/// as bytes, so that a text that is not UTF-8, such as a tool's binary output, passes through
/// unchanged except where a value occurs, and so that a match is exact whatever the script.
public enum SecretMask {
    /// What every hidden stretch of the text becomes. The same for every value, so that the
    /// replacement tells nothing about the value it stands for, not even its length.
    public static let placeholder = Data("***".utf8)

    /// Values shorter than this many characters are not looked for. A short value, such as a port,
    /// `true` or a region name, occurs in unrelated text often enough that replacing it would break
    /// the prompts and tool results the model reads, while API keys and tokens are far longer.
    /// Eight is the bound the issue that introduced `mask` settled on
    /// (https://github.com/bannzai/SecChain/issues/70).
    public static let minimumValueLength = 8

    /// The secrets whose values `mask` looks for, out of `storedSecrets`, the effective secrets of
    /// `passedScopes` in every environment. Without an environment that is all of them: unlike
    /// `run`, `mask` does not refuse to start where a scope has environments, because hiding more
    /// than one environment's values is the safe side. With one, it is what `run --env` is offered
    /// (`RunPlan.offeredSecrets`).
    public static func maskedSecrets(
        storedSecrets: [StoredSecret],
        passedScopes: [SecretScope],
        environment: SecretEnvironment?
    ) throws -> [StoredSecret] {
        try environment.map {
            try RunPlan.offeredSecrets(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: $0)
        } ?? storedSecrets.filter { passedScopes.contains($0.scope) }
    }

    /// `data` with every occurrence of every value that is long enough replaced by `placeholder`,
    /// and how many stretches were replaced. Occurrences that overlap, of one value or of several,
    /// are one stretch replaced once: replacing them one value after another would leave the part
    /// of a value that another one's replacement cut off in the text.
    public static func masked(data: Data, values: [SecretValue]) -> (data: Data, maskedStretchCount: Int) {
        let text = Data(data)
        let stretches = Set(values.map(\.exposedData))
            .filter(isLookedFor(valueData:))
            .flatMap { occurrences(valueData: $0, text: text) }
            .sorted { $0.lowerBound < $1.lowerBound }
            .reduce(into: [Range<Int>]()) { merged, occurrence in
                if let last = merged.last, occurrence.lowerBound < last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, occurrence.upperBound)
                } else {
                    merged.append(occurrence)
                }
            }
        var output = Data()
        var cursor = text.startIndex
        for stretch in stretches {
            output.append(text[cursor..<stretch.lowerBound])
            output.append(placeholder)
            cursor = stretch.upperBound
        }
        output.append(text[cursor...])
        return (output, stretches.count)
    }

    /// Whether a value is looked for at all: at least `minimumValueLength` characters, and not only
    /// whitespace and newlines, which would match the indentation and line breaks of any text.
    static func isLookedFor(valueData: Data) -> Bool {
        let valueText = String(decoding: valueData, as: UTF8.self)
        return valueText.count >= minimumValueLength && !valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Every place `valueData` occurs in `text`, overlapping ones included, so that a value that
    /// repeats inside itself is hidden wherever any occurrence reaches.
    static func occurrences(valueData: Data, text: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: valueData, in: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = range.lowerBound + 1
        }
        return ranges
    }
}
