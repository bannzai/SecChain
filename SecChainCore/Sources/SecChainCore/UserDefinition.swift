import Foundation

/// What the user's definition file (`~/.secchain`) declares: the shared scopes, the repositories
/// each of them is passed to, and the identifiers of forks and of directories without a Git remote
/// (documents/PROJECT.md, "The user's definition file").
///
/// It lives outside every repository on purpose: a repository's own files cannot widen what
/// `secchain run` passes (design decision 6), so everything that does is here. Like a repository's
/// `.secchain`, it holds names and identifiers only, never a value.
///
/// File format, one entry per line. The names and `@allow` lines before the first `@scope` belong
/// to the user scope, and each `@scope` line starts a custom scope that lasts until the next one.
/// `@alias` and `@path` say which repository a directory is, which belongs to no scope, so they
/// apply wherever they are written:
///
///     # user scope
///     OPENAI_API_KEY
///     @allow github.com/bannzai/*
///
///     @scope youtube
///     YOUTUBE_API_KEY
///     @allow github.com/bannzai/youtuber
///
///     @alias github.com/bannzai/some-fork github.com/upstream/some-repo
///     @path /Users/bannzai/notes local/notes
public struct UserDefinition: Equatable, Sendable {
    /// The lines before the first `@scope`.
    public let userScope: ScopeDefinition
    /// One entry per `@scope`, in file order, which is also their order of precedence in `run`.
    public let customScopes: [ScopeDefinition]
    /// `@alias <fork> <upstream>`, keyed by the fork's identifier in lowercase: the fork is treated
    /// as its upstream, so that both get the upstream's secrets.
    public let upstreamRepositoryIdentities: [String: RepositoryIdentity]
    /// `@path <directory> <identifier>`, keyed by the directory as written: the directory and
    /// everything below it is that repository.
    public let pathRepositoryIdentities: [String: RepositoryIdentity]

    /// The scopes `run` passes to a repository, in order of precedence: the repository's own scope,
    /// then every custom scope that allows it, in file order, then the user scope when it allows it.
    /// A repository's own secret always wins over a shared one of the same name, and the user
    /// scope, the most general one, comes last.
    public func passedScopes(repositoryIdentity: RepositoryIdentity) -> [SecretScope] {
        [.repository(repositoryIdentity)]
            + (customScopes + [userScope])
                .filter { $0.isAllowed(repositoryIdentity: repositoryIdentity) }
                .map { .shared($0.scope) }
    }

    /// The definition of a shared scope. The user scope always has one; a custom scope has one only
    /// when a `@scope` line names it.
    public func scopeDefinition(scope: SharedScope) -> ScopeDefinition? {
        ([userScope] + customScopes).first { $0.scope == scope }
    }

    /// `repositoryIdentity` after `@alias`: a fork becomes its upstream. One step only, so that
    /// aliases can never form a loop.
    public func aliasedRepositoryIdentity(repositoryIdentity: RepositoryIdentity) -> RepositoryIdentity {
        upstreamRepositoryIdentities[repositoryIdentity.value.lowercased()] ?? repositoryIdentity
    }

    /// The `@path` that contains `directory`: the directory it names and its identifier, the most
    /// specific one when several contain `directory`. Paths are compared component by component
    /// after resolving symbolic links, so that `/Users/me/notes` does not contain
    /// `/Users/me/notes-old`, and a path through a link names the directory it leads to.
    public func pathRepository(directory: URL) -> (directory: URL, repositoryIdentity: RepositoryIdentity)? {
        let directoryComponents = directory.resolvingSymlinksInPath().pathComponents
        return pathRepositoryIdentities
            .map { (writtenPath: $0.key, directory: URL(fileURLWithPath: $0.key, isDirectory: true).resolvingSymlinksInPath(), repositoryIdentity: $0.value) }
            .filter { directoryComponents.starts(with: $0.directory.pathComponents) }
            // Two written paths can lead to the same directory. The order of their text decides
            // between them, so that the answer does not depend on the order of a dictionary.
            .max { ($0.directory.pathComponents.count, $0.writtenPath) < ($1.directory.pathComponents.count, $1.writtenPath) }
            .map { (directory: $0.directory, repositoryIdentity: $0.repositoryIdentity) }
    }
}

/// One shared scope as `~/.secchain` defines it.
public struct ScopeDefinition: Equatable, Sendable {
    /// The scope the section defines.
    public let scope: SharedScope
    /// Names the scope is meant to hold, in file order, without duplicates. They do not limit what
    /// `run` passes; `list --long --scope` reports the ones that have no value.
    public let secretNames: [SecretName]
    /// `@allow` patterns in file order, without duplicates: the repositories the scope is passed to.
    /// A scope without one is passed to no repository.
    public let allowPatterns: [String]

    /// Whether `run` passes the scope to the repository.
    public func isAllowed(repositoryIdentity: RepositoryIdentity) -> Bool {
        allowPatterns.contains { repositoryPatternMatches(pattern: $0, repositoryIdentity: repositoryIdentity) }
    }
}

/// Whether an `@allow` pattern names a repository: the pattern is its identifier, or the pattern
/// ends in `*` and the rest of it starts the identifier. `github.com/owner/*` therefore names every
/// repository of `owner` and none of `owner-other`. Letter case is ignored, because the identifier
/// of a Git remote is folded to lowercase while the pattern may be spelled the way the hosting
/// service shows the name.
public func repositoryPatternMatches(pattern: String, repositoryIdentity: RepositoryIdentity) -> Bool {
    let lowercasedPattern = pattern.lowercased()
    guard lowercasedPattern.hasSuffix("*") else {
        return repositoryIdentity.value.lowercased() == lowercasedPattern
    }
    return repositoryIdentity.value.lowercased().hasPrefix(String(lowercasedPattern.dropLast()))
}

/// An `@allow` pattern: a whole identifier, or the start of one followed by a single `*`. A `*`
/// anywhere else would read as a glob, which the comparison does not implement.
public func isValidRepositoryPattern(pattern: String) -> Bool {
    !pattern.isEmpty && !pattern.dropLast().contains("*") && !pattern.contains(where: \.isWhitespace)
}

/// Why `~/.secchain` was rejected. Messages never echo the rest of an offending line, for the same
/// reason as `SecretDefinitionError`: the most likely offending content is a secret value.
public enum UserDefinitionError: Error, Equatable, CustomStringConvertible {
    /// The line contains `=`, which suggests a value. Values belong in the Keychain only.
    case valueNotAllowed(lineNumber: Int)
    /// The line is neither a comment, a directive, nor a valid secret name.
    case invalidSecretName(lineNumber: Int)
    /// `@scope` names no valid custom scope: a malformed name, or `user` / `repository`, which
    /// name the built-in scopes.
    case invalidScopeName(lineNumber: Int)
    /// `@allow` has no pattern, several, or a `*` that is not the last character.
    case invalidAllowPattern(lineNumber: Int)
    /// An unknown directive, or `@scope` / `@alias` / `@path` with the wrong arguments.
    case invalidDirective(lineNumber: Int)
    /// A second `@scope` for one scope, or a second `@alias` / `@path` for one fork or directory.
    /// Which of the two lines counts would be a guess, and an edit would not know which to change.
    case duplicateDeclaration(lineNumber: Int)

    /// The message in English, as the command-line tool prints it: no SecChain binary has
    /// translations in `Bundle.main`.
    public var description: String {
        message(bundle: .main)
    }

    /// The message translated by the String Catalog in `bundle`, for the macOS app, which reads
    /// `~/.secchain` when a folder is chosen. English where the catalog has no translation.
    public func message(bundle: Bundle) -> String {
        switch self {
        case .valueNotAllowed(let lineNumber):
            String(localized: "~/.secchain line \(lineNumber): contains '='. The file lists secret names only; store the value with 'secchain set <NAME> --scope <scope>'.", bundle: bundle)
        case .invalidSecretName(let lineNumber):
            String(localized: "~/.secchain line \(lineNumber): not a valid secret name. Use letters, digits and underscores, not starting with a digit.", bundle: bundle)
        case .invalidScopeName(let lineNumber):
            String(localized: "~/.secchain line \(lineNumber): not a custom scope name. Use lowercase letters, digits and hyphens, starting with a letter or a digit; 'user' and 'repository' are built in.", bundle: bundle)
        case .invalidAllowPattern(let lineNumber):
            String(localized: "~/.secchain line \(lineNumber): '@allow' takes one pattern, a repository identifier or the start of one followed by '*'.", bundle: bundle)
        case .invalidDirective(let lineNumber):
            String(localized: "~/.secchain line \(lineNumber): unknown or incomplete directive. The directives are '@scope <name>', '@allow <pattern>', '@alias <fork> <upstream>' and '@path <absolute directory> <identifier>'.", bundle: bundle)
        case .duplicateDeclaration(let lineNumber):
            String(localized: "~/.secchain line \(lineNumber): repeats a scope, an '@alias' fork or an '@path' directory of an earlier line.", bundle: bundle)
        }
    }
}

/// Pure text operations on `~/.secchain`. Edits work on the text instead of re-serializing a parsed
/// model, so that comments and ordering written by the user survive `set`, `delete`, and
/// `scope allow` / `scope deny`, as they do in a repository's `.secchain`.
public enum UserDefinitionText {
    /// File name of the user's definition file, placed in the home directory. The same name as a
    /// repository's definition file, because both list secret names in the same line format.
    public static let fileName = ".secchain"

    static let scopeDirective = "@scope"
    static let allowDirective = "@allow"
    static let aliasDirective = "@alias"
    static let pathDirective = "@path"

    static let headerComment = """
        # SecChain: secrets shared between repositories, and the repositories each scope is passed to.
        # Names only. Never put a value in this file; store it with `secchain set <NAME> --scope <scope>`.
        """

    public static func parse(text: String) throws -> UserDefinition {
        var sections: [(scope: SharedScope, secretNames: [SecretName], allowPatterns: [String])] = [(.user, [], [])]
        var upstreamRepositoryIdentities: [String: RepositoryIdentity] = [:]
        var pathRepositoryIdentities: [String: RepositoryIdentity] = [:]
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard !line.contains("=") else {
                throw UserDefinitionError.valueNotAllowed(lineNumber: lineNumber)
            }
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            switch words[0] {
            case scopeDirective:
                guard words.count == 2 else {
                    throw UserDefinitionError.invalidDirective(lineNumber: lineNumber)
                }
                guard let customScopeName = CustomScopeName(rawName: words[1]) else {
                    throw UserDefinitionError.invalidScopeName(lineNumber: lineNumber)
                }
                guard !sections.contains(where: { $0.scope == .custom(customScopeName) }) else {
                    throw UserDefinitionError.duplicateDeclaration(lineNumber: lineNumber)
                }
                sections.append((.custom(customScopeName), [], []))
            case allowDirective:
                guard words.count == 2, isValidRepositoryPattern(pattern: words[1]) else {
                    throw UserDefinitionError.invalidAllowPattern(lineNumber: lineNumber)
                }
                if !sections[sections.count - 1].allowPatterns.contains(words[1]) {
                    sections[sections.count - 1].allowPatterns.append(words[1])
                }
            case aliasDirective:
                guard words.count == 3 else {
                    throw UserDefinitionError.invalidDirective(lineNumber: lineNumber)
                }
                guard upstreamRepositoryIdentities[words[1].lowercased()] == nil else {
                    throw UserDefinitionError.duplicateDeclaration(lineNumber: lineNumber)
                }
                upstreamRepositoryIdentities[words[1].lowercased()] = RepositoryIdentity(value: words[2])
            case pathDirective:
                // The identifier is the last word and the directory is everything before it, so
                // that a directory whose name contains a space needs no quoting.
                let arguments = line.dropFirst(pathDirective.count).trimmingCharacters(in: .whitespaces)
                guard let lastSeparator = arguments.lastIndex(where: \.isWhitespace) else {
                    throw UserDefinitionError.invalidDirective(lineNumber: lineNumber)
                }
                let path = arguments[..<lastSeparator].trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/") else {
                    throw UserDefinitionError.invalidDirective(lineNumber: lineNumber)
                }
                guard pathRepositoryIdentities[path] == nil else {
                    throw UserDefinitionError.duplicateDeclaration(lineNumber: lineNumber)
                }
                pathRepositoryIdentities[path] = RepositoryIdentity(value: String(arguments[arguments.index(after: lastSeparator)...]))
            case let word where word.hasPrefix("@"):
                throw UserDefinitionError.invalidDirective(lineNumber: lineNumber)
            default:
                guard words.count == 1, let secretName = SecretName(rawName: line) else {
                    throw UserDefinitionError.invalidSecretName(lineNumber: lineNumber)
                }
                if !sections[sections.count - 1].secretNames.contains(secretName) {
                    sections[sections.count - 1].secretNames.append(secretName)
                }
            }
        }
        let scopeDefinitions = sections.map { ScopeDefinition(scope: $0.scope, secretNames: $0.secretNames, allowPatterns: $0.allowPatterns) }
        return UserDefinition(
            userScope: scopeDefinitions[0],
            customScopes: Array(scopeDefinitions.dropFirst()),
            upstreamRepositoryIdentities: upstreamRepositoryIdentities,
            pathRepositoryIdentities: pathRepositoryIdentities
        )
    }

    // Every edit parses the text first, so that nothing is changed in a file that already says
    // something this version cannot read.

    /// Text with `secretName` declared in the section of `scope`. `text == nil` means the file does
    /// not exist yet. A custom scope without a section gets one, so that `secchain set --scope`
    /// creates the scope. Adding a name the section already declares returns the text unchanged
    /// (idempotent).
    public static func adding(secretName: SecretName, scope: SharedScope, text: String?) throws -> String {
        if let text, try parse(text: text).scopeDefinition(scope: scope)?.secretNames.contains(secretName) == true {
            return text
        }
        return inserting(line: secretName.value, scope: scope, text: text)
    }

    /// Text without the declaration of `secretName` in the section of `scope`. The same name in
    /// another scope is another secret and stays. Removing a name that is not declared returns the
    /// text unchanged (idempotent).
    public static func removing(secretName: SecretName, scope: SharedScope, text: String) throws -> String {
        _ = try parse(text: text)
        return removing(scope: scope, text: text) { words in
            words == [secretName.value]
        }
    }

    /// Text with `@allow <pattern>` in the section of `scope`, creating the section of a custom
    /// scope and the file when needed. `allowPattern` is a valid pattern
    /// (`isValidRepositoryPattern`). Allowing a pattern the section already has returns the text
    /// unchanged (idempotent).
    public static func adding(allowPattern: String, scope: SharedScope, text: String?) throws -> String {
        if let text, try parse(text: text).scopeDefinition(scope: scope)?.allowPatterns.contains(allowPattern) == true {
            return text
        }
        return inserting(line: "\(allowDirective) \(allowPattern)", scope: scope, text: text)
    }

    /// Text without `@allow <pattern>` in the section of `scope`. Other patterns that still name the
    /// same repositories stay: the text only loses the line that was asked for. Removing a pattern
    /// the section does not have returns the text unchanged (idempotent).
    public static func removing(allowPattern: String, scope: SharedScope, text: String) throws -> String {
        _ = try parse(text: text)
        return removing(scope: scope, text: text) { words in
            words == [allowDirective, allowPattern]
        }
    }

    // MARK: - Sections

    /// Words of one line, as `parse` splits it.
    static func words(line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether a line belongs to the scope of its section: the `@scope` line, a name, or an
    /// `@allow`. Blank lines, comments, `@alias`, and `@path` do not.
    static func isScopeEntry(line: String) -> Bool {
        guard let firstWord = words(line: line).first, !firstWord.hasPrefix("#") else {
            return false
        }
        return firstWord != aliasDirective && firstWord != pathDirective
    }

    /// The indices of the lines of `scope`'s section: the lines before the first `@scope` for the
    /// user scope, the `@scope` line and the lines up to the next one for a custom scope. `nil` when
    /// no `@scope` line names the custom scope.
    static func sectionRange(scope: SharedScope, lines: [String]) -> Range<Int>? {
        let scopeLineIndices = lines.indices.filter { words(line: lines[$0]).first == scopeDirective }
        guard case .custom(let customScopeName) = scope else {
            return 0..<(scopeLineIndices.first ?? lines.count)
        }
        guard let start = scopeLineIndices.first(where: { words(line: lines[$0]) == [scopeDirective, customScopeName.value] }) else {
            return nil
        }
        return start..<(scopeLineIndices.first { $0 > start } ?? lines.count)
    }

    /// `text` with `line` at the end of what the section of `scope` declares: after its last scope
    /// entry, or after the comments that open the file when the user scope has none yet, so that a
    /// comment written above an `@alias` or the first `@scope` stays next to it. A custom scope
    /// without a section gets a new one at the end of the text.
    static func inserting(line: String, scope: SharedScope, text: String?) -> String {
        let baseText = text ?? headerComment + "\n"
        var lines = baseText.components(separatedBy: "\n")
        guard let section = sectionRange(scope: scope, lines: lines) else {
            let separatedText = baseText.isEmpty || baseText.hasSuffix("\n") ? baseText : baseText + "\n"
            // A blank line keeps the new section apart from what comes before it.
            return separatedText + (separatedText.isEmpty || separatedText.hasSuffix("\n\n") ? "" : "\n")
                + "\(scopeDirective) \(scope.name)\n\(line)\n"
        }
        let insertionIndex = section.last(where: { isScopeEntry(line: lines[$0]) }).map { $0 + 1 }
            ?? section.lowerBound + lines[section].prefix(while: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }).count
        lines.insert(line, at: insertionIndex)
        let editedText = lines.joined(separator: "\n")
        return editedText.hasSuffix("\n") ? editedText : editedText + "\n"
    }

    /// `text` without the lines of `scope`'s section whose words `isRemoved` picks.
    static func removing(scope: SharedScope, text: String, isRemoved: ([String]) -> Bool) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let section = sectionRange(scope: scope, lines: lines) else {
            return text
        }
        return lines.indices
            .filter { !section.contains($0) || !isRemoved(words(line: lines[$0])) }
            .map { lines[$0] }
            .joined(separator: "\n")
    }
}

#if os(macOS)
/// Reads and writes `~/.secchain`. Only the Mac has one: the iOS app never runs a command, so it
/// never needs to know which scopes a repository gets.
public enum UserDefinitionFile {
    /// The home directory `~/.secchain` is in: `$HOME`, the way a shell expands `~` and git finds
    /// `~/.gitconfig`, so that the file this tool reads is the one the user edits in a terminal. The
    /// account's home directory when `HOME` is not set. Foundation's own home directory APIs ignore
    /// `HOME` on macOS (measured with `HOME=/tmp/…`), which is why the variable is read here.
    public static var homeDirectory: URL {
        ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public static func url(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(UserDefinitionText.fileName, isDirectory: false)
    }

    /// `nil` when the file does not exist, which is a valid state: no shared scope is passed to any
    /// repository, and the first `secchain set --scope` or `secchain scope allow` creates it.
    public static func readText(homeDirectory: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url(homeDirectory: homeDirectory).path) else {
            return nil
        }
        return try String(contentsOf: url(homeDirectory: homeDirectory), encoding: .utf8)
    }

    /// Writes through a symbolic link instead of replacing it: `~/.secchain` is meant to be kept
    /// with the user's dotfiles, which are often links into a dotfiles repository, and an atomic
    /// write replaces the file at the path it is given. Writing the same text again leaves the same
    /// file (idempotent).
    public static func write(text: String, homeDirectory: URL) throws {
        try text.write(to: url(homeDirectory: homeDirectory).resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }
}
#endif
