import ArgumentParser
import Foundation
import SecChainCore

/// Reads a secret value without it ever appearing in the shell history, the process list, or on
/// screen: from a hidden prompt when a terminal is attached, otherwise from standard input (for
/// example `pbpaste | secchain set NAME`), or from an environment variable this process received
/// (`secchain set NAME --from-variable`).
enum SecretInput {
    /// Longest value accepted from the hidden prompt. Far above real credentials (long JSON
    /// service-account keys are a few kilobytes); larger values can be piped through standard
    /// input, which has no limit.
    static let promptBufferSize = 16_384

    static func read(secretName: SecretName) throws -> SecretValue {
        if isatty(STDIN_FILENO) == 1 {
            return try readFromHiddenPrompt(secretName: secretName)
        }
        return SecretValue(exposingData: withoutOneTrailingNewline(data: FileHandle.standardInput.readDataToEndOfFile()))
    }

    static func readFromHiddenPrompt(secretName: SecretName) throws -> SecretValue {
        var buffer = [CChar](repeating: 0, count: promptBufferSize)
        defer {
            // The buffer held the value; overwrite it before the memory is released.
            buffer.withUnsafeMutableBytes { bytes in
                _ = memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
            }
        }
        guard readpassphrase("Value for \(secretName.value) (input hidden): ", &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil else {
            throw ValidationError("The value could not be read from the terminal.")
        }
        return SecretValue(exposingData: Data(bytes: buffer, count: strlen(buffer)))
    }

    /// The value of `variableName` in `environment`, which is the environment of this process for
    /// `secchain set NAME --from-variable`: a value a shell or direnv already exported moves into the
    /// Keychain without passing through a prompt, a pipe, or the view of whoever typed the command.
    ///
    /// The error names the variable, never the value. `SetCommand.validate` has already refused a
    /// name that is not a variable name, which may be a value typed in its place.
    static func readFromVariable(variableName: String, environment: [String: String]) throws -> SecretValue {
        guard let value = environment[variableName], !value.isEmpty else {
            throw ValidationError("\(variableName) is not set in the environment of this command, or it is empty. Export it in the shell that runs secchain, or pipe the value in without --from-variable.")
        }
        return SecretValue(exposingString: value)
    }

    /// `echo value | secchain set NAME` and here-strings append one newline that is not part of
    /// the value. Only a single one is removed, so a value that really ends in newlines keeps
    /// the rest.
    static func withoutOneTrailingNewline(data: Data) -> Data {
        data.last == UInt8(ascii: "\n") ? data.dropLast() : data
    }
}
