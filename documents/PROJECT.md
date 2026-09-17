# SecChain — Project Requirements

SecChain is a per-repository secret manager for macOS. Secret values live only in the macOS Keychain; a command-line tool, a macOS app, and an iOS app manage the same items. The name combines *secret*, *secure*, *security*, and *keychain*.

This document is the source of truth for requirements and for the design decisions that constrain every implementation issue. It was derived from the original request (https://github.com/bannzai/ideamemo/issues/310, written in Japanese).

## Problem

Development secrets (API keys, access tokens, service credentials, anything usually placed in `.env`) end up as plaintext files inside repositories. They leak through commits, backups, screen sharing, and AI coding agents that read the working tree.

SecChain keeps the values in the Keychain and only hands them to the process that needs them.

```text
Repository                     macOS Keychain
├── .git                       ├── <repository-a> / OPENAI_API_KEY
├── package.json        ──▶    ├── <repository-a> / CLOUDFLARE_API_TOKEN
└── secret definition file     └── <repository-b> / OPENAI_API_KEY
    (names only)
```

## Scope

Everything in this section is in scope for the first release. There is no reduced "MVP" subset.

### Storage

- Secret values are stored in the macOS **data protection keychain** through the `SecItem` API. The legacy `SecKeychain` API family is not used.
- Items can synchronize between the Macs of one person through **iCloud Keychain** (`kSecAttrSynchronizable`). SecChain does not implement its own sync.
- Each secret has a protection level chosen by the user (see "Protection levels").
- SecChain stays fully usable as a local secret manager when iCloud Keychain is disabled. "Sync is unavailable" and "the secret is unavailable" are reported as different conditions wherever the system lets us tell them apart.

### Protection levels

User authentication (Touch ID, Apple Watch, or the login password) is opt-in per secret. The default keeps `secchain run` free of prompts.

| Level | Synchronizes | When authentication is requested | Enforced by |
| --- | --- | --- | --- |
| Standard (default) | Yes, or *this device only* if the user turns sync off | Only when a value is revealed in an app | SecChain |
| Confirm | Yes, or *this device only* | Additionally every time `secchain run` reads the secret, and before update / delete | SecChain (LocalAuthentication prompt shown by the command-line tool itself, or an approval from the user's paired iPhone once "Remote approval" ships) |
| Device-bound | Never | Every read, by any front end | The Keychain (`kSecAttrAccessControl` with user presence and a `ThisDeviceOnly` accessibility class) |

- *Confirm* exists because `secchain run -- env` would otherwise let any process running as the user, including an AI coding agent, print every secret without the user noticing.
- *Device-bound* is the most robust level and the least convenient: the value does not reach other devices, is not restored onto a replacement Mac from a backup, and prompts on every read.
- The protection level is stored as a non-secret attribute of the Keychain item, not in a repository file, so that editing a file in the working tree cannot lower it. Lowering a level requires authentication.
- When one `run` needs several protected secrets, a single authentication covers all of them (one `LAContext` passed through `kSecUseAuthenticationContext`).
- Updating or deleting a secret that is not *standard* authenticates first. Every way of lowering a level goes through such an update, so lowering always requires authentication.
- A new secret is *standard* and synchronized unless the user chooses otherwise.
- When a local and a synchronized item of the same name coexist (a copy arrived from another Mac), the local one is the effective secret, and the next write removes the other.

### Remote approval (after the first release)

Tracked in https://github.com/bannzai/SecChain/issues/32. The open design points (who talks to CloudKit on the Mac, pairing, when the fallback applies) are decided there with measurements and then recorded under "Design decisions".

An authentication that SecChain itself requests on a Mac (the *confirm* level) can be answered on the user's iPhone or iPad instead of at the Mac: the Mac files an approval request, the iOS app shows what is being asked and approves it after Face ID / Touch ID. It serves Macs without Touch ID, sessions where the local prompt cannot be shown (SSH), and commands started by an AI coding agent while the user is away from the Mac.

- It is opt-in. The default stays the local prompt.
- It is another way to answer an existing authentication, not a fourth protection level.
- *Device-bound* secrets are excluded: the Keychain itself enforces user presence on the device that holds the value, and a remote approval cannot satisfy that.
- The request travels through the user's **CloudKit private database**. SecChain runs no server. A request or an approval never contains a secret value; it names the repository, the secret names, the command, the requesting Mac, and an expiry.
- An approval must not be forgeable by a process running as the user on the Mac, because that is exactly the actor *confirm* exists to stop. An approval is therefore a signature made by a key that only the iPhone holds, over the request's identifier, nonce, and expiry, and the Mac verifies it against a public key enrolled once.

### Repository scoping

- Secrets belong to a repository. The same secret name can exist in several repositories as independent items.
- The repository identity must survive different checkout paths on different Macs (`~/Projects/example` and `~/src/example` are the same repository). An absolute local path alone is therefore not a valid identity.
- Directories that are not Git repositories need a defined behavior (an explicit identifier or a clear error).

Identification rules (implemented in `RepositoryIdentity.swift` and `RepositoryIdentityResolver.swift`):

1. An identifier declared in the secret definition file wins. It is the way to use SecChain in a directory without a usable remote, and to make a fork share (or not share) the upstream's secrets on purpose.
2. Otherwise the `origin` remote URL is normalized to `host/owner/repo`: user info, port, scheme, a trailing `.git`, trailing slashes, and letter case are dropped, so `git@github.com:Owner/Repo.git` and `https://github.com/owner/repo` are the same repository. `git config` is asked, which answers the same from sub-directories and linked worktrees.
3. No Git repository, no `origin`, or an `origin` that is a local path is an error that names the fix. SecChain never falls back to the directory path.

The Keychain item of a secret is a generic password with `kSecAttrService` = `com.bannzai.SecChain.repository.<identifier>` and `kSecAttrAccount` = the secret name.

### Secret definition file

- A repository may contain a Git-trackable file listing the secret **names** it needs.
- The file never contains secret values.

The file is `.secchain` at the root of the working tree, one entry per line:

```text
# comment
@repository my-notes
OPENAI_API_KEY
CLOUDFLARE_API_TOKEN
```

- A secret name is a POSIX environment variable name (ASCII letters, digits, underscores, not starting with a digit), because `secchain run` exports it under that name.
- `@repository <identifier>` is optional and replaces the identity derived from the Git remote.
- A line containing `=` is rejected, and the error does not echo the line, so a pasted `.env` file is refused instead of committed.
- `secchain set` and `secchain delete` edit the text in place: comments and ordering written by hand survive.
- The file is optional. Without it, `run` uses every secret stored for the repository. With it, `run` refuses to start while a declared secret has no stored value.

### Command-line tool

| Operation | Notes |
| --- | --- |
| Set / update a secret | The value is read from a hidden terminal prompt or from standard input. It is never accepted as a command-line argument (shell history, process listing). |
| List secrets | Prints names only. |
| Delete a secret | Removes the Keychain item. |
| Run a command with secrets | `secchain run -- <command>` reads the repository's secrets and passes them to the child process as environment variables. A subset of secrets can be selected. No plaintext temporary files. |

There is deliberately no command that prints a secret value to standard output. `run` is the primary way to consume secrets, so that shell automation and AI coding agents can use a secret without being able to read it.

### macOS app

SwiftUI app with: repository list, per-repository secret list, add / update / delete, choosing the protection level, sync state and the information needed to configure it, and understandable errors when the Keychain cannot be accessed. Secret values are hidden by default; revealing one requires an explicit user action and user authentication.

### iOS app

A SwiftUI iOS app manages the same synchronized items from an iPhone or iPad: repository list, secret list, add / update / delete, and reveal after Face ID / Touch ID. It has no `run` equivalent. *This device only* and *device-bound* secrets created on a Mac are not visible on iOS, and the app says so instead of showing an empty repository without explanation.

### One store for all front ends

A secret registered in the macOS app is usable from the command-line tool in that repository, and the other way around. Synchronized secrets are also manageable from the iOS app. All three are signed by the same team and use the same access group, service naming, and attributes.

### Error handling

Security framework `OSStatus` values are translated into errors a user can act on: item not found, save failed, access denied, user authentication failed, repository not identifiable, not a Git repository, definition present but value missing, delete failed, updating an existing name, access-group mismatch between the two front ends, and missing entitlement / code-signing problems. Error output never contains secret values.

### Security invariants

- Secret values are never written to stdout, stderr, application logs, debug logs, analytics, crash metadata, or shell history.
- Secret values are never persisted outside the Keychain: not in `.env`, JSON, plist, SQLite, `UserDefaults`, or any Git-tracked file.
- Repository-side files contain only secret names, repository identity, and non-sensitive settings.

### Tests

Repository identification, per-repository isolation, add / update / delete, missing secret, interoperability in both directions between the two front ends, handing secrets to a child process, no secret value in logs, no secret value in the definition file. Tests that need a real signed build are separated from unit tests (see "Test layers").

### Documentation and agent skill

- `README.md` covers setup and basic command-line usage.
- An agent skill (`SKILL.md`) ships in the repository so that AI coding agents use `secchain run` instead of asking for or reading secret values.

## Non-goals

Team vaults, organizations, workspaces, member management, share links, a custom cloud backend or sync service, a web console, and sharing between different Apple Accounts. The target is one person using several Macs with the same Apple Account.

"Remote approval" does not change this: it uses the user's own CloudKit private database, which SecChain's maintainer cannot read, only to carry approval requests between that user's devices. Secret values keep traveling through iCloud Keychain alone.

Masking secrets before an AI agent reads them (outside of `secchain run`) is not part of this project.

## Design decisions

These decisions are fixed. Implementation issues build on them instead of re-evaluating them.

### 1. Keychain only, data protection keychain, optional iCloud sync

Every query sets `kSecUseDataProtectionKeychain`; synchronized items additionally set `kSecAttrSynchronizable`. On macOS, access to the data protection keychain is granted through code-signing entitlements, not through per-item access control lists, so no permission dialog interrupts non-interactive use.

Constraints that follow from Apple's documentation:

- Synchronizable items cannot use an accessibility class ending in `ThisDeviceOnly`, and queries on them are limited to class and attribute keys plus `kSecMatchLimit`.
- Updating or deleting a synchronizable item affects every device.
- The Keychain treats the synchronizable and non-synchronizable variants of the same service/account as different items. Changing a secret between *synchronized* and *this Mac only* is a copy-then-delete, not an attribute update.
- An app cannot reliably detect whether iCloud Keychain is enabled. The app explains the conditions for sync instead of claiming a sync status it cannot observe.

### 2. The command-line tool ships inside the app bundle, signed by the same team

Keychain access groups on macOS come from code-signing entitlements, and `keychain-access-groups` is a restricted entitlement that must be authorized by a provisioning profile. A standalone executable cannot embed a provisioning profile; signing one with that entitlement gets it killed at launch. Apple's guidance is to wrap the tool in an app-like bundle.

- The command-line executable is packaged as a minimal bundle at `SecChain.app/Contents/Helpers/secchain.app` with its own `Info.plist`, `embedded.provisionprofile`, and an entitlements file listing the shared access group.
- Both the app and the tool use one shared access group, `<Team ID>.<shared group identifier>`, and pass it explicitly as `kSecAttrAccessGroup`.
- Users get the tool on their `PATH` as a symlink into the installed app bundle.
- An unsigned `swift build` product cannot reach the shared items (`errSecMissingEntitlement`). This is reported as a code-signing error, never as "secret not found".

The maintainer has shipped this construction in another macOS app (an embedded, team-signed command-line tool reading the app's synchronized data protection keychain items without any permission dialog), including the observation that a standalone executable signed with `keychain-access-groups` is killed at launch.

### 3. Distribution: Developer ID for macOS, App Store for iOS

The iOS app can only be distributed through the App Store (TestFlight during development). The Mac App Store is not used for the macOS app: it requires App Sandbox, which conflicts with a tool that runs arbitrary commands in arbitrary directories. Releases are signed with a Developer ID certificate, use the hardened runtime, are notarized and stapled, and are published on GitHub Releases. Homebrew distribution is a **cask** with a `binary` stanza for the embedded tool; a source-built formula cannot work because of decision 2.

Consequences for contributors: a fork must be signed with the contributor's own team to touch a real Keychain, and such a build uses a different access group than the official build, so the two cannot read each other's secrets.

### 4. Two authentication mechanisms, both opt-in

Authentication can be requested in two different places, and SecChain offers both because they trade off differently (see "Protection levels").

- **Requested by SecChain** through the LocalAuthentication framework (`LAContext.evaluatePolicy`) before it reads the item. Nothing is attached to the Keychain item, so the secret can still synchronize. The command-line tool shows the system prompt itself; it does not depend on the app running. This is the *confirm* level and the reveal action in the apps.
- **Enforced by the Keychain** through `kSecAttrAccessControl`. Apple's pattern for this uses `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, and `ThisDeviceOnly` items are not eligible for iCloud Keychain, so this mechanism excludes synchronization. This is the *device-bound* level.

Neither is the default, because a prompt on every `secchain run` makes frequent invocations unusable. In every level, the shared access group limits item access to binaries signed by the SecChain team with the entitlement.

The command-line prompt needs a logged-in graphical session. Over SSH or in other contexts where the prompt cannot be shown, protected secrets fail with an authentication error instead of being read without confirmation. "Remote approval" is the planned way to answer such an authentication from a paired iPhone; until it ships, and whenever no iPhone is paired, the authentication error stays.

## Measured behavior

Observed on 2026-09-17 with macOS 26 / Xcode 26.5, using `secchain doctor` and `make test-integration` with builds signed by the team (Apple Development identity, automatic signing).

| Observation | Result |
| --- | --- |
| The app and the embedded tool read, write, and delete each other's synchronizable items in the shared access group | Works in both directions, no permission dialog |
| An unsigned `swift build` product performs the same calls | Every call returns `errSecMissingEntitlement` (-34018) |
| The same service/account stored once with and once without `kSecAttrSynchronizable` | Two separate items; `kSecAttrSynchronizableAny` returns both |
| A non-secret attribute (`kSecAttrDescription`) read with `kSecReturnAttributes` | Readable without reading the value |
| Item with `kSecAttrAccessControl` (user presence, `WhenPasscodeSetThisDeviceOnly`) read with `LAContext.interactionNotAllowed = true` | `errSecInteractionNotAllowed` (-25308) on macOS: the Keychain enforces the prompt. The iOS 26.5 Simulator returns the value without authentication, so enforcement on iOS must be checked on a device |
| The same access control combined with `kSecAttrSynchronizable = true` | `SecItemAdd` fails with `errSecParam` (-50): device-bound and synchronized are mutually exclusive |
| An attribute-only list query that matches an access-controlled item, with prompting disabled | The whole query fails with `errSecInteractionNotAllowed`. A device-bound secret is therefore stored as a listable generic-password marker (empty value) plus the protected value under another item class (internet password), which no list query can match |
| `LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)` from the embedded tool | `true` |
| `LAContext.evaluatePolicy` from the embedded tool with nobody answering | The call stays pending (the process was still waiting after 6 seconds), i.e. the tool can present the system prompt. Answering it is a manual check |
| The iOS app on the Simulator (locally signed, entitlements embedded) | Reads and writes items in the shared access group |

## Test layers

| Layer | Runs where | Covers |
| --- | --- | --- |
| Unit tests against an in-memory Keychain double | Anywhere, including CI on pull requests from forks | Repository identification, isolation, definition file, error translation, environment construction for `run`, no-leak assertions |
| Signed integration tests against the real data protection keychain | A Mac with the team's signing identity | Add / update / delete, sync attribute handling, interoperability between the app and the embedded tool |
| Manual checks | Two Macs and an iPhone on the same Apple Account | Actual iCloud Keychain propagation, authentication prompts on real hardware |

## References

Apple documentation consulted before these decisions (retrieved 2026-09-17):

- TN3137: On Mac keychain APIs and implementations — https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- Sharing access to keychain items among a collection of apps — https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
- Signing a daemon with a restricted entitlement — https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement
- `kSecAttrSynchronizable` — https://developer.apple.com/documentation/security/ksecattrsynchronizable
- Restricting keychain item accessibility — https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility
- Accessing keychain items with Face ID or Touch ID — https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id
- Configuring app groups — https://developer.apple.com/documentation/xcode/configuring-app-groups
