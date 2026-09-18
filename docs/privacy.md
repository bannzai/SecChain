---
layout: legal
title: Privacy Policy
# The landing page links to ./privacy/ and App Store Connect stores the same URL, so the page is
# published as a directory index instead of privacy.html, which would only answer /privacy.
permalink: /privacy/
---

# Privacy Policy

bannzai (the "Provider") establishes this Privacy Policy (this "Policy") for SecChain for macOS, SecChain for iOS and iPadOS, and the `secchain` command-line tool (together, the "Service").

## Summary

- The Service does not collect or sell any information about you. The Provider operates no server, so nothing you do in the Service reaches the Provider.
- Secret values stay in the Keychain of your devices. When you choose to synchronize a secret, Apple's iCloud Keychain carries it between your devices with end-to-end encryption. The Provider cannot read it.
- If you turn on remote approval, what leaves a device goes to your own iCloud account and nowhere else. It never contains a secret value, and the Provider cannot read it.
- The Service contains no analytics, advertising, crash reporting, or tracking, and it does not require an account.

## Information the Service Handles on Your Devices

### Secrets you store

Secret names, secret values, protection levels, and repository identifiers are stored in the data protection keychain of the device on which you enter them. They are never written to other files, logs, or servers operated by the Provider.

When a secret is set to synchronize, the Keychain of your operating system synchronizes it through iCloud Keychain to your other devices signed in with the same Apple Account. This synchronization is provided by Apple Inc. and is end-to-end encrypted: neither the Provider nor Apple can read the values. Apple's handling of iCloud data is described in Apple's privacy policy (https://www.apple.com/legal/privacy/). Secrets set to "This device only" or "Device-bound" never leave the device.

### Repository files

The `.secchain` file that the command-line tool can write into a repository contains secret names and an optional repository identifier, never secret values. It stays in your repository and is shared only where you share that repository.

### Authentication

Face ID, Touch ID, Apple Watch, and password prompts are shown and evaluated by the operating system. The Service only learns whether authentication succeeded; it never receives biometric data.

### Remote approval

Remote approval lets the authentication that a "Confirm" secret asks for on a Mac be answered on your iPhone. It does nothing until you pair a Mac with an iPhone yourself.

Once you do, the request travels through the private database of your own iCloud account (Apple's CloudKit), never through a server of the Provider, which does not exist. What these records contain is the name of the Mac that asks, the repository identifier, the names of the secrets the command reads, the command and its arguments, a random value and an expiry belonging to that one request, the approval signature or the rejection, and, for pairing, the public key of your iPhone and its name. **No stored secret value is part of any of them.** The command is recorded as you typed it, and SecChain never puts a value it stores into it. The private key that signs an approval is created in the Secure Enclave of your iPhone and never leaves it.

Apple states that only you can access your private database and that its contents are not visible to a developer (https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase). The Provider can therefore neither read these records nor tell that you use remote approval.

The notification your iPhone shows says only that a Mac is asking for your approval and carries no part of the request. Notifications are delivered by Apple; the Provider receives no device token, again because it operates no server.

### Clipboard

When you copy a revealed value, it is placed on the clipboard marked as concealed so that clipboard managers skip it. On iPhone and iPad the copy stays on the device and expires after one minute.

## Information the Provider Collects

The Provider collects no information through the Service, including when you use remote approval: those records are in your iCloud account, which the Provider cannot access. If you contact the Provider by email or through GitHub, the Provider uses your contact information and the content of your message only to respond to you.

## Provision to Third Parties

The Provider does not hold user information and therefore does not provide it to third parties. Information in your inquiry is not provided to third parties except where required by law.

## Deleting Your Data

All data of the Service is stored on your devices, except for the remote approval records in your own iCloud account. Delete a secret in the app or with `secchain delete` to remove it from the Keychain; a synchronized secret is removed from all of your devices. Keychain items can remain on a device after the app is removed, so delete your secrets in the app before removing it.

Remote approval records are removed by your own devices: the Mac removes a request and its answer as soon as it knows the outcome, and the iPhone removes a request that was cancelled or has expired. "Remove Pairing" on the iPhone withdraws its published key, and `secchain pair remove` makes a Mac forget the key it enrolled.

## Contact

For questions about this Policy or the handling of your information, contact:

- bannzai.app@gmail.com

## Changes to This Policy

The Provider may update this Policy. The current version is always published at this address, and its history is available in the source repository (https://github.com/bannzai/SecChain).

Effective date: September 18, 2026
