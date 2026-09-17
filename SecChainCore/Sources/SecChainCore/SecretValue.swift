import Foundation

/// A secret value in memory. The type exists so that a value cannot reach a log, an error
/// message, or a debugger dump by accident: every textual representation is redacted, and the
/// bytes are only reachable through members whose names say that they expose the secret.
public struct SecretValue: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let data: Data

    public init(exposingData data: Data) {
        self.data = data
    }

    public init(exposingString string: String) {
        self.data = Data(string.utf8)
    }

    /// The raw bytes, for writing to the Keychain.
    public var exposedData: Data {
        data
    }

    /// The value as text, for a child process's environment or an explicit reveal in an app.
    /// `nil` when the bytes are not UTF-8 (values are always stored from text, so this only
    /// happens for items written by something else).
    public var exposedString: String? {
        String(data: data, encoding: .utf8)
    }

    public var isEmpty: Bool {
        data.isEmpty
    }

    public var description: String {
        "<redacted secret value>"
    }

    public var debugDescription: String {
        description
    }

    /// `dump` and the debugger's default summaries go through the mirror; an empty one keeps the
    /// bytes out of them.
    public var customMirror: Mirror {
        Mirror(self, children: [])
    }
}
