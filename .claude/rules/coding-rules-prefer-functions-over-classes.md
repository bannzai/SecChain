---
paths:
  - "**/*.swift"
---

# Prefer functions over classes

- If a function is enough, write a function. Do not introduce a `class`, `struct`, or `enum` just to hold it.
- Use a `class` only when it is unavoidable (inheritance is required, a framework demands it, shared mutable state with identity).
- `struct` / `enum` are fine for primitive purposes: `Codable` data, values passed to generic functions, namespaces for pure `static func` logic.

## Bad

```swift
final class SecretNameValidator {
    func isValid(name: String) -> Bool { ... }
}
```

## Good

```swift
func isValidSecretName(name: String) -> Bool { ... }
```
