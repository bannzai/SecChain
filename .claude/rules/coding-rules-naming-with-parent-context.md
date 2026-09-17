---
paths:
  - "**/*.swift"
---

# Keep the parent type's name in variable names

Name a variable so that the type it came from stays visible.

## Bad

```swift
// The `RepositoryIdentity` context is lost.
let value = repositoryIdentity.value
```

## Good

```swift
let repositoryIdentityValue = repositoryIdentity.value
```
