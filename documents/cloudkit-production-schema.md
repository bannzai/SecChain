# Deploying the remote approval schema to production

Remote approval carries its requests and answers as CloudKit records in the private database of the
container `iCloud.com.bannzai.SecChain` (`documents/PROJECT.md`, design decision 5). A record type
exists in the **production** environment of a container only after the schema has been deployed
there from the development environment, and the builds that are distributed can use nothing else: a
Developer ID profile allows only `com.apple.developer.icloud-container-environment` = `Production`,
and an App Store build of the iOS app is production too.

Until the schema is deployed, every remote approval fails on a released build. Deploying is done in
the CloudKit Console, which is a person's step rather than an agent's, and it is tracked in the list
of the maintainer's tasks (https://github.com/bannzai/SecChain/issues/16). This document says what
has to be there, what to check before pressing the button, and how to tell afterwards that it
worked.

## What the production schema needs

| Record type | Written by | Read by | What it is |
| --- | --- | --- | --- |
| `ApprovalRequest` | the Mac | the iPhone | The authentication a Mac asks the iPhone to answer |
| `ApprovalDecision` | the iPhone | the Mac | The approval, which is a signature, or the rejection |
| `ApprovalCancellation` | the Mac | the iPhone | The Mac has stopped waiting, so the request can be dropped |
| `DevicePairing` | the iPhone | the Mac | The public key of the iPhone, published so that a Mac can enroll it |

The fields of each type, the record names, and what is signed are in
`documents/remote-approval-records.md`, which stays the source of truth for the layout; this
document only lists which types have to exist in production.

The doctor has no record type of its own: a deployed record type cannot be deleted again, so
`secchain doctor --cloudkit` exercises these four instead (`documents/PROJECT.md`, design
decision 5).

### Indexes

`ApprovalRequest` and `DevicePairing` are read with a `CKQuery` — the iOS app looks for open
requests, and `secchain pair` lists the published keys — and both queries filter on `schemaVersion`,
so that field has to be **queryable** on those two types. `ApprovalDecision` and
`ApprovalCancellation` are only ever fetched by record name, which needs no index, and no query
filters on the system `recordName`, which CloudKit does not index on its own.

Deploying copies the indexes along with the types and their fields ("Deploying the schema copies its
record types, fields, and indexes to the production environment, but doesn't copy any records",
https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema), and in
development both queries return the record that was just saved, with no step in the console —
measured (`documents/PROJECT.md`, "Remote approval, while it was built"), so the development schema
already carries the index that is deployed. Looking at the two indexes before deploying is therefore
a check, not a setup step.

### The notification subscription is not part of the schema

The `CKQuerySubscription` that turns a filed request into a notification is saved by the iOS app at
runtime, into the private database of whoever is signed in (`RemoteApprovalSubscription`). It is not
deployed, and it does not have to be created in the console. It can only be saved once
`ApprovalRequest` exists in that environment: against production, before any deployment, saving it
failed with `CKError` 11, "Did not find record type" (`documents/PROJECT.md`, "Remote approval
spike").

## Before deploying

1. **Create the four record types in the development environment.** Run `make test-integration` on a
   Mac signed in to iCloud, with a build signed by the team. It runs `secchain doctor --cloudkit`,
   which saves and reads back one record of each type with every field populated — including
   `signature`, which only an approval carries — and deletes the records again. A deployment copies
   no records, and the record types and fields it created stay behind, which is what is deployed.
2. **Remove every other record type from the development schema first.** A deployment merges the
   whole development schema into production, and "you can't delete record types or fields that are
   already in production" (Apple's documentation, linked above). The type to look for is
   `DoctorProbe`, which the spike created before the doctor moved to the record types of the
   protocol.
3. **Check the two queryable indexes** described above.

## Deploying

Open https://icloud.developer.apple.com/dashboard/, select the container
`iCloud.com.bannzai.SecChain`, choose **Deploy Schema Changes**, read the list of changes it offers,
and deploy.

## Afterwards

With a build that uses the production environment — a Developer ID build of the macOS app and its
embedded tool, or an App Store or TestFlight build of the iOS app:

- `secchain doctor --cloudkit` passes. Before the deployment, saving a record of a type production
  does not have fails with `CKError` 12, "Cannot create new type … in production schema", which is
  what the spike measured with the doctor's own type.
- On the iPhone, **Remote Approval** shows *Your Macs can find this key* after pairing, and
  **Allow Notifications** installs the subscription without reporting a failure.

Both need a signed build and an Apple Account, so they belong to the pre-release checks rather than
to CI.
