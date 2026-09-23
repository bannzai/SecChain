import ArgumentParser
import Foundation
import SecChainCore

/// `secchain scope`: which repositories a shared scope is passed to, as the `@allow` lines of
/// `~/.secchain` say.
struct ScopeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scope",
        abstract: "Choose the repositories a shared scope is passed to, in ~/.secchain.",
        discussion: """
            'secchain run' passes a shared scope, the user scope or a custom one, only to the \
            repositories that an '@allow' of that scope names. Nothing inside a repository can add \
            one. 'secchain list --scopes' shows every scope with its patterns.
            """,
        subcommands: [ScopeAllowCommand.self, ScopeDenyCommand.self]
    )
}

/// Arguments of `scope allow` and `scope deny`.
struct ScopePatternArguments: ParsableArguments {
    @Argument(help: "The scope: 'user' or a custom scope.")
    var scope: String

    @Argument(help: "A repository identifier, such as github.com/owner/repo, or the start of one followed by '*', such as 'github.com/owner/*'. Quote it so that the shell leaves the '*' alone.")
    var pattern: String

    /// The scope and the pattern after validation, so that a mistyped one is a usage error.
    func validated() throws -> (sharedScope: SharedScope, pattern: String) {
        guard isValidRepositoryPattern(pattern: pattern) else {
            throw ValidationError("'\(pattern)' is not a pattern. Give a repository identifier, or the start of one followed by a single '*' at the end, without spaces or '='.")
        }
        return (try validatedSharedScope(rawName: scope), pattern)
    }
}

/// `secchain scope allow <scope> <pattern>`: pass the scope to the repositories the pattern names.
struct ScopeAllowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow",
        abstract: "Pass a scope to the repositories a pattern names, by adding '@allow <pattern>' to that scope in ~/.secchain."
    )

    @OptionGroup
    var arguments: ScopePatternArguments

    func run() throws {
        let (sharedScope, pattern) = try arguments.validated()
        try editUserDefinition { text in
            try UserDefinitionText.adding(allowPattern: pattern, scope: sharedScope, text: text)
        }
        print("Scope \(sharedScope.name) is passed to \(pattern).")
    }
}

/// `secchain scope deny <scope> <pattern>`: stop passing the scope to the repositories the pattern
/// names.
struct ScopeDenyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deny",
        abstract: "Stop passing a scope to the repositories a pattern names, by removing '@allow <pattern>' from that scope in ~/.secchain.",
        discussion: "Only that line is removed. A repository another '@allow' of the scope still names keeps getting the scope, which the command reports."
    )

    @OptionGroup
    var arguments: ScopePatternArguments

    func run() throws {
        let (sharedScope, pattern) = try arguments.validated()
        guard let userDefinitionText = try readUserDefinition().text else {
            print("Scope \(sharedScope.name) is not passed to \(pattern).")
            return
        }
        let editedText = try UserDefinitionText.removing(allowPattern: pattern, scope: sharedScope, text: userDefinitionText)
        try UserDefinitionFile.write(text: editedText, homeDirectory: UserDefinitionFile.homeDirectory)
        // Another line of the scope may still name some of what the removed one named: the same
        // identifier spelled in another letter case, a wider wildcard, or a narrower pattern.
        let remainingPatterns = (try UserDefinitionText.parse(text: editedText).scopeDefinition(scope: sharedScope)?.allowPatterns ?? [])
            .filter { repositoryPatternsOverlap(pattern: $0, otherPattern: pattern) }
        guard remainingPatterns.isEmpty else {
            print("Removed '@allow \(pattern)' from scope \(sharedScope.name), but '@allow \(remainingPatterns.joined(separator: "', '@allow "))' still passes it to repositories that \(pattern) names.")
            return
        }
        print("Scope \(sharedScope.name) is not passed to \(pattern).")
    }
}
