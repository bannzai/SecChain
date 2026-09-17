#!/bin/bash
# Archives the Release build of the app and exports it signed with the Developer ID Application
# certificate and the profiles that create_developer_id_profiles.sh installs.
#
# Both the archive and the export use manual signing, so neither an Apple Development certificate,
# a registered Mac, nor cloud signing is involved: the same commands run on a developer's Mac and on
# a CI runner whose keychain holds only the Developer ID certificate.
#
# Idempotent: the previous archive and export are replaced.
set -euo pipefail
source "$(dirname "$0")/_developer_id_common.sh"

require_commands xcodebuild codesign security plutil jq
read_app_build_settings
DEVELOPMENT_TEAM="$(app_build_setting DEVELOPMENT_TEAM)"
APP_BUNDLE_IDENTIFIER="$(app_build_setting PRODUCT_BUNDLE_IDENTIFIER)"
CLI_BUNDLE_IDENTIFIER="$(cli_bundle_identifier)"
EXPORT_OPTIONS="${DISTRIBUTION_DIRECTORY}/ExportOptions.plist"
CLOUDKIT_CONTAINER_IDENTIFIER="$(plutil -convert json -o - SecChainCLISupport/secchain.entitlements | jq -er '.["com.apple.developer.icloud-container-identifiers"][0]')"

# Fails unless the bundle is signed by the team's Developer ID Application identity with the hardened
# runtime, which notarization requires, embeds the named profile, which authorizes the bundle's
# keychain-access-groups and iCloud entitlements, and names the CloudKit container in its production
# environment (a Developer ID profile allows no other environment).
verify_exported_bundle() {
  local bundle_path="$1" profile_name="$2" signature embedded_profile_name entitlements
  codesign --verify --strict --verbose=2 "${bundle_path}"
  entitlements="$(codesign --display --entitlements - --xml "${bundle_path}" 2>/dev/null | plutil -convert json -o - -)"
  if ! jq -e --arg container "${CLOUDKIT_CONTAINER_IDENTIFIER}" \
    '(.["com.apple.developer.icloud-container-identifiers"] | index($container)) != null and .["com.apple.developer.icloud-container-environment"] == "Production"' \
    <<< "${entitlements}" > /dev/null; then
    echo "Error: ${bundle_path} is not signed for the production environment of ${CLOUDKIT_CONTAINER_IDENTIFIER}" >&2
    echo "${entitlements}" >&2
    exit 1
  fi
  signature="$(codesign --display --verbose=2 "${bundle_path}" 2>&1)"
  if ! grep -q "^Authority=Developer ID Application: .*(${DEVELOPMENT_TEAM})$" <<< "${signature}"; then
    echo "Error: ${bundle_path} is not signed with the Developer ID Application identity of ${DEVELOPMENT_TEAM}" >&2
    exit 1
  fi
  if ! grep -q '^CodeDirectory .*(runtime)' <<< "${signature}"; then
    echo "Error: ${bundle_path} is not signed with the hardened runtime" >&2
    exit 1
  fi
  embedded_profile_name="$(security cms -D -i "${bundle_path}/Contents/embedded.provisionprofile" | plutil -extract Name raw -o - -)"
  if [ "${embedded_profile_name}" != "${profile_name}" ]; then
    echo "Error: ${bundle_path} embeds the profile \"${embedded_profile_name}\" instead of \"${profile_name}\"" >&2
    exit 1
  fi
  echo "Verified ${bundle_path}: Developer ID Application (${DEVELOPMENT_TEAM}), hardened runtime, profile \"${profile_name}\", CloudKit production environment"
}

rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIRECTORY}"
mkdir -p "${DISTRIBUTION_DIRECTORY}"

# Build settings given on the command line apply to every target, including the Swift package's
# executable, which rejects a provisioning profile. The profile is therefore looked up by target name,
# so that only the app target resolves to one. The team is passed on because package targets do not
# inherit it from the project. CLI_APPLICATION_IDENTIFIER makes the embed build phase sign the tool
# with the identifier of the tool's own profile, which the export checks (scripts/xcode/embed_cli.sh).
xcodebuild -project SecChain.xcodeproj -scheme SecChain -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_DIRECTORY}" \
  -archivePath "${ARCHIVE_PATH}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  PROVISIONING_PROFILE_SPECIFIER='$(DEVELOPER_ID_PROFILE_$(TARGET_NAME))' \
  DEVELOPER_ID_PROFILE_SecChain="${APP_PROFILE_NAME}" \
  CLI_APPLICATION_IDENTIFIER="${DEVELOPMENT_TEAM}.${CLI_BUNDLE_IDENTIFIER}" \
  archive

# The export re-signs every bundle and replaces the app profile that the embed build phase copies into
# the command-line tool with the tool's own profile. iCloudContainerEnvironment sets the
# com.apple.developer.icloud-container-environment entitlement to the only value a Developer ID
# profile allows.
jq -n \
  --arg team "${DEVELOPMENT_TEAM}" \
  --arg app_bundle_identifier "${APP_BUNDLE_IDENTIFIER}" \
  --arg app_profile_name "${APP_PROFILE_NAME}" \
  --arg cli_bundle_identifier "${CLI_BUNDLE_IDENTIFIER}" \
  --arg cli_profile_name "${CLI_PROFILE_NAME}" \
  '{method: "developer-id", teamID: $team, signingStyle: "manual", signingCertificate: "Developer ID Application",
    iCloudContainerEnvironment: "Production",
    provisioningProfiles: {($app_bundle_identifier): $app_profile_name, ($cli_bundle_identifier): $cli_profile_name}}' \
  | plutil -convert xml1 -o "${EXPORT_OPTIONS}" -
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIRECTORY}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}"

verify_exported_bundle "${EXPORTED_APP}/Contents/Helpers/secchain.app" "${CLI_PROFILE_NAME}"
verify_exported_bundle "${EXPORTED_APP}" "${APP_PROFILE_NAME}"
