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
secchain run -- curl -H "Authorization: Bearer ${OPENAI_API_KEY}" https://api.openai.com/v1/models
secchain run --only CLOUDFLARE_API_TOKEN -- ./scripts/deploy.sh
```

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

## Checking what is available

```bash
secchain list         # secret names for this repository — never values
secchain list --long  # + protection level, sync state, and names declared but not yet set
secchain doctor        # whether this installation can reach SecChain's Keychain items
```

Use `secchain list` to check whether a secret already exists before asking the user to set it. Use `secchain doctor` when a command reports a secret as missing that the user says should exist — the most common cause is a `secchain` binary that is not the team-signed one from the installed app (see the repository's `README.md`).
