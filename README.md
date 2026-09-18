# SecChain

A per-repository secret manager for macOS. Secret values live in the macOS Keychain instead of `.env` files, can follow you across your Macs through iCloud Keychain, and are handed to the commands that need them as environment variables. SecChain itself never prints a secret value to a terminal, a log, or a file — what a command does with a value once it has it is up to that command, which is why an AI coding agent should never be asked to run one that dumps its environment (see "AI agent skill").

```bash
secchain set OPENAI_API_KEY      # value is read from a hidden prompt
secchain list                    # names only, never values
secchain run -- npm run dev      # secrets are passed as environment variables
```

SecChain ships as a macOS app with an embedded command-line tool, plus an iOS app. All of them read and write the same Keychain items, so a secret added in the app is usable from the command line in that repository, and the other way around.

> **Status: not released yet.** There is no build to download. The install instructions below describe the intended distribution and will get real links once the first release ships.

## Install

- **macOS app (Developer ID, GitHub Releases):** download the `.dmg` from the [Releases page](https://github.com/bannzai/SecChain/releases) once a release exists, open it, and move `SecChain.app` to `/Applications`. The app is notarized, so Gatekeeper opens it without a warning.
- **Homebrew cask:** `brew install --cask bannzai/tap/secchain` (tap name and formula land with the first release).

Either path installs the same signed app bundle, with the command-line tool embedded inside it at `SecChain.app/Contents/Helpers/secchain.app`. The Homebrew cask puts `secchain` on your `PATH` through its `binary` stanza. Installing from the DMG puts only the app in `/Applications`; put `secchain` on your `PATH` yourself:

```bash
mkdir -p ~/.local/bin
ln -sf /Applications/SecChain.app/Contents/Helpers/secchain.app/Contents/MacOS/secchain ~/.local/bin/secchain
```

Either way it is a symlink into the app bundle, not a second, separately signed copy of the tool.

The iOS app is distributed through the App Store once published; it manages the same iCloud-synchronized secrets from an iPhone or iPad and has no command-line equivalent.

## Initial setup

Secrets synchronize between your Macs through **iCloud Keychain**. To get sync:

1. Sign in to the same Apple Account on every Mac.
2. Turn on iCloud Keychain: System Settings → *[your name]* → iCloud → Passwords and Keychain.

SecChain is fully usable as a local-only secret manager when iCloud Keychain is off; sync just does not happen, and a secret stored as *standard* or *confirm* stays on that one Mac (see "Protection levels"). macOS cannot reliably report whether iCloud Keychain is enabled, so SecChain never claims a sync status it cannot observe. If a secret you expect to see on another Mac is missing, check the conditions above by hand — the same Apple Account, iCloud Keychain on for both Macs, and a level that syncs (*this Mac only* and *device-bound* secrets never do).

## CLI usage

Run these from inside the repository whose secrets you want; SecChain derives the repository identity from the Git remote (see "Repository identity" below).

### Set or update a secret

```bash
secchain set OPENAI_API_KEY
# Value for OPENAI_API_KEY (input hidden):
```

The value is always read from a hidden terminal prompt or from standard input — `secchain` never accepts it as a command-line argument, so `secchain`'s own invocation cannot leak it through shell history or `ps` output. That guarantee is about `secchain`, not about how you produce the value: piping in a command whose own arguments contain the value (`echo "the-value" | secchain set NAME`) still puts it in your shell history.

```bash
pbpaste | secchain set OPENAI_API_KEY
op read "op://vault/item/credential" | secchain set OPENAI_API_KEY
```

```bash
secchain set OPENAI_API_KEY --level confirm   # authenticate on every read, not just on reveal
secchain set OPENAI_API_KEY --no-sync         # this Mac only
```

### List secrets

```bash
secchain list                # names only
secchain list --long         # + protection level, sync state, and declared-but-missing names
secchain list --repositories  # every repository that has secrets on this Mac
```

Values are never printed by any `list` form.

### Run a command with secrets

```bash
secchain run -- npm run dev
secchain run --only OPENAI_API_KEY -- ./scripts/smoke-test.sh
```

`run` reads the repository's secrets and hands them to the child process as environment variables; the child replaces the `secchain` process (`execve`), so no SecChain process keeps holding the values and no plaintext temporary file is ever created. A secret above *standard* protection asks for Touch ID or your password before the command starts; one prompt covers every protected secret the command needs.

There is deliberately no command that prints a secret value to standard output. `run` is the way a shell script or an AI coding agent consumes a secret without being able to read it — see the [`secchain` agent skill](#ai-agent-skill).

### Delete a secret

```bash
secchain delete OPENAI_API_KEY
```

Deleting a synchronized secret removes it on every device.

### Check the installation

```bash
secchain doctor
secchain doctor --authenticate   # also asks for Touch ID / your password once
```

`doctor` checks one thing: whether this binary can use SecChain's shared Keychain access group at all. An unsigned or wrongly signed binary fails that outright — every command reports a code-signing error immediately, without needing `doctor` to find out (see "Building from source" below).

`doctor` passing does not mean every secret you expect is visible. A binary signed by a different Apple Developer Team (a fork built and signed with your own team, for example) passes `doctor` — it can use its own access group just fine — but that access group is not the official app's, so a secret stored by the official app is genuinely absent from it, and you get a real "not found" for a secret you know exists elsewhere. When that happens, check, in order:

1. Is this the same repository? `secchain list --repositories` shows the identifiers this Mac has secrets for; a different Git remote or `.secchain` `@repository` line means a different identifier.
2. Is this the official, team-signed build? A build signed with a different team reads and writes a separate Keychain vault (see "Building from source").
3. If the secret was set on another Mac, does it meet the sync conditions in "Initial setup"?

## Protection levels

User authentication (Touch ID, Apple Watch, or your login password) is opt-in per secret. The default keeps `secchain run` free of prompts.

| Level | Synchronizes | When authentication is requested |
| --- | --- | --- |
| `standard` (default) | Yes, or this device only if you turn sync off | Only when a value is revealed in an app |
| `confirm` | Yes, or this device only | Additionally every time `secchain run` reads the secret, and before update / delete |
| `device-bound` | Never | Every read, by any front end, enforced by the Keychain itself |

`confirm` exists because `secchain run -- env` would otherwise let any process running as you — including an AI coding agent — print every secret without you noticing. `device-bound` is the most robust and least convenient level: the value never reaches another device and is not restored from a backup onto a replacement Mac.

## The `.secchain` file

A repository can list the names of the secrets it needs in a `.secchain` file at its root. The file is safe to commit: it holds names only, and a line containing `=` is rejected so a pasted `.env` file is refused instead of committed.

```text
# Secrets this project needs
@repository my-notes
OPENAI_API_KEY
CLOUDFLARE_API_TOKEN
```

- A secret name is a POSIX environment variable name (letters, digits, underscores, not starting with a digit) — `secchain run` exports it under that name.
- `@repository <identifier>` is optional. It overrides the identity SecChain would otherwise derive from the Git remote, which is how a directory without a usable remote uses SecChain, and how a fork can be made to share (or not share) the upstream's secrets on purpose.
- `secchain set` and `secchain delete` keep the current directory's `.secchain` in sync, as long as neither is given `--repository`; comments and ordering you wrote by hand survive. With `--repository`, the command acts on a different repository's secrets, so the local `.secchain` is not the right file to update and is left alone.
- The file is optional. Without it, `run` uses every secret stored for the repository. With it, `run` refuses to start while a name it declares has no stored value, and names it in the error.

### Repository identity

Without a `.secchain` declaration, the repository identity comes from the `origin` remote, normalized to `host/owner/repo` (case, credentials, port, scheme, and a trailing `.git` are dropped), so `git@github.com:Owner/Repo.git` and `https://github.com/owner/repo` are the same repository and the same Keychain items — including from a linked worktree or a sub-directory. A directory that is not a Git repository, has no `origin`, or has an `origin` that is a local path needs an explicit `@repository` line; SecChain never falls back to the checkout path, because the same repository must resolve to the same secrets from every checkout on every Mac.

`--repository <identifier>` on any command acts on a repository other than the current directory's, without touching that repository's `.secchain` file.

## Building from source

An unsigned `swift build` product cannot read SecChain's Keychain items. Keychain access groups on macOS are granted through code-signing entitlements (`keychain-access-groups`), which requires a provisioning profile; a plain `swift build` binary has none. This is reported as a code-signing error (`secchain doctor` will show it), not as "secret not found" — see `documents/PROJECT.md` for the full explanation.

If you sign a build with your own Apple Developer Team to test it, it uses your own access group, so it reads and writes a Keychain vault separate from the official, team-signed distribution — your build and someone else's official install never see each other's secrets, even in the same repository.

## AI agent skill

SecChain ships an [Agent Skill](https://agentskills.io) at [`skills/secchain/SKILL.md`](skills/secchain/SKILL.md) that tells a coding agent to run secret-dependent commands through `secchain run` instead of asking for, or reading, a secret value.

To use it in a project, copy the skill folder into that project's skill directory, for example:

```bash
mkdir -p .claude/skills
cp -R /path/to/SecChain/skills/secchain .claude/skills/secchain   # Claude Code, project-level
```

Other Agent-Skills-compatible tools look for the same `SKILL.md` shape under their own skill directory (for example `~/.agents/skills/secchain` for a personal, cross-project install). See the skill file itself for the exact instructions given to the agent.

### Claude Code hooks

A skill tells an agent what to do; a [hook](https://code.claude.com/docs/en/hooks) decides whether a call runs at all. The skill folder ships both parts of one: [`skills/secchain/hooks/secchain-guard.py`](skills/secchain/hooks/secchain-guard.py), a `PreToolUse` hook, and [`skills/secchain/hooks/settings.json`](skills/secchain/hooks/settings.json), the configuration that installs it. Put that `hooks` key into the project's `.claude/settings.json`, or into `~/.claude/settings.json` with the path of a cross-project install:

```bash
mkdir -p .claude
cp .claude/skills/secchain/hooks/settings.json .claude/settings.json   # a project without other settings
```

The hook refuses two kinds of call and answers with the `secchain run -- <command>` that does the same work without exposing a value:

- reading a `.env` or `.env.*` file — through the `Read` tool, or through a command that reads one (`cat`, `grep`, `source`, an input redirect);
- printing the environment of a run — `secchain run -- env`, `printenv`, or a shell command under `secchain run` that echoes a variable into the terminal.

It leaves the documented ways of using a secret alone, including piping a value straight into the program that consumes it. The list of what stops and what passes, with examples, is in [the skill](skills/secchain/SKILL.md); `make test-hooks` checks the script against every case of that list. The hook needs `python3`, which comes with the Xcode Command Line Tools. Codex CLI uses the same input and output shape, so the same script works there.

Masking secret values in the output of a command an agent runs is not part of SecChain (`documents/PROJECT.md`, "Non-goals"): the hook stops the calls whose purpose is to expose a value, not every way a program could print one it was given.

## Development

### Tests

Tests are split by what they need to run, so that most of them run anywhere while the ones that need a real Keychain stay honest about it.

| Layer | Command | Runs where | Covers |
| --- | --- | --- | --- |
| Unit tests | `make test` | Anywhere, including CI on pull requests from forks | Everything that can be decided without the system Keychain: repository identity, the `.secchain` file, the rules of `SecretStore` (protection levels, authentication, synchronization), the environment `run` builds, the error translation, and the assertions that a value never appears in a description or a log. They run against an in-memory Keychain double (`InMemorySecretKeychain`) and an authenticator double, so no prompt appears |
| Signed integration tests | `make test-integration` | A Mac with the team's signing identity (not CI, because a runner has none) | The real data protection keychain, exercised by the signed binaries themselves: the app and the embedded tool read and write each other's items, a device-bound item is refused without user interaction, an unsigned `swift build` product fails with `errSecMissingEntitlement`, the command-line tool end to end (`scripts/test/cli.sh`), and both binaries reaching SecChain's CloudKit container (the Mac must be signed in to iCloud) |
| Manual checks | — | Two Macs and an iPhone on one Apple Account | What no automated run can reach: actual iCloud Keychain propagation between devices, and answering a Touch ID / Face ID prompt. Tracked in the pre-release checklist issue |

`make test-integration` builds the app first, then runs `scripts/test/integration.sh` with the embedded tool of that build. It stores only its own throwaway values (`dummy-value-for-…`) under a throwaway repository identifier and deletes them again, so it does not touch secrets you keep.

Where each requirement of the project is covered is listed in [`documents/test-coverage.md`](documents/test-coverage.md).

### Verification commands

`AGENTS.md` lists the commands used while changing the project (`make build-macos`, `make build-ios`, `make macos`, `make cli`, and how screens are checked).

## More

Scope, non-goals, security invariants, and the fixed design decisions: [documents/PROJECT.md](documents/PROJECT.md).

## License

[MIT](LICENSE)
