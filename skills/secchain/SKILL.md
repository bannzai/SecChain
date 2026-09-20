---
name: secchain
description: Use SecChain (the `secchain` command-line tool) to run commands that need a secret value — an API key, an access token, a service credential, anything that would otherwise go in a `.env` file — instead of asking the user for the value or reading it from a file. Applies whenever a task needs a secret to run a command, and the repository has a `.secchain` file or the user mentions SecChain.
license: MIT
---

# SecChain

SecChain stores secret values in the macOS Keychain, scoped to this repository. You never see the values; you only run commands through the tool that has access to them.

## Rule: run secret-dependent commands through `secchain run`

```bash
secchain run -- <command> [arguments...]
```

`secchain run` reads this repository's stored secrets and passes them to `<command>` as environment variables, then exits with that command's exit status. Use it for anything that needs a secret at runtime: a dev server, a deploy script, a one-off API call, a test suite that hits a real service.

```bash
secchain run -- npm run dev
secchain run --only CLOUDFLARE_API_TOKEN -- ./scripts/deploy.sh
```

To use a secret inside a shell pipeline or with variable expansion, wrap it in `sh -c` so the expansion happens in the child process that actually receives the value. Do not pass the value as another command's argument — arguments are visible to other processes through `ps`, the same exposure `secchain set` avoids by never accepting a value that way. Pipe it in instead:

```bash
secchain run -- sh -c 'printf "Authorization: Bearer %s" "$OPENAI_API_KEY" | curl -H @- https://api.openai.com/v1/models'
```

The single quotes around the `sh -c` script matter: double quotes would let the calling shell expand `$OPENAI_API_KEY` before `secchain run` ever starts, when the variable does not exist yet, silently sending an empty value. `curl -H @-` reads the header from standard input instead of taking it as an argument.

Some secrets in this Keychain are protected at the `confirm` level: `secchain run` shows a Touch ID / password prompt before it starts. That prompt is the user confirming the run, not an error — wait for it instead of treating the run as stuck or failed.

## Rule: never ask the user for a secret value, and never read one

- Do not ask the user to paste a secret value into the chat, a file, or a command argument.
- Do not read a secret value from an existing `.env`, config file, or shell profile on the user's behalf — SecChain exists specifically to keep those values out of files an agent can read.
- Do not run a command whose purpose is to print a secret value, such as `secchain run -- env`, `secchain run -- printenv`, or `secchain run -- sh -c 'echo $NAME'`. `secchain` itself has no command that prints a value; do not work around that by piping a secret-bearing command's output back into your own context.

## Rule: when a secret is missing, ask the user to set it — do not collect the value yourself

If `secchain run` fails because a required secret has no stored value, tell the user which name is missing and ask them to run:

```bash
secchain set <NAME>
```

They run this themselves, in their own terminal, because the prompt reads the value with a hidden `readpassphrase` prompt or from standard input — never as a command-line argument. Do not offer to run `secchain set` for them with the value inline, and do not ask them to tell you the value so that you can run it.

## Enforcing these rules with a Claude Code hook

The rules above are instructions, and an instruction can be forgotten. `hooks/secchain-guard.py` is a `PreToolUse` hook that refuses the calls those rules rule out before they run, and `hooks/settings.json` is the configuration that installs it.

Put the `hooks` key of `hooks/settings.json` into the project's `.claude/settings.json`, keeping whatever that file already holds. When the project has no settings file yet, the example is the whole file:

```bash
mkdir -p .claude
cp .claude/skills/secchain/hooks/settings.json .claude/settings.json
```

For every project instead of one, put the same `hooks` key into `~/.claude/settings.json` and replace `${CLAUDE_PROJECT_DIR}/.claude/skills/secchain` in the path with the directory the skill is installed in, such as `$HOME/.agents/skills/secchain`. The hook runs `python3`, which macOS provides with the Xcode Command Line Tools.

What it refuses, with a message that names `secchain run -- <command>` as the way to do the same thing:

| Call | Example |
| --- | --- |
| Reading a `.env` or `.env.*` file with the `Read` tool | `Read .env.local` |
| A command that reads one | `cat .env`, `grep TOKEN .env.production`, `source .env`, `secchain set NAME < .env` |
| A command under `secchain run` that prints the environment | `secchain run -- env`, `secchain run -- printenv NAME`, `secchain run -- sh -c 'env \| grep API'` |
| A command under `secchain run` that prints a value | `secchain run -- sh -c 'echo $OPENAI_API_KEY'`, the same piped into `cat` or `tee` |
| A script of another language written on the command line, under `secchain run` | `secchain run -- python3 -c '…'`, `secchain run -- node -e '…'`. Put the script in a file and run `secchain run -- python3 script.py` |

A launcher in front of any of these does not hide it: `env secchain run -- env` and `nohup secchain run -- printenv` are refused too.

It lets through everything these rules describe as the way to work, including piping a value straight into the program that consumes it (`printf … \| curl -H @-`), `env NAME=value <command>` under `secchain run`, running a script file with any interpreter, and naming a `.env` file in a command that does not read it (`rm .env`, `echo '.env' >> .gitignore`). A `.env.example` is refused like any other `.env.*` file: nothing in the name tells the hook that the file holds no real value.

The hook reads a command the way a shell parses it, and it does not evaluate the command. A value carried through a shell variable (`SECRET_FILE=.env; cat "$SECRET_FILE"`) therefore gets past it. It is a guard against reaching for a secret by habit, not a sandbox: what keeps a value out of a file and out of the terminal is `secchain` itself, which has no command that prints one.

Where the configuration goes matters for the same reason. A hook in the project's `.claude/settings.json` runs a script inside the working tree, which an agent that may write to the project can change. Put it in `~/.claude/settings.json`, with the path of an installation outside the repository, wherever that matters.

Codex CLI sends the same hook input and reads the same decision from standard output, so the script runs there too, from `~/.codex/hooks.json` or `<repository>/.codex/hooks.json` (or an inline `[hooks]` table in `config.toml`). What it covers there is narrower: Codex matches a shell call as `Bash` with the command in `tool_input.command`, which is the half of this hook that works, and it has no `Read` tool — a file read goes through an MCP tool under that tool's own name (`mcp__filesystem__read_file`), which this hook neither matches nor knows how to read. On Codex, treat it as a guard on shell commands only ([Codex hooks](https://learn.chatgpt.com/docs/hooks), "Tool coverage"). Codex also runs a hook from any of those files only after it is trusted: it records trust against the hook definition's hash, so a new or changed definition is skipped until it is reviewed with `/hooks` in the CLI, and `<repository>/.codex/hooks.json` loads only when the project's `.codex/` layer is trusted as well. Until that step the guard is configured but inactive ([Codex hooks](https://learn.chatgpt.com/docs/hooks), "Review and trust hooks").

## Checking what is available

```bash
secchain list         # secret names for this repository — never values
secchain list --long  # + protection level, sync state, and names declared but not yet set
secchain doctor        # whether this binary can use SecChain's shared Keychain access group at all
```

Use `secchain list` to check whether a secret already exists before asking the user to set it.

`secchain doctor` only tells you whether this binary can use SecChain's Keychain access group at all — an unsigned or wrongly signed binary fails every command immediately with a code-signing error, not a "not found" one, so you would not need `doctor` to notice that case. `doctor` passing does **not** mean a specific secret is reachable: a binary signed by a different Apple Developer Team also passes `doctor` (it can use its own access group), while reading and writing a Keychain vault separate from the official app's — so a secret the user says exists can still come back "not found". When that happens, do not conclude the binary is broken; ask the user to check, in order: the repository identifier (`secchain list --repositories`), whether this is the official, team-signed installation, and — if the secret was set on another Mac — the iCloud Keychain sync conditions. See the repository's `README.md` ("Check the installation") for the full explanation.
