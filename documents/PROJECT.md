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
| Confirm | Yes, or *this device only* | Additionally every time `secchain run` reads the secret, and before update / delete | SecChain (LocalAuthentication prompt shown by the command-line tool itself, or an approval from the user's paired iPhone, see "Remote approval") |
| Device-bound | Never | Every read, by any front end | The Keychain (`kSecAttrAccessControl` with user presence and a `ThisDeviceOnly` accessibility class) |

- *Confirm* exists because `secchain run -- env` would otherwise let any process running as the user, including an AI coding agent, print every secret without the user noticing.
- *Device-bound* is the most robust level and the least convenient: the value does not reach other devices, is not restored onto a replacement Mac from a backup, and prompts on every read.
- The protection level is stored as a non-secret attribute of the Keychain item, not in a repository file, so that editing a file in the working tree cannot lower it. Lowering a level requires authentication.
- When one `run` needs several protected secrets, a single authentication covers all of them (one `LAContext` passed through `kSecUseAuthenticationContext`).
- Updating or deleting a secret that is not *standard* authenticates first. Every way of lowering a level goes through such an update, so lowering always requires authentication.
- A new secret is *standard* and synchronized unless the user chooses otherwise.
- When a local and a synchronized item of the same name coexist (a copy arrived from another Mac), the local one is the effective secret, and the next write removes the other.

### Remote approval

Part of the first release. Tracked in https://github.com/bannzai/SecChain/issues/32; how it is built is fixed in design decision 5.

An authentication that SecChain itself requests on a Mac (the *confirm* level) can be answered on the user's iPhone or iPad instead of at the Mac: the Mac files an approval request, the iOS app shows what is being asked and approves it after Face ID / Touch ID. It serves Macs without Touch ID, sessions where the local prompt cannot be shown (SSH), and commands started by an AI coding agent while the user is away from the Mac.

- It is opt-in. The default stays the local prompt.
- It is another way to answer an existing authentication, not a fourth protection level.
- *Device-bound* secrets are excluded: the Keychain itself enforces user presence on the device that holds the value, and a remote approval cannot satisfy that.
- The request travels through the user's **CloudKit private database**. SecChain runs no server. A request or an approval never contains a secret value; it names the repository, the secret names, the command, the requesting Mac, and an expiry.
- An approval must not be forgeable by a process running as the user on the Mac, because that is exactly the actor *confirm* exists to stop. An approval is therefore a signature made by a key that only the iPhone holds, over the request's identifier, nonce, expiry, and a digest of what the iPhone showed, and the Mac verifies it against a public key enrolled once.

### Repository scoping

- Secrets belong to a repository by default. The same secret name can exist in several repositories as independent items. Secrets that several repositories use can be kept in a shared scope instead (see "Secret scopes").
- The repository identity must survive different checkout paths on different Macs (`~/Projects/example` and `~/src/example` are the same repository). An absolute local path alone is therefore not a valid identity.
- Directories that are not Git repositories need a defined behavior (an explicit identifier or a clear error).

Identification rules (implemented in `RepositoryIdentity.swift` and `RepositoryIdentityResolver.swift`):

1. `--repository <identifier>` on the command line wins, for acting on a repository from outside its checkout or on a directory without a usable remote. The identifier is folded to lowercase.
2. Otherwise the `origin` remote URL is normalized to `host/owner/repo`: user info, port, scheme, a trailing `.git`, trailing slashes, and letter case are dropped, so `git@github.com:Owner/Repo.git` and `https://github.com/owner/repo` are the same repository. `git config` is asked, which answers the same from sub-directories and linked worktrees.
3. No Git repository, no `origin`, or an `origin` that is a local path is an error that names `--repository`. SecChain never falls back to the directory path.

Nothing in the working tree takes part (design decision 6). A fork is a repository of its own: what it shares with its upstream belongs in a shared scope whose `@allow` lines name both.

An identifier is lowercase however it was given, `--repository` and one typed in an app included, for the reason rule 2 drops letter case: the Keychain compares services case-sensitively (`SecItem.h`: without `kSecMatchCaseInsensitive`, string matching is case-sensitive), so `--repository github.com/Owner/Repo`, spelled the way the hosting service shows the name, would otherwise name other items than a checkout of that repository, and the secrets would silently split.

### Secret scopes

A secret belongs to one scope:

| Scope | Identified by | `kSecAttrService` |
| --- | --- | --- |
| `repository` | the repository identity; the default of every command | `com.bannzai.SecChain.repository.<identifier>` |
| `user` | built in, one per user | `com.bannzai.SecChain.scope.user` |
| custom, for example `youtube` | a name the user gives it | `com.bannzai.SecChain.scope.<name>` |

- `user` and the custom scopes are *shared scopes*. They hold what several repositories use, such as an `OPENAI_API_KEY` that is the same everywhere or a `YOUTUBE_API_KEY` of a few repositories, so that one value is stored once instead of once per repository.
- A custom scope name consists of lowercase ASCII letters, digits, and hyphens, and starts with a letter or a digit, because it becomes part of a Keychain service, of a line of `~/.secchain`, and of a command-line argument. `user` names the built-in scope and `repository` is reserved: neither can name a custom scope.
- `kSecAttrAccount` is the secret name in every scope. Protection levels and synchronization work the same way in every scope.
- A device-bound value is kept in an internet password item (see "Measured behavior"). A repository scope uses its identifier as `kSecAttrServer`; a shared scope uses its whole service, `com.bannzai.SecChain.scope.<name>`, so that a repository whose identifier happens to be a scope name never shares that item with the scope. Nothing is stored for a repository whose identifier is itself such a service, in any letter case: only an identifier given by hand (`--repository`, or typed in an app) can be one, and a secret stored there would let a later write or delete replace or remove the scope's device-bound value without the authentication its level asks for.
- `secchain run` passes the repository scope and every shared scope that an `@allow` of `~/.secchain` passes to the repository. A name held by several of them comes from the repository scope first, then from the custom scopes in the order `~/.secchain` lists them, then from the user scope.

### Secret definition file

- A repository may contain a Git-trackable file listing the secret **names** it needs.
- The file never contains secret values.

The file is `.secchain` at the root of the working tree, one entry per line:

```text
# comment
OPENAI_API_KEY
CLOUDFLARE_API_TOKEN
```

- A secret name is a POSIX environment variable name (ASCII letters, digits, underscores, not starting with a digit), because `secchain run` exports it under that name.
- The file has no directive: it cannot name the repository or choose a scope (design decision 6). `@repository`, which development builds before https://github.com/bannzai/SecChain/issues/56 read as the repository's identifier, is refused with an error that names what replaced it: `--repository` for a directory without a Git remote, and a shared scope for secrets shared with another repository.
- A line containing `=` is rejected, and the error does not echo the line, so a pasted `.env` file is refused instead of committed.
- `secchain set` and `secchain delete` edit the text in place: comments and ordering written by hand survive.
- The file is optional. Without it, `run` uses every secret of the scopes passed to the repository. With it, `run` refuses to start while a declared name has no stored value in those scopes; when a shared scope that is not passed to the repository holds or declares the name, the error names that scope and `secchain scope allow`.

### The user's definition file

`~/.secchain` decides which shared scopes a repository gets. It is outside every repository and not tracked by Git; the user keeps it with their dotfiles. It belongs to one Mac and is never synchronized through iCloud. `$HOME` locates it, the way a shell expands `~`.

It has the line format of `.secchain`. The names and `@allow` lines before the first `@scope` belong to the user scope, and `@scope <name>` starts a custom scope that lasts until the next `@scope`:

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

- The names of a scope are the names it is meant to hold. They do not limit what `run` passes; `secchain list --long --scope <name>` reports the ones without a value. `secchain set NAME --scope <name>` adds the name, together with the `@scope` line when the scope has none.
- `@allow <pattern>` names repositories the scope is passed to: a repository identifier, or the start of one followed by `*` (a `*` anywhere else is an error). Letter case is ignored, because the identifier of a Git remote is lowercase. `github.com/bannzai/*` names every repository of `bannzai` and none of `bannzai-other`. A scope without `@allow` is passed to no repository.
- The identifier `@allow` is compared with is the one of "Repository scoping": the Git remote or `--repository`. Nothing in the repository can change it.
- A second `@scope` for the same scope is an error.
- The file holds secret names, scope names, and patterns, never a value; a line containing `=` is rejected as in `.secchain`, and so is a pattern that contains one.
- `secchain set --scope`, `secchain delete --scope`, `secchain scope allow`, and `secchain scope deny` edit the text in place: comments and ordering written by hand survive, and a symbolic link into a dotfiles repository stays a link. An edit is applied to the file as it is when the command writes it, so that a change made while the command waited for a value or an authentication is kept.
- The `.secchain` of the home directory is this file, and so is the `.secchain` of a dotfiles repository that `~/.secchain` links into. No command reads or writes it as a repository's definition file.

### Command-line tool

| Operation | Notes |
| --- | --- |
| Set / update a secret | The value is read from a hidden terminal prompt or from standard input. It is never accepted as a command-line argument (shell history, process listing). |
| List secrets | Prints names only: the ones `run` passes to the repository, with the scope of each in the long form, or those of one scope. |
| Delete a secret | Removes the Keychain item. |
| Run a command with secrets | `secchain run -- <command>` reads the secrets of the scopes passed to the repository and passes them to the child process as environment variables. A subset of secrets can be selected. No plaintext temporary files. |
| Act on a shared scope | `--scope user` or `--scope <name>` on `set`, `list`, and `delete`. Without it, `set` and `delete` act on the repository scope. `list --scopes` lists the shared scopes with their `@allow` patterns. |
| Pass a shared scope to repositories | `secchain scope allow <scope> <pattern>` and `secchain scope deny <scope> <pattern>` add and remove an `@allow` line of `~/.secchain`. |

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
- Repository-side files contain only secret names. `~/.secchain` contains only secret names, scope names, repository identifiers, patterns, and paths.

### Tests

Repository identification, per-repository isolation, scopes (which shared scopes a repository gets, the order a name is taken in, the Keychain layout of a scope), add / update / delete, missing secret, interoperability in both directions between the two front ends, handing secrets to a child process, no secret value in logs, no secret value in the definition files. Tests that need a real signed build are separated from unit tests (see "Test layers").

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

The command-line prompt needs a logged-in graphical session. Over SSH or in other contexts where the prompt cannot be shown, protected secrets fail with an authentication error instead of being read without confirmation. "Remote approval" answers such an authentication from a paired iPhone (decision 5); whenever no iPhone is paired, the authentication error stays.

### 5. Remote approval: the command-line tool talks to CloudKit, and an approval is a signature by the paired iPhone

Decided on 2026-09-18 from the measurements under "Remote approval spike".

**The command-line tool uses CloudKit directly.** The embedded tool saves the approval request to the private database of `iCloud.com.bannzai.SecChain` and fetches the approval itself. The macOS app does not have to run, so the tool keeps working the same way over SSH and on a Mac where the app was never opened. Routing requests through the app (XPC) was not chosen: it would make a resident app a precondition of `secchain run`.

- The tool is signed with the container entitlements and with `com.apple.application-identifier`, whose value must match the profile the build embeds (`scripts/xcode/embed_cli.sh`).
- A command-line process cannot receive pushes, so the tool polls. The iPhone saves the approval under a record name derived from the request identifier, and the tool fetches that record by identifier every 2 seconds until the request expires: a CloudKit call measured about 0.3 seconds, and a 2 minute expiry bounds one request to about 60 fetches.
- The iPhone learns about a request from a `CKQuerySubscription` with a visible notification. Notifications can be coalesced or dropped, so the iOS app also queries for open requests when it launches and when a notification arrives.

**An approval is a signature by a key that only the paired iPhone holds.** The iPhone creates a P-256 key in its Secure Enclave with the access control `.privateKeyUsage` and `.biometryAny`; the Mac verifies the signature against the public key enrolled during pairing (`RemoteApproval.swift`) and against its own copy of the request, never against values read back from CloudKit.

- Sharing an Apple Account is not enough to approve. CloudKit records which account wrote a record, not which device wrote it or whether its user was asked. Without the signature the Mac would accept any approval record in the private database, and everything that carries the container entitlement on that account can write one: the requesting Mac's own tool and app, another Mac or iPad signed in to the same Apple Account, and, on a Mac that holds the team's signing identity, any program built there. The signature is what makes "approved" mean "the enrolled iPhone, after a biometric match".
- Pairing is done once per Mac. Afterwards an approval is a notification and Face ID.
- `.biometryAny` rather than `.biometryCurrentSet`: changing the enrolled Face ID or Touch ID does not force a new pairing. The device passcode alone cannot sign. This is already stricter than revealing a value in the iOS app, which accepts the passcode (`.deviceOwnerAuthentication`), so a stricter key would not protect synchronized secrets from someone who knows the passcode.
- The Simulator cannot create such a key, so signing behind Face ID is verified on a device (pre-release checklist).

**Pairing compares a short number on both screens.** The iPhone publishes its public key in the private database. `secchain` on the Mac and the iOS app both show a short number derived from the SHA-256 of that key; after the user confirms that they match, the Mac authenticates the user locally (Touch ID or password) and stores the public key in its data protection keychain as a *this device only* item. A QR code was not chosen: the tool has no camera, and scanning the Mac's screen with the iPhone would still leave CloudKit as the way the key reaches the Mac. Each Mac is paired separately.

**When remote approval is used.** It stays opt-in, and only a paired Mac uses it:

1. `secchain run --approve-remotely -- <command>` asks the iPhone for this run.
2. When the local prompt cannot be shown and LocalAuthentication fails at once (SSH), a paired Mac falls back to the iPhone. A prompt that nobody answers in a graphical session keeps waiting (measured), so being away from the Mac cannot be detected and needs 1 or 3.
3. A per-Mac setting makes the iPhone the default way to answer *confirm* authentications, for Macs without Touch ID and for commands started by AI coding agents. The setting is stored next to the enrolled public key, and changing it requires local authentication.

Without a pairing, all three behave as before: the local prompt, or the authentication error.

**While waiting**, the tool writes the waiting state and the remaining time to standard error (standard output belongs to the child process) and waits until the expiry (2 minutes). Ctrl-C saves a cancellation record so that the iPhone stops offering the request. Rejected, expired, and cancelled are distinct errors, and all of them exit with the status of a failed authentication.

**Production schema.** Developer ID and App Store builds can only use the production environment of the container, where a record type exists only after the schema has been deployed from the development environment in the CloudKit Console. Deployed record types cannot be deleted, so the doctor's `DoctorProbe` type is not deployed, and `secchain doctor --cloudkit` moves to the record types of the protocol.

### 6. A repository's own files cannot widen what `run` passes

Decided on 2026-09-23 in https://github.com/bannzai/SecChain/issues/56, after the review of the first design of shared scopes (https://github.com/bannzai/SecChain/issues/55#issuecomment-5791730706).

A repository is written by whoever wrote it, and `git clone` puts it on the Mac as it is. If anything in its working tree decided which repository it is, or which shared scopes it gets, a clone of an unknown repository could present itself as one of the user's and receive their shared secrets: with `@allow github.com/bannzai/*` in `~/.secchain`, a clone whose `.secchain` said `@repository github.com/bannzai/anything` would have matched.

- The identity comes from the Git remote, which is where the user cloned from, or from what the user passes: `--repository` ("Repository scoping").
- Only the `@allow` lines of `~/.secchain` decide which shared scopes a repository gets. The names a repository's `.secchain` lists never add a scope; a name only stops `run` when no passed scope holds it.
- `.secchain` has no directive at all. The `@repository` of earlier development builds is refused rather than ignored, so that a fork or a directory that relied on it is told what replaced it instead of silently becoming another repository. Nothing has been released, so there is no compatibility path.
- The issue gave `@repository`'s two uses a new home in `~/.secchain`, `@alias <fork> <upstream>` and `@path <directory> <identifier>`. On 2026-09-24, before either was released, the maintainer dropped both: `--repository` already names a directory without a usable remote, and a shared scope already shares secrets between a fork and its upstream, so `~/.secchain` only decides which shared scopes a repository gets.
- `~/.secchain` is found through `$HOME`. Setting `HOME` for `secchain` takes a process that already runs as the user, which could just as well pass `--repository` or write `~/.secchain` itself: the boundary is against what a repository's files say, not against such a process.
- `@allow` is a setting of one Mac and is not synchronized: allowing a scope for a checkout on one Mac says nothing about a clone of the same name on another. A new Mac gets the secrets through iCloud Keychain and `~/.secchain` through the user's dotfiles.

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

### Remote approval spike

Observed on 2026-09-17 for https://github.com/bannzai/SecChain/issues/32, with the same tools plus the App Store Connect API (version 4.4.1 of its specification), `secchain doctor --cloudkit`, the app's `--doctor-cloudkit` launch argument, and the debug-only "Run Remote Approval Checks" screen.

| Observation | Result |
| --- | --- |
| Enabling iCloud (CloudKit) and Push Notifications on the App IDs with `POST /v1/bundleIdCapabilities` | Works for both `com.bannzai.SecChain` and `com.bannzai.SecChain.cli`. The API has no endpoint for CloudKit containers |
| Changing the capabilities of an App ID | Its existing Developer ID profiles turn `INVALID`. `POST /v1/profiles` with the same name then fails with HTTP 409 ("Multiple profiles found with the name") while the invalid profile exists |
| `xcodebuild -allowProvisioningUpdates` for the app with `iCloud.com.bannzai.SecChain` in its entitlements | The automatically managed profile that Xcode creates for `com.bannzai.SecChain` lists the container, and CloudKit calls on it succeed, so no step on the developer website is needed. The same build with `PRODUCT_BUNDLE_IDENTIFIER=com.bannzai.SecChain.cli` assigns the container to the tool's App ID |
| The embedded tool signed with the container entitlements but without `com.apple.application-identifier` | `CKError` 8 (missing entitlement): "Trying to initialize a container without an application ID" |
| The embedded tool additionally signed with the application identifier of the profile it embeds (a development build embeds the app's profile) | Account status, the user record identifier, saving / fetching / deleting a record in the private database, and saving / fetching / deleting a `CKQuerySubscription` whose notification has an `alertBody` all succeed, with the app not running |
| The macOS app binary (`--doctor-cloudkit`) | Same result as the embedded tool |
| Developer ID export when the archived tool carries the app's application identifier | `xcodebuild -exportArchive` fails: the tool's profile "doesn't match the entitlements file's value for the com.apple.application-identifier entitlement". The archive must already sign the tool with its own identifier |
| A process without the container entitlement creates `CKContainer(identifier:)` | The process stops with a trace trap inside CloudKit (exit status 133) |
| Developer ID export with `iCloudContainerEnvironment` = `Production`, the tool archived with its own application identifier | Export, notarization, stapling, and the Gatekeeper assessment succeed. Both bundles are signed with the container and `com.apple.developer.icloud-container-environment` = `Production`, the only environment the Developer ID profiles allow |
| The Developer ID signed tool and app against the production environment | The account status and the user record identifier are returned. Saving a record fails with `CKError` 12 ("Cannot create new type DoctorProbe in production schema") and saving the subscription with `CKError` 11 ("Did not find record type"): a record type created in the development environment is usable in production only after the schema is deployed |
| Duration of CloudKit calls from a development build of the tool | The doctor's ten calls (account status, user record identifier, and the saves, fetches, and deletes of the record and the subscription, including the two clean-up deletes) take 3.19 seconds in total |
| The iOS app on the iOS 26.5 Simulator of a GitHub Actions runner (simtunnel), Secure Enclave | `SecureEnclave.isAvailable` is `true`, and a Secure Enclave P-256 key without access control signs an approval that verifies with its public key |
| The same Simulator, a Secure Enclave key with `.privateKeyUsage` and `.biometryCurrentSet` | Creating the key fails with LocalAuthentication error -1020 ("This call is not supported on iOS Simulator"). `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` is `false` with -7 (biometry not enrolled) for biometry type Face ID. A key that demands Face ID can only be checked on a device |
| The same Simulator, CloudKit | `accountStatus` is `noAccount` (3): no Apple Account is signed in there, so neither saving a subscription nor receiving its notification can be observed on it |

### Remote approval, while it was built

Observed on 2026-09-18 for https://github.com/bannzai/SecChain/issues/38 with `secchain doctor
--cloudkit` of a development build, against the record types of the protocol
(`documents/remote-approval-records.md`) in the development environment.

| Observation | Result |
| --- | --- |
| Saving the first record of `ApprovalRequest`, `ApprovalDecision`, `ApprovalCancellation`, and `DevicePairing` in the development environment | Creates each record type with its fields, and the queries below work, so no step in the CloudKit Console is needed for development |
| A record fetched by record name right after it was saved | Returned at once, which is what the 2 second polling of an answer relies on |
| A `CKQuery` on the same record a moment after it was saved | Missing at first, found after 2 seconds (the same on two consecutive runs). A query reads an index CloudKit updates asynchronously, so a request the iOS app queries for can be a couple of seconds behind the notification about it |
| The whole `doctor --cloudkit` run (16 CloudKit calls, including the two waits for the index and the clean-up deletes) | 13 seconds, of which about 4 are the two index waits |
| `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` from the embedded tool with `interactionNotAllowed = true`, which is how LocalAuthentication is told that no prompt may be shown | Fails after 1–2 ms with `LAError` -1004 (`notInteractive`), which `SecretStoreErrorMapping` already reads as "no prompt can be shown here". That is the error a paired Mac takes over from by asking the iPhone. Whether a real SSH session produces the same code is **not** measured: `sshd` answers on this Mac but rejects the connection because no authorized key is installed, and installing one is the user's decision (issue #16) |
| One whole remote approval against the development environment, with a software key standing in for the iPhone (`doctor --remote-approval-end-to-end` of a development build): the Mac files a request, the stand-in reads the request **back out of CloudKit** and signs what it read, and the Mac verifies | Accepted after 5 seconds, so the record layout survives the round trip: the request CloudKit returns produces the same signed message as the copy the Mac kept, including the expiry, which is signed in whole seconds for that reason. An answer signed by another key is refused as `signatureMismatch`, and a rejection stops the read |
| `SIGINT` sent to a process that is waiting for an approval, with the wait wrapped the way `secchain run` wraps it (a `DispatchSource` signal source while `SIGINT` is ignored) | The wait ends as a cancellation and the cancellation record is in the private database. A kqueue-based source therefore sees a signal that the thread Swift's concurrency runtime runs on blocks, which a plain handler installed on that thread would not |
| The release build of the tool (`swift build --configuration release`) | Rejects `doctor --remote-approval-end-to-end` as an unknown option (status 64), and the flag's name does not appear in the binary at all: the shipped tool contains no way to approve its own requests |

## Test layers

| Layer | Runs where | Covers |
| --- | --- | --- |
| Unit tests against an in-memory Keychain double | Anywhere, including CI on pull requests from forks | Repository identification, isolation, scopes, both definition files, error translation, environment construction for `run`, no-leak assertions |
| Signed integration tests against the real data protection keychain | A Mac with the team's signing identity | Add / update / delete in a repository scope and in a shared scope, sync attribute handling, interoperability between the app and the embedded tool |
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
