# macOS distribution

The macOS app, including the embedded `secchain` command-line tool, is distributed outside the Mac App Store: it is signed with a Developer ID certificate, notarized, published as a DMG on GitHub Releases, and installed through a Homebrew cask. The reasons are in [PROJECT.md](PROJECT.md), design decisions 2 and 3.

```text
make dmg
├── scripts/macos/create_developer_id_profiles.sh  bundle identifiers and Developer ID profiles (App Store Connect API)
├── scripts/macos/export_developer_id.sh           Release archive, Developer ID export, signature checks
└── scripts/macos/notarize_and_dmg.sh              DMG, notarization, stapling, Gatekeeper checks
      │
      ▼
tmp/distribution/SecChain-<version>.dmg
      │  version tag pushed: .github/workflows/release.yml runs make dmg on a GitHub runner
      ▼
GitHub release with SecChain-<version>.dmg and secchain.rb (Casks/secchain.rb with the version and checksum filled in)
      │  secchain.rb copied to bannzai/homebrew-tap
      ▼
brew install --cask bannzai/tap/secchain
```

Why each script signs the way it does is explained in the comments at the top of the script.

## Prerequisites

1. A Developer ID Application certificate of the team, with its private key, in the keychain of the Mac that builds. Only the Account Holder can create one (https://developer.apple.com/account/resources/certificates/add). Check with:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. An App Store Connect team API key (https://appstoreconnect.apple.com/access/integrations/api), exported as environment variables:

   | Variable | Value |
   | --- | --- |
   | `ASC_API_KEY_ID` | Key ID |
   | `ASC_API_KEY_ISSUER_ID` | Issuer ID |
   | `ASC_API_KEY_P8_BASE64` | The downloaded `AuthKey_<Key ID>.p8`, base64-encoded (`base64 -i AuthKey_<Key ID>.p8`) |

   The key authenticates notarization and the requests that register bundle identifiers and create profiles. When the key's role does not allow a request, the script stops and prints Apple's error response.

The team and the app's bundle identifier are read from `SecChain.xcodeproj`, and the tool's bundle identifier from `SecChainCLISupport/Info.plist`. A fork builds with its own team after changing those values and the access group.

## Building a DMG

```sh
make dmg
```

The result is `tmp/distribution/SecChain-<version>.dmg`, where the version is `MARKETING_VERSION` of the app. The last steps print the checks it passed and the DMG's SHA-256:

```sh
spctl --assess --type open --context context:primary-signature --verbose=2 tmp/distribution/SecChain-<version>.dmg
xcrun stapler validate tmp/distribution/SecChain-<version>.dmg
spctl --assess --type execute --verbose=2 tmp/distribution/export/SecChain.app
```

`make dmg` changes state outside the repository:

- On the first run, it registers the bundle identifiers `com.bannzai.SecChain` and `com.bannzai.SecChain.cli` and creates the profiles "SecChain Developer ID" and "SecChain CLI Developer ID" in the team's developer account. Later runs reuse them.
- It installs both profiles as `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.provisionprofile`, where `xcodebuild -exportArchive` looks them up by name.
- It uploads the DMG to Apple's notary service.

To see what someone who downloads the DMG sees, mark it as downloaded and open it. Gatekeeper must open it without a warning:

```sh
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" tmp/distribution/SecChain-<version>.dmg
open tmp/distribution/SecChain-<version>.dmg
```

## Releasing

### Repository secrets

`.github/workflows/release.yml` reads these secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | The Developer ID Application certificate and its private key exported as a `.p12` file, base64-encoded |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | The password chosen when exporting the `.p12` file |
| `ASC_API_KEY_ID` | Same as the environment variable |
| `ASC_API_KEY_ISSUER_ID` | Same as the environment variable |
| `ASC_API_KEY_P8_BASE64` | Same as the environment variable |

Export the `.p12` file from Keychain Access: in the login keychain, open My Certificates, select "Developer ID Application: … (TQPN82UBBY)", and choose File > Export Items. `security export` is not an alternative because it exports every identity in the keychain. Then register the secrets and delete the exported file:

```sh
base64 -i DeveloperIDApplication.p12 | gh secret set DEVELOPER_ID_APPLICATION_P12_BASE64 -R bannzai/SecChain
gh secret set DEVELOPER_ID_APPLICATION_P12_PASSWORD -R bannzai/SecChain  # prompts for the value
test -n "$ASC_API_KEY_ID" && printf '%s' "$ASC_API_KEY_ID" | gh secret set ASC_API_KEY_ID -R bannzai/SecChain
test -n "$ASC_API_KEY_ISSUER_ID" && printf '%s' "$ASC_API_KEY_ISSUER_ID" | gh secret set ASC_API_KEY_ISSUER_ID -R bannzai/SecChain
test -n "$ASC_API_KEY_P8_BASE64" && printf '%s' "$ASC_API_KEY_P8_BASE64" | gh secret set ASC_API_KEY_P8_BASE64 -R bannzai/SecChain
```

### Publishing a version

1. Set the version in `MARKETING_VERSION` of the project. The command-line tool declares its version separately, in `CFBundleShortVersionString` of `SecChainCLISupport/Info.plist` and in `version` of `SecChainCore/Sources/SecChainCLI/SecChain.swift`; keep them equal.
2. Push a tag named after the version. The workflow fails before building when the tag and `MARKETING_VERSION` differ.

   ```sh
   git tag v<version>
   git push origin v<version>
   ```

3. The workflow runs `make dmg` and publishes the release with `SecChain-<version>.dmg` and `secchain.rb`. Running it again for the same tag replaces both assets.

### Updating the Homebrew tap

The cask lives in https://github.com/bannzai/homebrew-tap. `Casks/secchain.rb` in this repository is its source; the copy attached to each release has the real version and checksum. In a checkout of the tap:

```sh
gh release download v<version> -R bannzai/SecChain -p secchain.rb -D Casks --clobber
git add Casks/secchain.rb
git commit -m "secchain <version>"
git push
```

The tap's audit workflow (`.github/workflows/audit.yml`) runs `brew audit` for each cask it names; add `bannzai/tap/secchain` to it when the cask is first added.

People install the app, and `secchain` on their `PATH`, with:

```sh
brew install --cask bannzai/tap/secchain
```

Installing with the fully qualified name trusts this cask only (https://docs.brew.sh/Tap-Trust).

## Troubleshooting

- **The export reports that a profile does not include the signing certificate.** The certificate was issued after the profile was created. Delete the profile at https://developer.apple.com/account/resources/profiles/list and run `make dmg` again; the script creates a new one that lists every valid certificate.
- **Notarization is not accepted.** `notarize_and_dmg.sh` prints the notary log, which names every rejected file and the reason.
- **`codesign` cannot find the identity on a CI runner.** Check that `DEVELOPER_ID_APPLICATION_P12_BASE64` contains the private key: a `.p12` exported from the certificate alone does not.
