---
name: secchain
description: Use SecChain (the `secchain` command-line tool) to run commands that need a secret value — an API key, an access token, a service credential, anything that would otherwise go in a `.env` file — instead of asking the user for the value or reading it from a file. Applies whenever a task needs a secret to run a command, and the repository has a `.secchain` file or the user mentions SecChain.
license: MIT
---

# SecChain

SecChain stores secret values in the macOS Keychain, scoped to this repository, or in a shared scope that the user passes to the repositories they choose. You never see the values; you only run commands through the tool that has access to them.

## Rule: run secret-dependent commands through `secchain run`

```bash
secchain run -- <command> [arguments...]
```

`secchain run` reads this repository's stored secrets, together with those of the shared scopes the user allowed for it (the `user` scope, or a custom one such as `youtube`), and passes them to `<command>` as environment variables, then exits with that command's exit status. Use it for anything that needs a secret at runtime: a dev server, a deploy script, a one-off API call, a test suite that hits a real service.

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

## Rule: when a run waits for the user's iPhone, let it wait

The user can pair a Mac with their iPhone and have that confirmation answered there instead. `secchain run` then files a request, waits, and writes a line like this to standard error every two seconds:

```text
secchain: waiting for approval on MacBook Pro's paired iPhone, 118s left
```

That is progress, not an error: the user is being asked on their phone right now.

- Let the command run to the end. A request stays open for two minutes, so allow at least three minutes before any timeout of your own. A process you kill leaves a request on the user's iPhone that answers nothing.
- Do not interrupt it, and do not start the command again to retry. Every run files a new request and sends the user another notification.
- `The request was rejected on your iPhone.`, `No answer arrived from your iPhone before the request expired.`, and `Waiting for the approval was cancelled.` are the user's answer, not a problem to work around. Say which one happened and ask the user how to proceed instead of running the command again yourself.
- Do not add `--approve-remotely` yourself. Whether commands ask the iPhone is the user's setting (`secchain pair confirm-on-iphone on`), and it applies to the commands you start without any flag.

## Rule: never ask the user for a secret value, and never read one

- Do not ask the user to paste a secret value into the chat, a file, or a command argument.
- Do not read a secret value from an existing `.env`, config file, or shell profile on the user's behalf — SecChain exists specifically to keep those values out of files an agent can read.
- Do not run a command whose purpose is to print a secret value, such as `secchain run -- env`, `secchain run -- printenv`, or `secchain run -- sh -c 'echo $NAME'`. `secchain` itself has no command that prints a value; do not work around that by piping a secret-bearing command's output back into your own context.

## Rule: store a secret only in a way that never shows you its value

When `secchain run` fails because a required secret has no stored value, or the task is to move a project's secrets into SecChain, you may run `secchain set` yourself, in these forms only:

```bash
secchain set <NAME> --from-variable                          # the variable <NAME> your shell already has
secchain set <NAME> --from-variable <VARIABLE>               # another variable your shell already has
op read "op://vault/item/credential" | secchain set <NAME>   # the output of the command that produces the value
gh api <endpoint> --jq '.token' | secchain set <NAME>
openssl rand -hex 32 | secchain set <NAME>                   # a new random value
secchain set <NAME>                                          # the user types the value at the hidden prompt
```

- `--from-variable` reads the environment `secchain` itself was started with, so it works where your shell already has the variable, for example one that direnv exports from `.envrc` (`direnv exec . secchain set <NAME> --from-variable`). Where it is not set, `secchain` fails with `<VARIABLE> is not set in the environment of this command`; ask the user then, and do not go looking for the value. Do not use it under `secchain run`: the values `run` passes are already stored, and setting them again would at best change nothing and at worst copy a value into another scope without the user deciding it.
- Pipe the command that produces the value straight into `secchain set`, with nothing in between that prints it.
- For the hidden prompt, start `secchain set <NAME>` where the user can type into it (a terminal they see, such as a tmux pane you share), tell them it is waiting for the value, and wait. Never type into that prompt yourself.

Never store a value in any other way:

- with the value written into the command: `printf 'value' | secchain set <NAME>`, `echo value | secchain set <NAME>`, `secchain set <NAME> <<< value`, a heredoc, `KEY=value secchain set KEY --from-variable`, or `export KEY=value` earlier in the same command;
- with the value read from a file: `secchain set <NAME> < .env`, `grep KEY .env | cut -d= -f2 | secchain set <NAME>`, `source .env && secchain set <NAME> --from-variable`;
- by asking the user to tell you the value in the chat.

When the name already has a value, `secchain set` asks for authentication — Touch ID, the login password, or an approval on the user's paired iPhone — before it replaces the value, whatever the protection level; `secchain delete` does the same before it removes one. That prompt is the user confirming the change, not an error: wait for it the way you wait for the confirmation of `secchain run`. A refused or cancelled authentication is the user's answer: say so and ask how to proceed instead of trying again.

A value that several repositories share goes into a shared scope with `secchain set <NAME> --scope user` (or `--scope <name>`); which one is the user's choice.

## Rule: leave the choice of shared scopes to the user

When `secchain run` says a name is in a scope that is not allowed for this repository, it prints the command that would allow it:

```text
.secchain declares YOUTUBE_API_KEY, which is in scope youtube, not allowed for github.com/owner/repo. Allow it with 'secchain scope allow youtube github.com/owner/repo'.
```

Tell the user and let them run it. Do not run `secchain scope allow` yourself, and do not edit `~/.secchain`: which repositories receive a shared secret is the user's decision, the same way `--approve-remotely` is.

## Rule: name the environment the task is about, and leave migrations to the user

A secret can hold one value per environment, such as `local` and `prod`, under the same name. Where a scope has environments, `secchain run` needs `--env` and passes only the values of that environment:

```bash
secchain run --env local -- npm run dev
secchain run --env prod -- npm run build
```

- Use the environment the task names (a deploy to production runs with `--env prod`). When the task does not say which one and `secchain run` refuses with `... has the environments local, prod, so name the one to run with`, ask the user instead of picking one: running against the wrong deployment target is not a detail to guess.
- `secchain list --envs` shows each scope's environments; `secchain list --env <environment>` shows the names `run --env <environment>` passes.
- When a value is missing in one environment, store it with `secchain set <NAME> --env <environment>`, following the rule above on storing a secret.
- `secchain env migrate` moves existing secrets into an environment, and the first secret moved makes `--env` necessary for every `run` in that repository — for a shared scope, in every repository it is passed to. That is the user's decision: tell them what the warning or the error says, and let them run it.

The steps the user follows to give an existing repository environments:

```bash
secchain list --long                          # the secrets now (environment "-")
secchain env migrate local                    # move the current values to local at once (any name works: dev is fine too)
secchain set OPENAI_API_KEY --env prod        # store the value of prod
secchain run --env local -- npm run dev
secchain run --env prod -- npm run build
```

Moving one secret at a time (`secchain env migrate local OPENAI_API_KEY`) works as well, but `run` needs `--env` from the first one moved on. `.secchain` declares names only, so every name it declares needs a value in each environment a command runs with.

## Enforcing these rules with a Claude Code hook

The rules above are instructions, and an instruction can be forgotten. `hooks/secchain-guard.py` is a `PreToolUse` hook that refuses the calls those rules rule out before they run, and `hooks/settings.json` is the configuration that installs it.

Put the `hooks` key of `hooks/settings.json` into the project's `.claude/settings.json`, keeping whatever that file already holds. When the project has no settings file yet, the example is the whole file:

```bash
mkdir -p .claude
cp .claude/skills/secchain/hooks/settings.json .claude/settings.json
```

For every project instead of one, put the same `hooks` key into `~/.claude/settings.json` and replace `${CLAUDE_PROJECT_DIR}/.claude/skills/secchain` in the path with the directory the skill is installed in, such as `$HOME/.agents/skills/secchain`. The hook runs `python3`, which macOS provides with the Xcode Command Line Tools.

What it refuses, with a message that names the way to do the same thing without exposing a value — `secchain run -- <command>`, or for `secchain set` the forms of the rule on storing a secret:

| Call | Example |
| --- | --- |
| Reading a `.env` or `.env.*` file with the `Read` tool | `Read .env.local` |
| A command that reads one | `cat .env`, `grep TOKEN .env.production`, `source .env`, `secchain set NAME < .env` |
| `secchain set` with the value written into the command | `printf 'value' \| secchain set NAME`, `echo value \| secchain set NAME`, `secchain set NAME <<< value`, a heredoc, `KEY=value secchain set KEY --from-variable` |
| A command under `secchain run` that prints the environment | `secchain run -- env`, `secchain run -- printenv NAME`, `secchain run -- sh -c 'env \| grep API'` |
| A command under `secchain run` that prints a value | `secchain run -- sh -c 'echo $OPENAI_API_KEY'`, the same piped into `cat` or `tee` |
| A script of another language written on the command line, under `secchain run` | `secchain run -- python3 -c '…'`, `secchain run -- node -e '…'`. Put the script in a file and run `secchain run -- python3 script.py` |

A launcher in front of any of these does not hide it: `env secchain run -- env` and `nohup secchain run -- printenv` are refused too.

It lets through everything these rules describe as the way to work, including piping a value straight into the program that consumes it (`printf … \| curl -H @-`), `env NAME=value <command>` under `secchain run`, `secchain set NAME --from-variable`, the output of a command piped straight into `secchain set` (`op read … \| secchain set NAME`), running a script file with any interpreter, and naming a `.env` file in a command that does not read it (`rm .env`, `echo '.env' >> .gitignore`). A `.env.example` is refused like any other `.env.*` file: nothing in the name tells the hook that the file holds no real value. `--from-variable` in a command that assigns any variable is refused too, because the hook does not work out which variable it reads.

The hook reads a command the way a shell parses it, and it does not evaluate the command. A value carried through a shell variable (`SECRET_FILE=.env; cat "$SECRET_FILE"`) therefore gets past it. It is a guard against reaching for a secret by habit, not a sandbox: what keeps a value out of a file and out of the terminal is `secchain` itself, which has no command that prints one.

Where the configuration goes matters for the same reason. A hook in the project's `.claude/settings.json` runs a script inside the working tree, which an agent that may write to the project can change. Put it in `~/.claude/settings.json`, with the path of an installation outside the repository, wherever that matters.

Codex CLI sends the same hook input and reads the same decision from standard output, so the script runs there too, from `~/.codex/hooks.json` or `<repository>/.codex/hooks.json` (or an inline `[hooks]` table in `config.toml`). What it covers there is narrower: Codex matches a shell call as `Bash` with the command in `tool_input.command`, which is the half of this hook that works, and it has no `Read` tool — a file read goes through an MCP tool under that tool's own name (`mcp__filesystem__read_file`), which this hook neither matches nor knows how to read. On Codex, treat it as a guard on shell commands only ([Codex hooks](https://learn.chatgpt.com/docs/hooks), "Tool coverage"). Codex also runs a hook from any of those files only after it is trusted: it records trust against the hook definition's hash, so a new or changed definition is skipped until it is reviewed with `/hooks` in the CLI, and `<repository>/.codex/hooks.json` loads only when the project's `.codex/` layer is trusted as well. Until that step the guard is configured but inactive ([Codex hooks](https://learn.chatgpt.com/docs/hooks), "Review and trust hooks").

## Masking what the model reads: the Claude Mods plugin

The hook stops the calls that reach for a value; it cannot stop a value the user pastes into a prompt, one that appears in a tool result, or a command that gets past its parsing. `hooks/mods` is a Claude Code plugin of function hooks (Claude Mods, early access) that passes every text the model is about to read through `secchain mask`, which replaces the values of the repository's secrets with `***`:

- the submitted prompt (`prompt.submit`);
- every tool result, a subagent's included (`tool.call`), and the error text of a failed call;
- the texts Claude Code adds: system prompt sections (`prompt.section`), the first message's context blocks such as `CLAUDE.md` (`prompt.context`), and injected messages such as an `@`-mentioned file (`prompt.attachment`).

```bash
printf '%s' "$text" | secchain mask             # the repository of the current directory
printf '%s' "$text" | secchain mask --env prod  # only the values of one environment
```

`secchain mask` looks only for *standard* secrets, because reading a `confirm` or `device-bound` value asks for authentication, and says on standard error which secrets it leaves out. Values shorter than 8 characters are not looked for. The plugin never reads a stored value or matches one itself: it hands the text, which may contain a value, to `secchain`, which does the matching and hands back the masked text. It runs next to the hook, not instead of it: install both.

Function hooks need `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`. Load the plugin for one session with `claude --plugin-dir <skill directory>/hooks/mods`, or for every session through the `env` block of `~/.claude/settings.json` (never a project's settings, which Claude Code does not read for this):

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
    "CLAUDE_CODE_PLUGIN_DIRS": "~/.agents/skills/secchain/hooks/mods"
  }
}
```

A tool result that held a value arrives as an error starting with `secchain-mask: the tool ran.`: the tool did run, and what follows is its output. When a prompt, a file, or a command's output shows `***` where you expected a value, SecChain masked it on purpose. Do not try to recover the value (reading the file another way, printing it in pieces, encoding it): run the command that needs it through `secchain run` instead.

## Checking what is available

```bash
secchain list          # the secret names secchain run passes to this repository — never values
secchain list --long   # + protection level, sync state, environment, the scope each name comes from, and names declared but not yet set
secchain list --scopes # the shared scopes and the repositories each is passed to
secchain list --envs   # the environments of each scope passed to this repository
secchain doctor        # whether this binary can use SecChain's shared Keychain access group at all
```

Use `secchain list` to check whether a secret already exists before storing it or asking the user to.

`secchain doctor` only tells you whether this binary can use SecChain's Keychain access group at all — an unsigned or wrongly signed binary fails every command immediately with a code-signing error, not a "not found" one, so you would not need `doctor` to notice that case. `doctor` passing does **not** mean a specific secret is reachable: a binary signed by a different Apple Developer Team also passes `doctor` (it can use its own access group), while reading and writing a Keychain vault separate from the official app's — so a secret the user says exists can still come back "not found". When that happens, do not conclude the binary is broken; ask the user to check, in order: the repository identifier (`secchain list --repositories`), whether the secret is in a shared scope that is not allowed for this repository (`secchain list --scopes`), whether this is the official, team-signed installation, and — if the secret was set on another Mac — the iCloud Keychain sync conditions. See the repository's `README.md` ("Check the installation") for the full explanation.
