import ArgumentParser
import Foundation
import SecChainCore

/// `secchain match`: name the stored secrets whose values a text on standard input contains, so
/// that another app can warn about a pasted secret without being handed a value.
struct MatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "match",
        abstract: "Write the names of the stored secrets whose values standard input contains.",
        discussion: """
            Example: pbpaste | secchain match
            It is for other apps, such as PasteCheck, to learn that a text holds a secret of the \
            user's by name, without being given a value. Like 'mask', it lets someone who guessed a \
            value whole find out that it is stored; the answer holds no value, and no more of it \
            than its name and where it is stored.

            Every 'standard' secret on this Mac is looked for, in every repository and shared \
            scope, because a text does not say which repository its reader is working on. A secret \
            of another protection level is not looked for, because reading its value asks for \
            authentication. Values shorter than \(SecretMask.minimumValueLength) characters are not \
            looked for either, because they occur in unrelated text.

            Each match is one line on standard output: the name, and in parentheses where it is \
            stored. A text that holds no value writes nothing and exits 0. When the Keychain \
            cannot be read, standard error says why and the exit status is 1.
            """
    )

    func run() throws {
        // Read into memory and never into a file: the input may hold the very values being looked for.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let matchedLabels = SecretMatch.matchedLabels(
            data: input,
            valuesBySecret: try SecretStore.system.standardValuesBySecret(storedSecrets: try SecretStore.system.storedSecrets())
        )
        for matchedLabel in matchedLabels {
            FileHandle.standardOutput.write(Data((matchedLabel + "\n").utf8))
        }
    }
}
