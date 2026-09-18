# Remote approval: records and the signed message

What travels between a Mac and the paired iPhone when an authentication is answered remotely
(`documents/PROJECT.md`, design decision 5). The iOS app, the command-line tool, and the
production schema deployment (issue #16) all build on the names in this document.

Everything here lives in the **private database** of the CloudKit container
`iCloud.com.bannzai.SecChain`, in the default zone. SecChain runs no server. **No record carries a
secret value**, only secret names (`.claude/rules/secret-handling.md`).

The definitions in code are `RemoteApprovalRecordType`, `RemoteApprovalRecordField`,
`RemoteApprovalRecordName`, and the value types in
`SecChainCore/Sources/SecChainCore/RemoteApprovalRecords.swift`. This document explains them; the
code is what both front ends compile against.

## Layout version

Every record carries `schemaVersion`, currently `1`, matching the `v1` in
`RemoteApproval.signedMessagePrefix`. A device that reads another version refuses the record
instead of guessing what the fields mean. The version changes when a field changes meaning or the
signed message is laid out differently, which requires both front ends to ship the new version:
until then, every approval of the new layout fails verification on the old one.

## Record types

### `ApprovalRequest` — written by the Mac, read by the iPhone

One authentication a Mac asks the iPhone to answer.

| Field | CloudKit type | Meaning |
| --- | --- | --- |
| `schemaVersion` | Int64 | Layout version of this record |
| `requestIdentifier` | String | UUID of the request, the same one the record name carries |
| `nonce` | Bytes | 32 random bytes chosen for this request only |
| `expiry` | Date/Time | When the Mac stops accepting an approval (2 minutes after it was filed) |
| `repositoryIdentity` | String | Repository whose secrets the command reads |
| `secretNames` | List of String | Names of the secrets, never their values |
| `commandArguments` | List of String | The command the user is about to run, word by word |
| `requestingDeviceName` | String | Name of the Mac, so that the user can tell where the request came from |

Record name: `approval-request-<requestIdentifier>`.

`commandArguments` is what the user typed after `--`, or the operation for an update or a delete
(`["set", "API_TOKEN"]`, `["delete", "API_TOKEN"]`). It never contains a secret value: `secchain`
refuses a value given as an argument and reads one from standard input instead.

### `ApprovalDecision` — written by the iPhone, read by the Mac

The answer to one request. The Mac polls for it by record name, which it derives from the request
identifier, because a command-line process cannot receive pushes.

| Field | CloudKit type | Meaning |
| --- | --- | --- |
| `schemaVersion` | Int64 | Layout version of this record |
| `requestIdentifier` | String | UUID of the request this answers |
| `outcome` | String | `approved` or `rejected` |
| `signature` | Bytes | The approval signature (P-256 ECDSA, raw representation). Absent for a rejection |

Record name: `approval-decision-<requestIdentifier>`.

An approval **is** the signature. `outcome = approved` without a signature, or with a signature
made by another key or over another request, is what a record written by anything but the paired
iPhone looks like, and the Mac refuses it (`RemoteApproval.verify`). A `rejected` record is
accepted without a signature: a process that could forge one could also kill the command, so
refusing to read is not a privilege it gains.

Approval and rejection share one record type so that the Mac fetches one record per poll instead of
two, and so that the production schema, whose record types cannot be deleted once deployed, carries
one type less.

### `ApprovalCancellation` — written by the Mac, read by the iPhone

The Mac's notice that it has stopped waiting (the user pressed Ctrl-C), so that the iPhone stops
offering the request.

| Field | CloudKit type | Meaning |
| --- | --- | --- |
| `schemaVersion` | Int64 | Layout version of this record |
| `requestIdentifier` | String | UUID of the request that is no longer waited for |

Record name: `approval-cancellation-<requestIdentifier>`.

It is a record of its own rather than a field of `ApprovalDecision`, because the Mac and the iPhone
would otherwise write the same record at the same moment and one of the two writes would be lost.

### `DevicePairing` — written by the iPhone, read by the Mac

The public key of an iPhone's approval key, published so that a Mac can enroll it.

| Field | CloudKit type | Meaning |
| --- | --- | --- |
| `schemaVersion` | Int64 | Layout version of this record |
| `publicKey` | Bytes | P-256 public key in X9.63 representation |
| `deviceName` | String | Name of the iPhone, so that the user recognizes it |

Record name: `device-pairing-<first 8 bytes of SHA-256(publicKey), as hex>`. Publishing the same
key twice therefore leaves one record, and a new key never overwrites the record of the old one.

The private key stays in the iPhone's Secure Enclave with the access control `.privateKeyUsage`
and `.biometryAny`; it is never published, exported, or backed up.

## Lifetime of the records

1. The Mac writes `ApprovalRequest` and starts fetching `ApprovalDecision` every 2 seconds.
2. The iPhone learns about the request from a `CKQuerySubscription` on `ApprovalRequest`, and also
   queries for open requests when it launches and when a notification arrives, because a
   notification can be coalesced or dropped.
3. The user approves or rejects; the iPhone writes `ApprovalDecision`.
4. The Mac verifies the answer against **its own copy** of the request and the key it enrolled, and
   then deletes the request and the answer, so that the iPhone stops offering an answered request.
5. If the user presses Ctrl-C first, the Mac writes `ApprovalCancellation` and leaves the request in
   place, because the cancellation refers to it.
6. If nothing answers, the request expires after 2 minutes and the Mac deletes it.

Every record read from the private database is a claim, not a fact: any process running as the user
can write there, and that process is exactly the actor the *confirm* level exists to stop. The Mac
verifies against what it holds itself.

### A query is a couple of seconds behind

A fetch by record name reads the record; a `CKQuery` reads an index CloudKit updates asynchronously.
Measured, a record saved a moment earlier appeared in a query after 2 seconds
(`documents/PROJECT.md`, "Remote approval, while it was built"). Two consequences:

- The Mac polls for the answer by **record name**, never with a query, which is why it sees an
  approval as soon as the iPhone has written it.
- The iPhone's query for open requests can be behind the notification that told it about one. A
  request named by a notification is fetched by identifier (`request(requestIdentifier:)`); the
  query is the backup for notifications that were coalesced or dropped, and it catches up on its
  own within seconds.

### Who deletes a record

Nothing expires by itself in CloudKit, and a request that nobody removes stays in the user's
database forever. Each record therefore has one device that is responsible for removing it, and the
rule is the same for all of them: **the device that can no longer be waiting for the record deletes
it.**

| Situation | Who deletes | What is deleted | When |
| --- | --- | --- | --- |
| The Mac learns the outcome: approved, rejected, expired, or an answer it refused | The Mac | The request, the answer, and any cancellation of it | Before the command starts, or before the error is reported |
| The user pressed Ctrl-C on the Mac | The iPhone | The request, its cancellation, and any answer | When the iPhone acts on the cancellation — it stops offering the request, and removes the three records. Nothing has to be shown first: a cancelled request is simply gone |
| The Mac was killed while waiting (SIGKILL, a closed lid, a lost power cable), so it wrote neither an answer nor a cancellation | The iPhone | The request and any answer or cancellation of it | Whenever the iPhone queries `ApprovalRequest` (at launch, on a notification) and finds a request whose `expiry` has passed. The iPhone never offers such a request |
| The same, but the iOS app is not opened for a long time | The Mac | The requests that carry this Mac's `requestingDeviceName` and whose `expiry` has passed | Before the Mac files its next request (`RemoteApprovalSession.forgetExpiredRequests`) |
| A device published a new approval key | The iPhone that published the old one | Its own `DevicePairing` record | When it publishes the new key |

Two rules keep this safe:

- **Only an expired request is removed by the device that did not file it.** A Mac deletes another
  device's request only after its `expiry` has passed, which is the moment after which no device may
  act on it anyway; two Macs that happen to share a name cannot remove each other's open requests.
- **Nobody but the publishing iPhone removes a `DevicePairing` record.** A Mac that is paired holds
  its own copy of the public key, so removing the published record does not unpair anything, but
  removing someone else's published key would stop another Mac from pairing.

Deleting a record that is already gone succeeds, so every one of these steps can be repeated without
checking first.

## The signed message

`RemoteApproval.signedMessage(request:)` is the byte string the iPhone signs and the Mac verifies:

```
"SecChain remote approval v1\n"
requestIdentifier          (16 bytes, the UUID as it is laid out in memory)
nonce                      (4-byte big-endian length, then the bytes)
expiry                     (8 bytes, big-endian Int64, whole seconds since 1970)
contentDigest              (4-byte big-endian length, then 32 bytes)
```

`contentDigest` is `SHA-256` over the length-prefixed concatenation of the repository identity, the
sorted secret names, the command arguments, and the requesting device name — that is, over what the
iPhone showed the user. Every field is preceded by its length so that bytes cannot move from one
field into the next without changing the result. Secret names are sorted because the order a
command lists them in does not change what is approved.

The expiry is signed in whole seconds because CloudKit stores dates with millisecond precision and
both sides have to produce the same bytes from their own copy of the request.

## Pairing number

Both screens show a 12-digit number in three groups of four, derived from the first 8 bytes of
`SHA-256(publicKey)` (`RemoteApprovalPairing.verificationNumber`). The user compares the two before
the Mac enrolls the key. 12 digits is a compromise: the number has to be read out by a person,
while being long enough that generating key pairs until one of them produces the number of the
user's own phone is expensive — a P-256 key pair plus a SHA-256 costs tens of microseconds, so six
digits would be matched in seconds.

## Deploying the schema to production

Developer ID and App Store builds can only use the production environment of the container, where a
record type exists only after the schema has been deployed from the development environment in the
CloudKit Console (`documents/PROJECT.md`, "Remote approval spike"). Which types have to be deployed,
what to check before deploying, and how to verify it afterwards are in
`documents/cloudkit-production-schema.md`.
