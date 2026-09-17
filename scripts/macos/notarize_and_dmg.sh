#!/bin/bash
# Packages the exported app into a DMG, signs the DMG, notarizes it, staples the ticket to it, and
# checks the result the way Gatekeeper does.
#
# The DMG is submitted once: notarizing a disk image also covers the app and the command-line tool
# inside it. Only the DMG gets a stapled ticket, because the app inside a read-only image cannot be
# changed; Gatekeeper looks up the app's ticket online when the copied app is first opened.
#
# Idempotent: the staging directory and the DMG are recreated on every run.
#
# Requires ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID, and ASC_API_KEY_P8_BASE64. Runs after
# export_developer_id.sh.
set -euo pipefail
source "$(dirname "$0")/_developer_id_common.sh"

require_commands codesign ditto hdiutil jq plutil security shasum spctl xcrun
require_asc_api_key
if [ ! -d "${EXPORTED_APP}" ]; then
  echo "Error: ${EXPORTED_APP} does not exist; run scripts/macos/export_developer_id.sh first" >&2
  exit 2
fi
write_asc_api_key_file

VERSION="$(plutil -extract CFBundleShortVersionString raw "${EXPORTED_APP}/Contents/Info.plist")"
DMG_PATH="${DISTRIBUTION_DIRECTORY}/SecChain-${VERSION}.dmg"
STAGING_DIRECTORY="${DISTRIBUTION_DIRECTORY}/dmg"
NOTARIZATION_RESULT="${DISTRIBUTION_DIRECTORY}/notarization.json"

# The DMG is signed with a Developer ID Application identity of the team that signed the app. The
# identity is passed by its hash because a name is ambiguous while a renewed certificate and the
# previous one are both valid.
TEAM_IDENTIFIER="$(codesign --display --verbose=2 "${EXPORTED_APP}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
  | awk -v team="(${TEAM_IDENTIFIER})\"" '/"Developer ID Application: / && index($0, team) { print $2; exit }')"
if [ -z "${SIGNING_IDENTITY}" ]; then
  echo "Error: no Developer ID Application identity of team ${TEAM_IDENTIFIER} in the keychain search list" >&2
  exit 1
fi

rm -rf "${STAGING_DIRECTORY}" "${DMG_PATH}"
mkdir -p "${STAGING_DIRECTORY}"
ditto "${EXPORTED_APP}" "${STAGING_DIRECTORY}/SecChain.app"
# Lets people install by dragging the app onto the link in the opened DMG.
ln -s /Applications "${STAGING_DIRECTORY}/Applications"
hdiutil create -volname SecChain -srcfolder "${STAGING_DIRECTORY}" -format UDZO "${DMG_PATH}"
# Gatekeeper's assessment of a disk image checks the image's own signature.
codesign --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"

submission_status=0
xcrun notarytool submit "${DMG_PATH}" \
  --key "${ASC_API_KEY_PATH}" --key-id "${ASC_API_KEY_ID}" --issuer "${ASC_API_KEY_ISSUER_ID}" \
  --wait --output-format json > "${NOTARIZATION_RESULT}" || submission_status=$?
cat "${NOTARIZATION_RESULT}"
echo
if [ "${submission_status}" -ne 0 ] || [ "$(jq -r '.status // empty' "${NOTARIZATION_RESULT}")" != "Accepted" ]; then
  echo "Error: notarization was not accepted (notarytool exited with ${submission_status})" >&2
  submission_id="$(jq -r '.id // empty' "${NOTARIZATION_RESULT}" 2> /dev/null || true)"
  if [ -n "${submission_id}" ]; then
    # The log names each file that was rejected and the reason.
    xcrun notarytool log "${submission_id}" \
      --key "${ASC_API_KEY_PATH}" --key-id "${ASC_API_KEY_ID}" --issuer "${ASC_API_KEY_ISSUER_ID}" >&2 || true
  fi
  exit 1
fi

xcrun stapler staple "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type execute --verbose=2 "${EXPORTED_APP}"
shasum -a 256 "${DMG_PATH}"
