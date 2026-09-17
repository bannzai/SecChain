---
paths:
  - "**/*.swift"
---

# Write doc comments on definitions

- Every type definition (`class`, `struct`, `enum`, `protocol`) and every property gets a doc comment that says what it represents.
- Every function gets a doc comment.

## Bad

```swift
struct RepositoryIdentity {
    let value: String
}

func resolveRepositoryIdentity(directory: URL) throws -> RepositoryIdentity
```

## Good

```swift
/// Identifies a repository independently of where it is checked out, so that the same
/// repository maps to the same Keychain items on every Mac.
struct RepositoryIdentity {
    /// Normalized identifier used as part of the Keychain item's service attribute.
    let value: String
}

/// Resolves the identity from the directory's Git metadata. Throws when the directory
/// cannot be mapped to a stable identity, because guessing would split or merge secrets.
func resolveRepositoryIdentity(directory: URL) throws -> RepositoryIdentity
```
