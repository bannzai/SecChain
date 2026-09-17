# SecChain

A per-repository secret manager for macOS. Secret values live in the macOS Keychain instead of `.env` files, can follow you across your Macs through iCloud Keychain, and are handed to the commands that need them without ever being printed to a terminal, a log, or a file.

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

The value is always read from a hidden terminal prompt or from standard input — never as a command-line argument, so it cannot end up in shell history or in `ps` output:

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

`doctor` reports whether this binary's code signature can reach SecChain's Keychain items. Run it first when a command reports "not found" for a secret you know exists — the most common cause is a binary that is not the team-signed one (see "Building from source" below).

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
- `secchain set` and `secchain delete` keep the file's names in sync; comments and ordering you wrote by hand survive.
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

## More

Scope, non-goals, security invariants, and the fixed design decisions: [documents/PROJECT.md](documents/PROJECT.md).

## License

[MIT](LICENSE)
