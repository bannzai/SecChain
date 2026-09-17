---
paths:
  - "**/*.swift"
---

# Swift coding conventions

- Write `///` doc comments that explain design intent (why, and under which constraints). Do not describe what the code does.
- Separate components with side effects (Keychain, process spawning, file system, Git, UI state) from pure logic (an `enum` with `static func`, or value types). Pure logic is the unit-test target.
- One responsibility per file. Test files mirror the file they cover (`Xxx.swift` ⇔ `XxxTests.swift`).
- Custom `Error` types conform to `CustomStringConvertible`. Show error messages as they are; do not rewrite or strip them at the call site.
- Make functions idempotent. When a function cannot be idempotent, state the reason in a comment.
- Unit tests use Swift Testing.
- Do not write statement blocks (`if` / `guard` / `for` / `while` / `defer` / `Task`) on a single line; expand them over multiple lines. Single-expression computed properties and expression closures such as `items.map { $0.name }` are exempt.
