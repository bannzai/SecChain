import ArgumentParser
import Foundation
import SecChainCore

/// `secchain mask`: copy standard input to standard output with the repository's secret values
/// replaced by `***`, so that a text on its way to an AI agent loses any value that got into it.
struct MaskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mask",
        abstract: "Copy standard input to standard output with this repository's secret values replaced by ***.",
        discussion: """
            Example: printf '%s' "$text" | secchain mask
            It looks for the values of the secrets 'secchain run' would pass to the repository: its \
            own and those of the shared scopes an '@allow' of ~/.secchain passes to it. Without \
            --env, a scope with environments gives the values of every environment.

            Only 'standard' secrets are looked for, because reading any other one asks for \
            authentication, and standard error names each secret that is left out. Values shorter \
            than \(SecretMask.minimumValueLength) characters are not looked for either, because \
            they occur in unrelated text.

            Nothing says whether the text held a value unless --count is given. In a directory \
            whose repository cannot be identified, the text is copied unchanged and standard error \
            says why.
            """
    )

    @Flag(name: .long, help: "Write the number of replaced stretches to standard error.")
    var count = false

    @OptionGroup
    var environmentOptions: EnvironmentOptions

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    /// Writes nothing to standard output on an error other than an unidentifiable repository, so
    /// that a caller never takes a partial text for the masked one.
    func run() throws {
        // Read into memory and never into a file: the input may hold the very values being hidden.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let environment = try environmentOptions.validatedEnvironment()
        let context: CommandContext
        do {
            context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
        } catch let error as RepositoryIdentityError {
            // Without a repository no `@allow` applies, so there is nothing to look for. The text
            // passes, because a caller such as an agent's hook must not break over it.
            FileHandle.standardOutput.write(input)
            writeStandardError(line: "\(error) Nothing was masked.")
            return
        }
        let passedScopes = context.userDefinition.passedScopes(repositoryIdentity: context.repositoryIdentity)
        let maskedSecrets = try SecretMask.maskedSecrets(
            storedSecrets: try passedScopes.flatMap { try SecretStore.system.storedSecrets(scope: $0) },
            passedScopes: passedScopes,
            environment: environment
        )
        for line in Set(maskedSecrets.filter { $0.protectionLevel != .standard }.map { "\($0.name.value) is \($0.protectionLevel.rawValue), so mask does not look for its value." }).sorted() {
            writeStandardError(line: line)
        }
        let masked = SecretMask.masked(data: input, values: try SecretStore.system.standardValues(storedSecrets: maskedSecrets))
        FileHandle.standardOutput.write(masked.data)
        if count {
            writeStandardError(line: "masked \(masked.maskedStretchCount)")
        }
    }

    /// One line on standard error, which is never where the text goes.
    func writeStandardError(line: String) {
        FileHandle.standardError.write(Data("secchain: \(line)\n".utf8))
    }
}
