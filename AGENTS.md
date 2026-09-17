# AGENTS.md

## Language

- Code comments and everything that lives in the repository (README, `documents/`, `docs/`, rules, skills) are written in English. SecChain is an open-source project (MIT).
- Conversation with the maintainer, issue bodies, pull request bodies, and GitHub comments are written in Japanese.

## Requirements and design decisions

`documents/PROJECT.md` is the source of truth for scope, non-goals, security invariants, and the fixed design decisions (data protection keychain, command-line tool embedded in the app bundle, Developer ID distribution, app-layer user authentication). Read it before changing Keychain access, code signing, entitlements, or the command-line interface.

## Verification

Run these after every change, save the full output under `./tmp/`, and inspect the whole log with `grep -i -e warning -e error` rather than a truncated tail.

| Command | Purpose |
| --- | --- |
| `make build-macos` | Build the macOS app together with the embedded command-line tool (`-derivedDataPath tmp/DerivedData`) |
| `make build-ios` | Build the iOS app for the generic iOS Simulator destination |
| `make ios` | Build, install, and launch the iOS app on the project's simulator (started through `sim-boot`) |
| `make test` | Unit tests. They use an in-memory Keychain double and need no signing identity, so they also run in CI |
| `make test-integration` | Tests against the real data protection keychain. Requires a build signed with the team's identity; not available in CI for pull requests from forks |
| `make macos` | Install the Release build to `/Applications/SecChain.app` |
| `make cli` | Symlink the embedded tool from the installed app into `~/.local/bin/secchain` |

An unsigned `swift build` product cannot read SecChain's Keychain items (`documents/PROJECT.md`, design decision 2). Verify command-line behavior that touches the Keychain through `make macos` and `make cli`, not through `swift run`.

Follow `.claude/rules/secret-handling.md` during verification: use fake values and never echo a secret value into a log, an issue, or a pull request.

## Xcode project

- `SecChain.xcodeproj` is the only source of truth for the project structure. Change it through the Xcode GUI or by editing `project.pbxproj` directly.
- Do not run `xcodegen generate` and do not keep a `project.yml` in the repository. The mechanical check is the `xcode-project-source` item of `~/.agents/skills/create-new-app/scripts/check-setup.sh`.
