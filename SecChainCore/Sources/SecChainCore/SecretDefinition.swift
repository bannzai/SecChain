import Foundation

/// What a repository's secret definition file (`.secchain`) declares: the names of the secrets
/// the repository needs, and optionally an explicit repository identifier.
///
/// There is deliberately no field that could hold a secret value, and the parser rejects lines
/// that look like `NAME=value`, so that a pasted `.env` file is refused instead of committed.
///
/// File format, one entry per line:
///
///     # comment
///     @repository my-notes
///     OPENAI_API_KEY
///     CLOUDFLARE_API_TOKEN
public struct SecretDefinition: Equatable, Sendable {
    /// Identifier declared with `@repository`, used instead of the Git remote.
    public let declaredRepositoryIdentifier: String?
    /// Declared secret names in file order, without duplicates.
    public let secretNames: [SecretName]
}

/// Why a definition file was rejected. Messages never echo the rest of an offending line, because
/// the most likely offending content is a secret value.
public enum SecretDefinitionError: Error, Equatable, CustomStringConvertible {
    /// The line contains `=`, which suggests a value. Values belong in the Keychain only.
    case valueNotAllowed(lineNumber: Int)
    /// The line is neither a comment, a directive, nor a valid secret name.
    case invalidSecretName(lineNumber: Int)
    /// `@repository` appears without an identifier, or an unknown `@` directive was used.
    case invalidDirective(lineNumber: Int)

    public var description: String {
        switch self {
        case .valueNotAllowed(let lineNumber):
            ".secchain line \(lineNumber): contains '='. The definition file lists secret names only; store the value with 'secchain set <NAME>'."
        case .invalidSecretName(let lineNumber):
            ".secchain line \(lineNumber): not a valid secret name. Use letters, digits and underscores, not starting with a digit."
        case .invalidDirective(let lineNumber):
            ".secchain line \(lineNumber): unknown or incomplete directive. The only directive is '@repository <identifier>'."
        }
    }
}

/// Pure text operations on the definition file. Edits work on the text instead of re-serializing
/// a parsed model, so that comments and ordering written by the user survive `set` and `delete`.
public enum SecretDefinitionText {
    /// File name of the definition file, placed at the root of the working tree.
    public static let fileName = ".secchain"

    static let repositoryDirective = "@repository"

    static let headerComment = """
        # SecChain secret definition: the names of the secrets this repository needs.
        # Names only. Never put a value in this file; store it with `secchain set <NAME>`.
        """

    public static func parse(text: String) throws -> SecretDefinition {
        var declaredRepositoryIdentifier: String?
        var secretNames: [SecretName] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("@") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 2, parts[0] == repositoryDirective else {
                    throw SecretDefinitionError.invalidDirective(lineNumber: index + 1)
                }
                declaredRepositoryIdentifier = String(parts[1])
                continue
            }
            guard !line.contains("=") else {
                throw SecretDefinitionError.valueNotAllowed(lineNumber: index + 1)
            }
            guard let secretName = SecretName(rawName: line) else {
                throw SecretDefinitionError.invalidSecretName(lineNumber: index + 1)
            }
            if !secretNames.contains(secretName) {
                secretNames.append(secretName)
            }
        }
        return SecretDefinition(declaredRepositoryIdentifier: declaredRepositoryIdentifier, secretNames: secretNames)
    }

    /// Text with `secretName` declared. `text == nil` means the file does not exist yet.
    /// Adding a name that is already declared returns the text unchanged (idempotent).
    public static func adding(secretName: SecretName, text: String?) throws -> String {
        guard let text else {
            return headerComment + "\n" + secretName.value + "\n"
        }
        guard try !parse(text: text).secretNames.contains(secretName) else {
            return text
        }
        return (text.hasSuffix("\n") || text.isEmpty ? text : text + "\n") + secretName.value + "\n"
    }

    /// Text without `secretName`. Removing a name that is not declared returns the text unchanged
    /// (idempotent).
    public static func removing(secretName: SecretName, text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != secretName.value }
            .joined(separator: "\n")
    }

    /// Names that the definition declares but the Keychain does not hold. `run` refuses to start
    /// while this is not empty, so that a command never runs with a silently missing variable.
    public static func missingSecretNames(definition: SecretDefinition, storedSecretNames: Set<SecretName>) -> [SecretName] {
        definition.secretNames.filter { !storedSecretNames.contains($0) }
    }
}

/// Reads and writes the definition file of one working tree.
public enum SecretDefinitionFile {
    public static func url(workingTreeRoot: URL) -> URL {
        workingTreeRoot.appendingPathComponent(SecretDefinitionText.fileName, isDirectory: false)
    }

    /// `nil` when the repository has no definition file, which is a valid state: the file is
    /// optional and gets created by the first `secchain set`.
    public static func readText(workingTreeRoot: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url(workingTreeRoot: workingTreeRoot).path) else {
            return nil
        }
        return try String(contentsOf: url(workingTreeRoot: workingTreeRoot), encoding: .utf8)
    }

    /// Writing the same text again leaves the same file (idempotent).
    public static func write(text: String, workingTreeRoot: URL) throws {
        try text.write(to: url(workingTreeRoot: workingTreeRoot), atomically: true, encoding: .utf8)
    }
}
