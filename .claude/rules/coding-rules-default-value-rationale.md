---
paths:
  - "**/*.swift"
  - "**/*.sh"
---

# State the rationale for default values

- For any fixed value that decides default behavior (an `Optional` fallback, a default argument, a constant used as a default), write a comment explaining why that value was chosen.
- The rationale should be verifiable later: a source, a constraint, a measurement, or the intent of a specification.
- Do not repeat the value or behavior that the code already shows. Write "why this value", not "what this does" (see `coding-rules-single-source-info.md`).

## Bad

```swift
context.touchIDAuthenticationAllowableReuseDuration = 10
```

## Good

```swift
// Revealing several values in a row should not prompt for each one; 10 seconds covers
// consecutive clicks while staying far below the 5 minute maximum the system allows.
context.touchIDAuthenticationAllowableReuseDuration = 10
```
