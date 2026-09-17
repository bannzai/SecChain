---
paths:
  - "**/*.swift"
---

# Use the memberwise initializer

- Initialize a `struct` with its synthesized memberwise initializer.
- Do not hand-write an `init` that only takes the same arguments and assigns them.
- A `public init` for API exposed outside the module is fine, because the synthesized memberwise initializer is `internal`.
- When defining any other `init`, state in a comment why it is needed (validation, a value decided internally, a `private` initializer, and so on).

## Bad

```swift
struct SecretName {
    let value: String

    // Custom initializer without a stated reason.
    init?(_ raw: String) {
        guard !raw.isEmpty else {
            return nil
        }
        self.value = raw
    }
}
```

## Good

```swift
struct SecretName {
    let value: String

    // Only names usable as environment variable names are accepted, so creation can fail.
    init?(rawName: String) {
        guard isValidSecretName(name: rawName) else {
            return nil
        }
        self.value = rawName
    }
}
```
