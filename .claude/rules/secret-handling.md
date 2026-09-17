# Secret values never leave the Keychain path

SecChain exists to keep secret values out of files, logs, and terminals. The invariants are defined in `documents/PROJECT.md` ("Security invariants" and "Command-line tool"); this rule states how they apply while writing code and while verifying it.

- Do not add any code path that prints, logs, or returns a secret value to a caller that could display it. This includes error descriptions, `debugDescription`, `dump`, test failure messages, and snapshot files.
- Do not add a command or flag that writes a secret value to standard output.
- Do not accept a secret value as a command-line argument.
- Do not persist a secret value anywhere except the Keychain, including temporary files and `UserDefaults`.
- Tests and manual verification use obviously fake values (for example `dummy-value-for-test`). Never paste a real credential into a test, a fixture, a log, an issue, or a pull request.
- When verifying `secchain run`, assert on a derived fact (the variable is set, its length, or a hash) instead of echoing the value.
