/// Name of a secret. It doubles as the environment variable name handed to child processes, so
/// only names every shell accepts as a variable are valid.
public struct SecretName: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The validated name.
    public let value: String

    // Only names usable as environment variable names are accepted, so creation can fail.
    public init?(rawName: String) {
        guard isValidSecretName(name: rawName) else {
            return nil
        }
        self.value = rawName
    }

    public var description: String {
        value
    }

    public static func < (lhs: SecretName, rhs: SecretName) -> Bool {
        lhs.value < rhs.value
    }
}

/// POSIX environment variable names: letters, digits and underscores, not starting with a digit.
/// ASCII only, because non-ASCII names are not portable across shells and tools.
public func isValidSecretName(name: String) -> Bool {
    guard let first = name.unicodeScalars.first, first == "_" || isASCIILetter(scalar: first) else {
        return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
        scalar == "_" || isASCIILetter(scalar: scalar) || ("0"..."9").contains(scalar)
    }
}

func isASCIILetter(scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
}
