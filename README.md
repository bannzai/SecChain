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

The iOS app is distributed through the App Store once published; it manages the same iCloud-synchronized secrets from an iPhone or iPad, answers the authentications of a paired Mac (see "Remote approval"), and has no command-line equivalent.

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
secchain list                 # the names run passes to this repository
secchain list --long          # + protection level, sync state, the scope of each name, and declared-but-missing names
secchain list --repositories  # every repository that has secrets on this Mac
secchain list --scopes        # every shared scope, with the repositories it is passed to
secchain list --scope user    # the names of one scope; --scope repository lists the repository's own
secchain list --env prod      # the names run --env prod passes (see "Environments")
secchain list --envs          # the environments of each scope, and how many secrets have none
```

Values are never printed by any `list` form.

### Run a command with secrets

```bash
secchain run -- npm run dev
secchain run --only OPENAI_API_KEY -- ./scripts/smoke-test.sh
```

`run` reads the repository's secrets, and those of the shared scopes allowed for it (see "Share secrets between repositories"), and hands them to the child process as environment variables; the child replaces the `secchain` process (`execve`), so no SecChain process keeps holding the values and no plaintext temporary file is ever created. A secret above *standard* protection asks for Touch ID or your password before the command starts; one prompt covers every protected secret the command needs. A paired iPhone can answer that question instead of the Mac (see "Remote approval").

There is deliberately no command that prints a secret value to standard output. `run` is the way a shell script or an AI coding agent consumes a secret without being able to read it — see the [`secchain` agent skill](#ai-agent-skill).

### Share secrets between repositories

A secret that several repositories use goes into a shared scope instead of into each repository: the built-in `user` scope for what is the same everywhere, or a custom scope you name for one purpose.

```bash
secchain set OPENAI_API_KEY --scope user                  # store it once
secchain scope allow user 'github.com/bannzai/*'          # pass the user scope to your repositories
secchain set YOUTUBE_API_KEY --scope youtube              # the first secret of a custom scope creates it
secchain scope allow youtube github.com/bannzai/youtuber
secchain scope deny youtube github.com/bannzai/youtuber
secchain delete YOUTUBE_API_KEY --scope youtube
```

- A shared scope is passed only to the repositories an `@allow` of your `~/.secchain` names (see "`~/.secchain`"). `scope allow` and `scope deny` add and remove those lines; nothing inside a repository can add one, so a repository you merely cloned cannot claim your shared secrets.
- A pattern is a repository identifier as `secchain list --repositories` prints it, or the start of one followed by `*`: `github.com/bannzai/*` covers every repository of `bannzai` and none of `bannzai-other`. Quote a pattern with `*` so that the shell leaves it alone.
- When a name is in several scopes a repository gets, the repository's own secret wins, then the custom scopes in the order of `~/.secchain`, then the user scope. `secchain list --long` shows which scope each name comes from.
- Custom scope names use lowercase letters, digits, and hyphens. Without `--scope`, `set` and `delete` act on the repository's own secrets as before.
- The macOS app does the same without a terminal: the sidebar lists the shared scopes under **Scopes**, **+ → Add Scope** adds one, and **Repository Settings** of a repository turns each scope on or off for it. A scope that a wildcard `@allow` passes stays on there; change the wildcard in `~/.secchain` itself.

### Environments

One name can hold a value per deployment target — `local`, `dev`, `prod`, any name you choose — so that `OPENAI_API_KEY` stays `OPENAI_API_KEY` in every one of them instead of becoming `OPENAI_API_KEY_PROD`:

```bash
secchain set OPENAI_API_KEY --env prod        # store the value of prod
secchain run --env prod -- npm run build      # the command gets the prod value
secchain delete OPENAI_API_KEY --env prod
secchain list --env prod                      # the names of prod only
secchain list --long                          # adds the environment column; "-" for no environment
secchain list --envs                          # each scope's environments, and how many of its secrets have none
```

To give an existing repository environments:

```bash
secchain list --long                          # the secrets you have now (environment "-")
secchain env migrate local                    # move the current values to local at once (any name works: dev is fine too)
secchain set OPENAI_API_KEY --env prod        # store the value of prod
secchain run --env local -- npm run dev
secchain run --env prod -- npm run build
```

- Instead of moving everything at once, you can move one secret at a time and check each: `secchain env migrate local OPENAI_API_KEY`. `run` needs `--env` from the first secret you move on, though.
- A scope that holds a secret of an environment has environments; nothing else records it, so the state reaches your other Macs through iCloud Keychain with the secrets. Deleting its last secret of an environment gives it none again.
- Where a scope has environments, `run --env <environment>` gets only the secrets of that environment from it — never those of another environment, and never those left without one. `set` needs `--env` there as well, and `run` without `--env` refuses to start and says how to go on. A scope without environments gives its secrets in every environment, so a user scope whose `OPENAI_API_KEY` is the same everywhere can stay without environments while a repository has them.
- Giving a shared scope environments makes `--env` necessary in every repository it is passed to. The first `set --env` or `env migrate` of one secret in a scope that still holds secrets without an environment warns about that, names those secrets, and says how to move them.
- `env migrate` keeps the value, the protection level, and the synchronization; a `confirm` or `device-bound` secret asks for authentication first, once for the whole command. It never overwrites a value the environment already holds, and with nothing left to move it does nothing. `--scope` moves a shared scope's secrets.
- `.secchain` declares names only and knows nothing of environments: every name it declares needs a value in each environment you run with. `delete --env` keeps a name declared while another environment still holds it.
- Environment names use lowercase letters, digits, and hyphens, like custom scope names.

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

1. Is this the same repository? `secchain list --repositories` shows the identifiers this Mac has secrets for; a different Git remote or `--repository` means a different identifier.
2. Is the secret in a shared scope? `secchain list --scopes` shows each scope with the repositories it is passed to; a scope without an `@allow` for this repository is not passed to it.
3. Is this the official, team-signed build? A build signed with a different team reads and writes a separate Keychain vault (see "Building from source").
4. If the secret was set on another Mac, does it meet the sync conditions in "Initial setup"?

## Protection levels

User authentication (Touch ID, Apple Watch, or your login password) is opt-in per secret. The default keeps `secchain run` free of prompts.

| Level | Synchronizes | When authentication is requested |
| --- | --- | --- |
| `standard` (default) | Yes, or this device only if you turn sync off | Only when a value is revealed in an app |
| `confirm` | Yes, or this device only | Additionally every time `secchain run` reads the secret, and before update / delete |
| `device-bound` | Never | Every read, by any front end, enforced by the Keychain itself |

`confirm` exists because `secchain run -- env` would otherwise let any process running as you — including an AI coding agent — print every secret without you noticing. `device-bound` is the most robust and least convenient level: the value never reaches another device and is not restored from a backup onto a replacement Mac.

The authentication a `confirm` secret asks for can be answered on your iPhone instead of at the Mac (see "Remote approval"). A `device-bound` secret cannot: the Keychain itself demands user presence on the Mac that holds the value.

## Remote approval

Your iPhone can answer the authentication that a `confirm` secret asks for: the Mac files the request in your own iCloud, SecChain on the iPhone shows what is being asked, and Face ID signs the approval. It is for Macs without Touch ID, for sessions where no prompt can be shown at all (SSH), and for commands an AI coding agent starts while you are away from the Mac. Nothing changes until you pair a Mac, and SecChain never puts a stored secret value into the request: the iPhone is shown the repository, the secret names with the scope each one comes from, the command as you typed it, and the name of the Mac.

Both devices are signed in to the same Apple Account with iCloud on. This uses CloudKit, which is a different setting from the iCloud Keychain that synchronizes the secrets themselves — the records are in your own private database, which nobody else, the author of SecChain included, can read.

### Pair a Mac with your iPhone

1. On the iPhone, open SecChain, open the toolbar's menu of further actions, choose **Remote Approval**, and tap **Pair This iPhone**. The screen then shows a 12-digit number, and **Allow Notifications** is what lets a request reach you while the app is closed.
2. On the Mac, run `secchain pair`, type the number the iPhone shows, and confirm with Touch ID or your password.

```bash
secchain pair                          # enrolls the key of the iPhone whose number you type
secchain pair --number 1234-5678-9012  # same, without being asked for the number
secchain pair status                   # which iPhone is paired, and whether it is asked by default
secchain pair confirm-on-iphone on     # ask that iPhone without --approve-remotely
secchain pair remove                   # stop letting the iPhone answer
```

Each Mac is paired separately, and only the key you enroll can approve, so nothing else that reaches your iCloud account can answer for you. Changing the setting or removing the pairing authenticates first. Pairing again on the iPhone replaces its key, after which every Mac pairs once more.

### Ask the iPhone

```bash
secchain run --approve-remotely -- npm run dev
secchain set OPENAI_API_KEY --approve-remotely
secchain delete OPENAI_API_KEY --approve-remotely
```

Without the flag, a paired Mac still prompts locally and asks the iPhone only where the prompt cannot be shown at all — over SSH, for example, where it reports `no authentication prompt can be shown here, asking your paired iPhone instead`. `secchain pair confirm-on-iphone on` turns that around: every `confirm` authentication on that Mac goes to the iPhone, which is the setting to use for a Mac without Touch ID and for commands an AI coding agent starts. `--approve-remotely` for a `device-bound` secret reports `a device-bound secret can only be confirmed on this Mac, asking here` and prompts locally.

While it waits, `secchain` writes the time left to standard error (standard output belongs to the command being run):

```text
secchain: waiting for approval on MacBook Pro's paired iPhone, 118s left
```

A request stays open for two minutes. Ctrl-C stops waiting and tells the iPhone to drop the request. Rejected, expired, and cancelled are reported as what they are, and the command does not start.

## The `.secchain` file

A repository can list the names of the secrets it needs in a `.secchain` file at its root. The file is safe to commit: it holds names only, and a line containing `=` is rejected so a pasted `.env` file is refused instead of committed.

```text
# Secrets this project needs
OPENAI_API_KEY
CLOUDFLARE_API_TOKEN
```

- A secret name is a POSIX environment variable name (letters, digits, underscores, not starting with a digit) — `secchain run` exports it under that name.
- Names are all the file holds. Which repository it is comes from its Git remote (or `--repository`), and which shared scopes it gets is yours to decide in `~/.secchain`, not the repository's; an `@repository` line of an earlier development build is refused with the error saying what replaces it.
- `secchain set` and `secchain delete` keep the current directory's `.secchain` in sync, as long as neither is given `--repository` or `--scope`; comments and ordering you wrote by hand survive. With `--repository`, the command acts on a different repository's secrets, so the local `.secchain` is not the right file to update and is left alone. With `--scope`, the name goes into that scope of `~/.secchain` instead.
- The file is optional. Without it, `run` uses every secret of the scopes the repository gets. With it, `run` refuses to start while a name it declares has no stored value there, and names it in the error, together with the `secchain scope allow` to run when a scope not allowed for the repository has it.

## `~/.secchain`

Your own file, outside every repository, decides what no repository can decide for itself: which shared scopes a repository gets. Keep it with your dotfiles; it belongs to one Mac and is not synchronized through iCloud (a symbolic link into a dotfiles repository stays a link when `secchain` edits it). It has the line format of `.secchain`:

```text
# user scope
OPENAI_API_KEY
ANTHROPIC_API_KEY
@allow github.com/bannzai/*

@scope youtube
YOUTUBE_API_KEY
@allow github.com/bannzai/youtuber
@allow github.com/bannzai/shorts-*
```

- The lines before the first `@scope` are the user scope; `@scope <name>` starts a custom scope that lasts until the next one. The names of a scope are the ones it is meant to hold, and `secchain list --long --scope <name>` reports those without a value.
- `@allow <pattern>` passes the scope to the repositories the pattern names. A scope without one is passed to no repository. A fork and its upstream are two repositories: to give the fork the upstream's secrets, keep them in a scope that allows both.
- `secchain set --scope`, `secchain delete --scope`, `secchain scope allow`, `secchain scope deny`, and the switches of **Repository Settings** in the macOS app edit the file for you and keep your comments and ordering. Like `.secchain`, it never holds a value.

### Repository identity

The repository identity comes from the `origin` remote, normalized to `host/owner/repo` (case, credentials, port, scheme, and a trailing `.git` are dropped), so `git@github.com:Owner/Repo.git` and `https://github.com/owner/repo` are the same repository and the same Keychain items — including from a linked worktree or a sub-directory. A directory that is not a Git repository, has no `origin`, or has an `origin` that is a local path needs `--repository <identifier>`; SecChain never falls back to the checkout path, because the same repository must resolve to the same secrets from every checkout on every Mac.

`--repository <identifier>` on any command acts on a repository other than the current directory's, without touching that repository's `.secchain` file. The identifier is folded to lowercase like a remote's, so `--repository github.com/Owner/Repo` is the same repository as a checkout of it. It cannot contain `#`, which separates the environment in the names SecChain gives its Keychain items.

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

The hook refuses three kinds of call and answers with the `secchain run -- <command>` that does the same work without exposing a value:

- reading a `.env` or `.env.*` file — through the `Read` tool, or through a command that reads one (`cat`, `grep`, `source`, an input redirect);
- printing the environment of a run — `secchain run -- env`, `printenv`, or a shell command under `secchain run` that echoes a variable into the terminal;
- running a script of another language written on the command line under `secchain run` (`python3 -c …`, `node -e …`), which the hook cannot read while every secret is in its environment. The same script in a file passes.

It leaves the documented ways of using a secret alone, including piping a value straight into the program that consumes it. The list of what stops and what passes, with examples, is in [the skill](skills/secchain/SKILL.md); `make test-hooks` checks the script against every case of that list. The hook needs `python3`, which comes with the Xcode Command Line Tools. Codex CLI sends the same input and reads the same decision, so the same script runs there from `~/.codex/hooks.json`, but it guards shell commands only: Codex has no `Read` tool, and a file read through an MCP tool arrives under that tool's own name, which this hook does not match. Codex also runs that hook only after the exact definition is trusted with `/hooks` (and trusted again after every change to it), so until that step the guard is configured but inactive.

The hook is a guard against reaching for a secret by habit, not a sandbox. It parses a command the way a shell would without evaluating it, so a path carried through a shell variable gets past it, and a hook configured inside the project runs a script the agent may be able to edit — which is why the skill also describes installing it in `~/.claude/settings.json`. What keeps a value out of a file and out of a terminal is `secchain` itself, which has no command that prints one. Masking secret values in the output of a command an agent runs stays outside SecChain (`documents/PROJECT.md`, "Non-goals").

## Development

### Tests

Tests are split by what they need to run, so that most of them run anywhere while the ones that need a real Keychain stay honest about it.

| Layer | Command | Runs where | Covers |
| --- | --- | --- | --- |
| Unit tests | `make test` | Anywhere, including CI on pull requests from forks | Everything that can be decided without the system Keychain: repository identity, the `.secchain` and `~/.secchain` files, which scopes a repository gets and the order a name is taken in, the rules of `SecretStore` (protection levels, authentication, synchronization), the environment `run` builds, the error translation, and the assertions that a value never appears in a description or a log. They run against an in-memory Keychain double (`InMemorySecretKeychain`) and an authenticator double, so no prompt appears |
| Signed integration tests | `make test-integration` | A Mac with the team's signing identity (not CI, because a runner has none) | The real data protection keychain, exercised by the signed binaries themselves: the app and the embedded tool read and write each other's items, a repository scope and a custom scope go through the same round trip, a device-bound item is refused without user interaction and a scope keeps its device-bound values apart from a repository of the same name, the secrets of an environment are listed, read, and moved into it, and a device-bound one is not moved without user interaction, an unsigned `swift build` product fails with `errSecMissingEntitlement`, the command-line tool end to end including scopes and environments (`scripts/test/cli.sh`), and both binaries reaching SecChain's CloudKit container (the Mac must be signed in to iCloud) |
| Manual checks | — | Two Macs and an iPhone on one Apple Account | What no automated run can reach: actual iCloud Keychain propagation between devices, and answering a Touch ID / Face ID prompt. Tracked in the pre-release checklist issue |

`make test-integration` builds the app first, then runs `scripts/test/integration.sh` with the embedded tool of that build. It stores only its own throwaway values (`dummy-value-for-…`) under throwaway repository identifiers, a throwaway custom scope, and one throwaway name in the user scope, which never gets an environment, uses a throwaway `~/.secchain`, and deletes them again, so it does not touch secrets you keep.

Where each requirement of the project is covered is listed in [`documents/test-coverage.md`](documents/test-coverage.md).

### Verification commands

`AGENTS.md` lists the commands used while changing the project (`make build-macos`, `make build-ios`, `make macos`, `make cli`, and how screens are checked).

## More

Scope, non-goals, security invariants, and the fixed design decisions: [documents/PROJECT.md](documents/PROJECT.md).

## License

[MIT](LICENSE)
