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
| `make check-localization` | Every text of the apps is in the String Catalog (`SecChainCore/Sources/SecChainUI/Resources/Localizable.xcstrings`) with a Japanese translation and is looked up in the right bundle. Also runs in CI |
| `make test-hooks` | The Claude Code hook shipped with the agent skill (`skills/secchain/hooks/`), against the calls it has to stop and the ones it has to let through. Also runs in CI |
| `make test-integration` | Tests against the real data protection keychain. Requires a build signed with the team's identity; not available in CI for pull requests from forks |
| `make macos` | Install the Release build to `/Applications/SecChain.app` |
| `make cli` | Symlink the embedded tool from the installed app into `~/.local/bin/secchain` |
| `make screenshots` | The App Store screenshots of the iOS app, in every language and for both device classes, into `fastlane/screenshots` (`scripts/generate_screenshots/README.md`). Runs simulators, so not in CI |

An unsigned `swift build` product cannot read SecChain's Keychain items (`documents/PROJECT.md`, design decision 2). Verify command-line behavior that touches the Keychain through `make macos` and `make cli`, not through `swift run`.

Follow `.claude/rules/secret-handling.md` during verification: use fake values and never echo a secret value into a log, an issue, or a pull request.

### Checking screens

- Verify screens and behavior through simtunnel by default: the app runs on a GitHub Actions macOS runner (in an iOS Simulator, or on the runner's desktop for the macOS app) that joins the maintainer's tailnet. A local simulator or a local launch of the macOS app is not the default, and a local-only step written in an issue (`make ios`, launch arguments) is not by itself a reason to use one.
  - Push the branch first. A session builds the pushed tip of `--ref`; without `--ref` it builds `main`.
  - iOS: `SIMTUNNEL_REPO=bannzai/SecChain ~/ghq/github.com/bannzai/simtunnel/local/simtunnel up <session> --ref <branch> --wait` starts `.github/workflows/simulator-session.yml`. Operate and capture with `scripts/ios-wda.sh --session <session>` of the `/ios-simulator` skill.
  - macOS: the same command with `SIMTUNNEL_WORKFLOW=macos-app-session.yml` starts `.github/workflows/macos-app-session.yml`. Operate and capture with `scripts/macos-wda.sh` of the `/macos-simtunnel` skill.
  - Name sessions `secchain-<worktree>` (iOS) and `secchain-<worktree>-mac` (macOS). A session name becomes a tailnet host name, so it must not collide with sessions of other repositories.
  - Close a session with `simtunnel down <session>` and the same environment variables as `up`, because macOS runners are shared with CI.
  - A remote session cannot pass launch arguments, so debug builds offer hard-to-reach states on screen: "Use Demo Data" on the "SecChain cannot reach its Keychain items" screen and in the repository list's toolbar, and "Show Sample Error" in the same toolbar. The macOS session builds the `DebugUnsigned` configuration (Debug without code signing, because the runner has no signing identity), so the macOS app always starts on that screen. The iOS Simulator build is signed locally and reaches the simulator's Keychain, but nobody can answer the authentication that revealing a stored value needs, so a reveal is checked with demo data. Add a debug-only control when a check needs a state none of them reaches.
  - Fall back to a local simulator (`make ios`) only when the check cannot be done with tap, type, and screenshot operations (XCUITest, `xcrun simctl` as the subject of the check), or when an operational condition of Phase 1 of the `/ios-simulator` skill applies (unpushed changes, no tailnet connection, the runner concurrency limit, and so on). State the reason in the completion report.

## Xcode project

- `SecChain.xcodeproj` is the only source of truth for the project structure. Change it through the Xcode GUI or by editing `project.pbxproj` directly.
- Do not run `xcodegen generate` and do not keep a `project.yml` in the repository. The mechanical check is the `xcode-project-source` item of `~/.agents/skills/create-new-app/scripts/check-setup.sh`.
