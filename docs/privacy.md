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

- The Service does not collect, transmit, or sell any information about you.
- Secret values stay in the Keychain of your devices. When you choose to synchronize a secret, Apple's iCloud Keychain carries it between your devices with end-to-end encryption. The Provider cannot read it.
- The Service contains no analytics, advertising, crash reporting, or tracking, and it does not require an account.

## Information the Service Handles on Your Devices

### Secrets you store

Secret names, secret values, protection levels, and repository identifiers are stored in the data protection keychain of the device on which you enter them. They are never written to other files, logs, or servers operated by the Provider.

When a secret is set to synchronize, the Keychain of your operating system synchronizes it through iCloud Keychain to your other devices signed in with the same Apple Account. This synchronization is provided by Apple Inc. and is end-to-end encrypted: neither the Provider nor Apple can read the values. Apple's handling of iCloud data is described in Apple's privacy policy (https://www.apple.com/legal/privacy/). Secrets set to "This device only" or "Device-bound" never leave the device.

### Repository files

The `.secchain` file that the command-line tool can write into a repository contains secret names and an optional repository identifier, never secret values. It stays in your repository and is shared only where you share that repository.

### Authentication

Face ID, Touch ID, Apple Watch, and password prompts are shown and evaluated by the operating system. The Service only learns whether authentication succeeded; it never receives biometric data.

### Clipboard

When you copy a revealed value, it is placed on the clipboard marked as concealed so that clipboard managers skip it. On iPhone and iPad the copy stays on the device and expires after one minute.

## Information the Provider Collects

The Provider collects no information through the Service. If you contact the Provider by email or through GitHub, the Provider uses your contact information and the content of your message only to respond to you.

## Provision to Third Parties

The Provider does not hold user information and therefore does not provide it to third parties. Information in your inquiry is not provided to third parties except where required by law.

## Deleting Your Data

All data of the Service is stored on your devices. Delete a secret in the app or with `secchain delete` to remove it from the Keychain; a synchronized secret is removed from all of your devices. Keychain items can remain on a device after the app is removed, so delete your secrets in the app before removing it.

## Contact

For questions about this Policy or the handling of your information, contact:

- bannzai.app@gmail.com

## Changes to This Policy

The Provider may update this Policy. The current version is always published at this address, and its history is available in the source repository (https://github.com/bannzai/SecChain).

Effective date: September 17, 2026
