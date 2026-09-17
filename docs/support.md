# Support

SecChain keeps development secrets in the Keychain of your devices instead of `.env` files. This page answers common questions and tells you how to reach the developer.

## Contact

- Email: bannzai.app@gmail.com
- Bug reports and feature requests: https://github.com/bannzai/SecChain/issues

Never include a secret value in an email or an issue. Describe the secret by its name instead.

## Frequently Asked Questions

### A secret I stored on my Mac does not appear on my iPhone or iPad

Only synchronized secrets reach your other devices. A secret set to "This device only" or "Device-bound" stays on the Mac where it was created. To make a secret available everywhere, change its protection on the Mac to "Standard" or "Confirm" with "Synchronize with iCloud Keychain" turned on.

### Synchronized secrets do not reach my other devices

Synchronization is performed by iCloud Keychain. Check that every device:

- is signed in with the same Apple Account,
- has iCloud Keychain turned on in the Apple Account settings, and
- has SecChain installed from the same developer.

SecChain cannot see whether iCloud Keychain is turned on. When it is off, every secret stays on the device where it was stored and keeps working there.

### The app says "SecChain cannot reach its Keychain items"

The running copy of SecChain is not signed with the developer's Keychain access group, so the system refuses access to its items. Install SecChain from the App Store on iPhone and iPad, or from the official release on the Mac. A copy built from the source code with a different signing team cannot read the secrets of the official app.

### Revealing a value asks for Face ID, Touch ID, or my password

Showing a value on screen always requires authentication, whatever the protection level, so that a value is never displayed by accident. If your device has no passcode or password set, authentication is not available and values cannot be revealed.

### How do I delete my data?

Delete each secret in the app. A synchronized secret is deleted on all of your devices. Keychain items can remain on a device after the app is removed, so delete your secrets before removing the app.

## Privacy

SecChain collects no information. See the [Privacy Policy](./privacy).
