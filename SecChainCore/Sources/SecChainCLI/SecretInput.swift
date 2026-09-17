import ArgumentParser
import Foundation
import SecChainCore

/// Reads a secret value without it ever appearing in the shell history, the process list, or on
/// screen: from a hidden prompt when a terminal is attached, otherwise from standard input (for
/// example `pbpaste | secchain set NAME`).
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

    /// `echo value | secchain set NAME` and here-strings append one newline that is not part of
    /// the value. Only a single one is removed, so a value that really ends in newlines keeps
    /// the rest.
    static func withoutOneTrailingNewline(data: Data) -> Data {
        data.last == UInt8(ascii: "\n") ? data.dropLast() : data
    }
}
