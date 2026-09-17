---
paths:
  - ".github/workflows/*.{yml,yaml}"
  - "**/.github/workflows/*.{yml,yaml}"
---

# Pin GitHub Actions to a commit SHA

Workflow `uses:` entries reference a full-length commit SHA plus a version comment, not a tag such as `@v4`. Tags are mutable: if an action's repository is compromised, the tag can be moved to malicious code. This is GitHub's recommended hardening, and it matters more here because the release workflow handles signing credentials.

- Form: `uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1`
- Finding the SHA: list tags with `git ls-remote https://github.com/<owner>/<repo>.git 'refs/tags/v*'`, then check the object type with `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.type + " " + .object.sha'`. For `commit` (lightweight tag) use the SHA as is. For `tag` (annotated tag) dereference once with `gh api repos/<owner>/<repo>/git/tags/<tag SHA>`.
- The version in the comment is the real version the major tag points to at that moment, which can lag behind the latest release. Pin to the SHA the major tag points to so behavior does not change.
- For sub-directory actions (`actions/cache/restore`), take the SHA from the parent repository's tags.
- After a change, run the workflow once to confirm it works.

Reference: https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-third-party-actions
