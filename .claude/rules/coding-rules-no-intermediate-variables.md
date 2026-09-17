---
paths:
  - "**/*.swift"
---

# Do not use intermediate variables

- Do not define a variable whose value is referenced only once.
- Pass the expression directly as the argument or return value.

## Bad

```swift
let names = definition.secretNames
return names
```

## Good

```swift
return definition.secretNames
```
