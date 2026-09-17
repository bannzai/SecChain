#!/bin/bash
# Makes sure that the app and the embedded command-line tool each have a Developer ID provisioning
# profile, and installs both where xcodebuild looks them up by name.
#
# Both bundles carry the restricted keychain-access-groups entitlement, which a provisioning profile
# must authorize (documents/PROJECT.md, design decision 2), and a Developer ID export looks up a
# profile for each bundle identifier. The profiles are created through the App Store Connect API
# rather than by Xcode's automatic signing: a Developer ID export with automatic signing needs cloud
# signing, which an API key without the Admin role is not allowed to use.
#
# Idempotent: a registered bundle identifier and an active profile with the expected name are reused,
# and an installed profile is overwritten by the file named after the same UUID.
#
# Requires ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID, and ASC_API_KEY_P8_BASE64.
set -euo pipefail
source "$(dirname "$0")/_developer_id_common.sh"

require_commands curl jq openssl xxd plutil security xcodebuild
require_asc_api_key
write_asc_api_key_file
read_app_build_settings

# Registers the bundle identifier when the team does not have it yet, and stores its resource ID in
# BUNDLE_ID_RESOURCE_ID. UNIVERSAL is the platform the developer website assigns to new identifiers,
# and the app's identifier is shared with the iOS app.
ensure_bundle_id() {
  local bundle_identifier="$1" bundle_id_name="$2"
  BUNDLE_ID_RESOURCE_ID="$(asc_api GET "/v1/bundleIds?filter[identifier]=${bundle_identifier}&fields[bundleIds]=identifier&limit=200" \
    | jq -r --arg identifier "${bundle_identifier}" '[.data[] | select(.attributes.identifier == $identifier)][0].id // empty')"
  if [ -z "${BUNDLE_ID_RESOURCE_ID}" ]; then
    BUNDLE_ID_RESOURCE_ID="$(asc_api POST /v1/bundleIds "$(jq -cn --arg identifier "${bundle_identifier}" --arg name "${bundle_id_name}" \
      '{data: {type: "bundleIds", attributes: {identifier: $identifier, name: $name, platform: "UNIVERSAL"}}}')" \
      | jq -er '.data.id')"
    echo "Registered the bundle identifier ${bundle_identifier}"
  fi
}

# Creates the profile when the bundle identifier has no active profile with the name, then downloads
# the profile and installs it under its UUID.
ensure_profile() {
  local bundle_identifier="$1" bundle_id_name="$2" profile_name="$3"
  local profile_id profile_path profile_uuid
  ensure_bundle_id "${bundle_identifier}" "${bundle_id_name}"
  profile_id="$(asc_api GET "/v1/profiles?filter[profileType]=MAC_APP_DIRECT&filter[name]=$(jq -rn --arg name "${profile_name}" '$name | @uri')&include=bundleId&limit=200" \
    | jq -r --arg bundle_id "${BUNDLE_ID_RESOURCE_ID}" \
      '[.data[] | select(.attributes.profileState == "ACTIVE" and .relationships.bundleId.data.id == $bundle_id)][0].id // empty')"
  if [ -z "${profile_id}" ]; then
    profile_id="$(asc_api POST /v1/profiles "$(jq -cn --arg name "${profile_name}" --arg bundle_id "${BUNDLE_ID_RESOURCE_ID}" --argjson certificates "${DEVELOPER_ID_CERTIFICATES}" \
      '{data: {type: "profiles", attributes: {name: $name, profileType: "MAC_APP_DIRECT"},
        relationships: {bundleId: {data: {type: "bundleIds", id: $bundle_id}}, certificates: {data: $certificates}}}}')" \
      | jq -er '.data.id')"
    echo "Created the profile \"${profile_name}\""
  fi

  profile_path="${DISTRIBUTION_DIRECTORY}/${profile_name}.provisionprofile"
  asc_api GET "/v1/profiles/${profile_id}?fields[profiles]=profileContent" \
    | jq -er '.data.attributes.profileContent' \
    | base64 --decode > "${profile_path}"
  profile_uuid="$(security cms -D -i "${profile_path}" | plutil -extract UUID raw -o - -)"
  cp -f "${profile_path}" "${XCODE_PROFILES_DIRECTORY}/${profile_uuid}.provisionprofile"
  echo "Installed the profile \"${profile_name}\" (${profile_uuid}) for ${bundle_identifier}"
}

mkdir -p "${DISTRIBUTION_DIRECTORY}" "${XCODE_PROFILES_DIRECTORY}"
APP_BUNDLE_IDENTIFIER="$(app_build_setting PRODUCT_BUNDLE_IDENTIFIER)"
CLI_BUNDLE_IDENTIFIER="$(cli_bundle_identifier)"

# A profile lists the certificates allowed to sign with it. Certificates issued by the G2
# intermediate authority have the _G2 type. Expired certificates cannot sign, so they are left out.
DEVELOPER_ID_CERTIFICATES="$(asc_api GET '/v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION,DEVELOPER_ID_APPLICATION_G2&fields[certificates]=expirationDate&limit=200' \
  | jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%S)" '[.data[] | select(.attributes.expirationDate > $now) | {type, id}]')"
if [ "$(jq length <<< "${DEVELOPER_ID_CERTIFICATES}")" -eq 0 ]; then
  echo "Error: the team has no valid Developer ID Application certificate." >&2
  echo "Creating one requires the Account Holder role: https://developer.apple.com/account/resources/certificates/add" >&2
  exit 1
fi

ensure_profile "${APP_BUNDLE_IDENTIFIER}" "SecChain" "${APP_PROFILE_NAME}"
ensure_profile "${CLI_BUNDLE_IDENTIFIER}" "SecChain CLI" "${CLI_PROFILE_NAME}"
