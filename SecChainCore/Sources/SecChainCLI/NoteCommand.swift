import ArgumentParser
import Foundation
import SecChainCore

/// `secchain note <NAME> <NOTE>`: write or remove the note of a stored secret.
struct NoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Write or remove the note of a stored secret, such as what it is for. No authentication is asked for: a note is not a secret.",
        discussion: """
            The note is kept with the secret in the Keychain, synchronizes with it, and is shown by \
            every app and by 'secchain list --long'. Never put a value in it.

            With --env, the note of that environment's secret: the secret of each environment has a \
            note of its own.
            """
    )

    @Argument(help: "Secret name.")
    var name: String

    @Argument(help: "The note: one line without tabs. Omit it with --remove.")
    var note: String?

    @Flag(help: "Remove the note instead of writing one.")
    var remove = false

    @OptionGroup
    var scopeOptions: ScopeOptions

    @OptionGroup
    var environmentOptions: EnvironmentOptions

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    /// Exactly one of a note and `--remove`, and a note that `SecretNote` accepts.
    func validate() throws {
        guard (note != nil) != remove else {
            throw ValidationError("Give the note, or --remove to remove it.")
        }
        if let note, !isValidSecretNote(note: note) {
            throw ValidationError(invalidNoteMessage)
        }
    }

    func run() throws {
        let secretName = try validatedSecretName(rawName: name)
        let environment = try environmentOptions.validatedEnvironment()
        let scope: SecretScope = try scopeOptions.sharedScope(repositoryOption: repositoryOptions.repository).map(SecretScope.shared)
            ?? .repository(try CommandContext.resolve(repositoryOption: repositoryOptions.repository).repositoryIdentity)
        let storedSecret = try SecretStore.system.setNote(
            name: secretName,
            scope: scope,
            environment: environment,
            note: note.flatMap(SecretNote.init(rawNote:))
        )
        writeToStandardOutput(
            line: storedSecret.note == nil
                ? "Removed the note of \(secretName.value) in \(storedSecret.locationDescription)."
                : "Wrote the note of \(secretName.value) in \(storedSecret.locationDescription)."
        )
    }
}

/// The usage error for a note that `SecretNote` refuses. The note is not repeated: it is shown by
/// `secchain list --long`, whose rows it would break.
let invalidNoteMessage = "A note is one line of text: no line breaks, tabs, other control characters, or bidirectional controls, and not whitespace alone. Use 'secchain note NAME --remove' to remove one."
