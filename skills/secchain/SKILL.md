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

## Rule: when a secret is missing, ask the user to set it — do not collect the value yourself

If `secchain run` fails because a required secret has no stored value, tell the user which name is missing and ask them to run:

```bash
secchain set <NAME>
```

They run this themselves, in their own terminal, because the prompt reads the value with a hidden `readpassphrase` prompt or from standard input — never as a command-line argument. Do not offer to run `secchain set` for them with the value inline, and do not ask them to tell you the value so that you can run it.

## Checking what is available

```bash
secchain list         # secret names for this repository — never values
secchain list --long  # + protection level, sync state, and names declared but not yet set
secchain doctor        # whether this binary can use SecChain's shared Keychain access group at all
```

Use `secchain list` to check whether a secret already exists before asking the user to set it.

`secchain doctor` only tells you whether this binary can use SecChain's Keychain access group at all — an unsigned or wrongly signed binary fails every command immediately with a code-signing error, not a "not found" one, so you would not need `doctor` to notice that case. `doctor` passing does **not** mean a specific secret is reachable: a binary signed by a different Apple Developer Team also passes `doctor` (it can use its own access group), while reading and writing a Keychain vault separate from the official app's — so a secret the user says exists can still come back "not found". When that happens, do not conclude the binary is broken; ask the user to check, in order: the repository identifier (`secchain list --repositories`), whether this is the official, team-signed installation, and — if the secret was set on another Mac — the iCloud Keychain sync conditions. See the repository's `README.md` ("Check the installation") for the full explanation.
