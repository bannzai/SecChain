---
paths:
  - "**/*.swift"
---

# Do not create intermediate representations

The structures that matter are the ones defined by a source of truth: the Keychain item attributes, the secret definition file format, and framework types. Do not create additional types that repackage or merge them.

- Use the source-of-truth type as it is. Do not repack it for display or processing convenience.
- Do not build a type that collects fields from several sources of truth.
- When a separate domain contract is really needed, derive it from the source type instead of declaring the same fields twice.

Reasons: repacked types add knowledge a reader has to learn, force readers to trace every field back to its origin, and must be updated whenever the source structure changes. An intermediate type occasionally reduces the size of a future change, but do not create one for a change that may never come.

## Bad

```swift
// Fields collected from the repository and the secret for display only.
struct RepositorySecretRow {
    let repositoryName: String
    let secretName: String
    let isSynchronized: Bool
}
```

## Good

```swift
func secretRow(repository: Repository, secret: SecretMetadata) -> some View
```

Related: single-use variables are covered by `coding-rules-no-intermediate-variables.md`. This rule is about duplicated structures.
