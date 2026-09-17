# SecChain

A per-repository secret manager for macOS. Secret values live in the macOS Keychain instead of `.env` files, can follow you across your Macs through iCloud Keychain, and are handed to the commands that need them without ever being printed.

```bash
secchain set OPENAI_API_KEY      # value is read from a hidden prompt
secchain list                    # names only
secchain run -- npm run dev      # secrets are passed as environment variables
```

SecChain ships as a macOS app with an embedded command-line tool, plus an iOS app. All of them manage the same Keychain items. Touch ID confirmation is opt-in per secret.

## The `.secchain` file

A repository can list the names of the secrets it needs in a `.secchain` file at its root. The file is safe to commit: it holds names only, and a line such as `NAME=value` is rejected.

```text
# Secrets this project needs
OPENAI_API_KEY
CLOUDFLARE_API_TOKEN
```

`secchain set` and `secchain delete` keep the file up to date. An optional `@repository <identifier>` line names the repository explicitly, for directories without a Git remote.

> Status: under development. Nothing is released yet.

Scope, non-goals, security invariants, and design decisions: [documents/PROJECT.md](documents/PROJECT.md).

## License

[MIT](LICENSE)
