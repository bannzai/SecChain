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
CloudKit Console (`documents/PROJECT.md`, "Remote approval spike"). Deployed record types cannot be
deleted, which is why `secchain doctor --cloudkit` exercises these four record types instead of a
type of its own.

Before deploying (issue #16):

- Run `make test-integration` on a Mac signed in to iCloud with a build signed by the team. It
  creates every record type above, with every field populated, in the **development** environment,
  which is what the console deploys from.
- `ApprovalRequest` needs a queryable index so that the iOS app can query for open requests, and
  `DevicePairing` needs one so that a Mac can list published keys. Both queries filter on
  `schemaVersion`, a field of every record, rather than on the system `recordName`, which is not
  indexed unless someone marks it in the console.
- `ApprovalRequest` also needs the subscription the iOS app installs on it.
