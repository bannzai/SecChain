# SecChain

A per-repository secret manager for macOS. Secret values live in the macOS Keychain instead of `.env` files, can follow you across your Macs through iCloud Keychain, and are handed to the commands that need them without ever being printed.

```bash
secchain set OPENAI_API_KEY      # value is read from a hidden prompt
secchain list                    # names only
secchain run -- npm run dev      # secrets are passed as environment variables
```

SecChain ships as a macOS app with an embedded command-line tool, plus an iOS app. All of them manage the same Keychain items. Touch ID confirmation is opt-in per secret.

> Status: under development. Nothing is released yet.

Scope, non-goals, security invariants, and design decisions: [documents/PROJECT.md](documents/PROJECT.md).

## License

[MIT](LICENSE)
