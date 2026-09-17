---
paths:
  - "**/*.swift"
---

# Argument labels name what is passed

- Do not use preposition-only labels such as `for:` / `with:` / `in:` / `at:`. They hide what the call site passes.
- Use a noun that names the value (`name:` / `repository:` / `directory:` / `index:`).
- Do not omit the first argument label with `_` without a reason. When omitting it (for example to mirror a standard API), state the reason in a comment.

## Bad

```swift
store.secret(for: name)
private func run(_ command: [String])
```

## Good

```swift
store.secret(name: name)
private func run(command: [String])
```
