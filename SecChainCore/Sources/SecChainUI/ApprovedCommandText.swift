import Foundation

/// The command of an approval request as one line, with the boundary between arguments visible.
///
/// The approval signature covers the arguments as a list (`RemoteApproval.contentDigest`), so what
/// the user reads has to say where one argument ends. Joining them with spaces does not: a process
/// running as the user can file `["deploy", "staging production"]`, which would read exactly like
/// the three words of `["deploy", "staging", "production"]` while a different command is signed.
///
/// An argument that could be misread is therefore quoted the way a shell writes it, which is the
/// form a developer already reads the arguments of a command in.
///
/// `nonisolated` because this is pure text: the module is built with `defaultIsolation(MainActor)`
/// for its views, and without this the tests would have to run on the main actor to call it.
nonisolated func approvedCommandText(commandArguments: [String]) -> String {
    commandArguments.map(approvedArgumentText(argument:)).joined(separator: " ")
}

/// One argument, quoted when reading it unquoted would not show where it starts and ends: when it
/// is empty, or when it contains anything but the characters a shell passes through untouched.
nonisolated func approvedArgumentText(argument: String) -> String {
    guard !argument.isEmpty, argument.allSatisfy(isUnquotedArgumentCharacter(character:)) else {
        return "'\(argument.replacingOccurrences(of: "'", with: #"'\''"#))'"
    }
    return argument
}

/// Whether a character needs no quoting. The set is the conservative one: letters, digits, and the
/// punctuation that appears in paths, flags, and version numbers. Everything else, including every
/// kind of space, is quoted rather than judged.
private nonisolated func isUnquotedArgumentCharacter(character: Character) -> Bool {
    character.isLetter && character.isASCII
        || character.isNumber && character.isASCII
        || "-_./:=@+,".contains(character)
}
