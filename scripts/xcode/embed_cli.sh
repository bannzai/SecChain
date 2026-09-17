#!/bin/bash
# Build phase of the SecChain macOS target: packages the `secchain` command-line tool as a minimal
# bundle at SecChain.app/Contents/Helpers/secchain.app and signs it with the app's identity.
#
# Why a bundle and not a bare executable: `keychain-access-groups` is a restricted entitlement
# that must be authorized by a provisioning profile, and a bare executable has nowhere to embed
# one. A bare executable signed with that entitlement is killed at launch.
# (documents/PROJECT.md, design decision 2)
#
# This phase runs on every build. Every step overwrites its output, so re-running converges to
# the same result (idempotent).
set -euo pipefail

HELPER_APP="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/secchain.app"
mkdir -p "${HELPER_APP}/Contents/MacOS"

# The SwiftPM product is `secchain-cli` (see SecChainCore/Package.swift); users get `secchain`.
cp -f "${BUILT_PRODUCTS_DIR}/secchain-cli" "${HELPER_APP}/Contents/MacOS/secchain"
cp -f "${SRCROOT}/SecChainCLISupport/Info.plist" "${HELPER_APP}/Contents/Info.plist"

# A profile left over from a previous build would be sealed into a build that is signed without
# one (for example ad-hoc signing in CI), so it is always removed before copying the current one.
rm -f "${HELPER_APP}/Contents/embedded.provisionprofile"
APP_PROFILE="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/embedded.provisionprofile"
if [ -f "${APP_PROFILE}" ]; then
  cp -f "${APP_PROFILE}" "${HELPER_APP}/Contents/embedded.provisionprofile"
fi

# CloudKit refuses a client without com.apple.application-identifier ("Trying to initialize a
# container without an application ID"), and the value must match the embedded profile. A development
# build embeds the app's profile, so the tool uses the app's identifier. The Developer ID export
# replaces that profile with the tool's own and fails unless the archive already signed the tool with
# the tool's identifier, which scripts/macos/export_developer_id.sh passes as CLI_APPLICATION_IDENTIFIER.
CLI_ENTITLEMENTS="${DERIVED_FILE_DIR}/secchain.entitlements"
mkdir -p "${DERIVED_FILE_DIR}"
cp -f "${SRCROOT}/SecChainCLISupport/secchain.entitlements" "${CLI_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${CLI_APPLICATION_IDENTIFIER:-${DEVELOPMENT_TEAM}.${PRODUCT_BUNDLE_IDENTIFIER}}" "${CLI_ENTITLEMENTS}"

# Without a signing identity (CI, contributors without a team) fall back to ad-hoc signing so the
# build still succeeds. An ad-hoc signed tool cannot use the shared access group; it reports a
# code-signing error at run time instead of reading secrets.
codesign --force --options runtime \
  --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "${CLI_ENTITLEMENTS}" \
  "${HELPER_APP}"
