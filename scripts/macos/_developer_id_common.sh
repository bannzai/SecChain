#!/bin/bash
# Definitions shared by the Developer ID distribution scripts in this directory. The scripts source
# this file; it is not run on its own. The procedure is described in documents/macos-distribution.md.

# Paths below are relative to the repository root, so the scripts work from any directory.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Every intermediate and final product stays under tmp/, which Git ignores.
DISTRIBUTION_DIRECTORY="tmp/distribution"
ARCHIVE_PATH="${DISTRIBUTION_DIRECTORY}/SecChain.xcarchive"
EXPORT_DIRECTORY="${DISTRIBUTION_DIRECTORY}/export"
EXPORTED_APP="${EXPORT_DIRECTORY}/SecChain.app"
# Same derived data directory as the Makefile, so that package checkouts are shared with local builds.
DERIVED_DATA_DIRECTORY="tmp/DerivedData"

# The export options refer to the profiles by name, so the names are fixed rather than derived.
APP_PROFILE_NAME="SecChain Developer ID"
CLI_PROFILE_NAME="SecChain CLI Developer ID"

# The directory in which Xcode looks up installed provisioning profiles by name.
XCODE_PROFILES_DIRECTORY="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"

# Exits before any work starts when a command the calling script needs is missing.
require_commands() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "${command_name}" > /dev/null 2>&1; then
      echo "Error: ${command_name} is required" >&2
      exit 2
    fi
  done
}

# Exits when the App Store Connect API key is incomplete. The key authenticates the REST requests
# for bundle identifiers and profiles as well as notarytool. The values are never printed.
require_asc_api_key() {
  local variable_name
  for variable_name in ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID ASC_API_KEY_P8_BASE64; do
    if [ -z "${!variable_name:-}" ]; then
      echo "Error: ${variable_name} is not set (see documents/macos-distribution.md)" >&2
      exit 2
    fi
  done
}

# Decodes the API private key into a directory that only the current user can read and that is
# removed when the script exits. openssl and notarytool read the key from a file, and a key left in
# the working tree could be picked up by any tool that reads the repository.
# Sets ASC_API_KEY_DIRECTORY and ASC_API_KEY_PATH.
write_asc_api_key_file() {
  ASC_API_KEY_DIRECTORY="$(mktemp -d)"
  trap 'rm -rf "${ASC_API_KEY_DIRECTORY}"' EXIT
  ASC_API_KEY_PATH="${ASC_API_KEY_DIRECTORY}/AuthKey_${ASC_API_KEY_ID}.p8"
  (umask 077 && printf '%s' "${ASC_API_KEY_P8_BASE64}" | base64 --decode > "${ASC_API_KEY_PATH}")
}

# Encodes standard input as base64url without padding (RFC 7515, section 2).
base64url() {
  base64 | tr -d '\n=' | tr '+/' '-_'
}

# Prints a token for one App Store Connect API request.
# openssl writes an ECDSA signature as an ASN.1 DER sequence of two integers, while ES256 expects
# both integers as 32-byte big-endian values, concatenated (RFC 7518, section 3.4).
# Callers use this function in a command substitution, where bash 3.2 (/bin/bash on macOS) does not
# apply `set -e`, so every step returns on failure explicitly.
asc_api_token() {
  local issued_at header payload signature
  issued_at="$(date +%s)" || return 1
  header="$(printf '%s' "$(jq -cn --arg key_id "${ASC_API_KEY_ID}" '{alg: "ES256", kid: $key_id, typ: "JWT"}')" | base64url)" || return 1
  # Every request signs a new token, so a short lifetime is enough; Apple rejects tokens that live
  # longer than 20 minutes.
  payload="$(printf '%s' "$(jq -cn --arg issuer_id "${ASC_API_KEY_ISSUER_ID}" --argjson issued_at "${issued_at}" \
    '{iss: $issuer_id, iat: $issued_at, exp: ($issued_at + 600), aud: "appstoreconnect-v1"}')" | base64url)" || return 1
  signature="$(printf '%s.%s' "${header}" "${payload}" \
    | openssl dgst -sha256 -sign "${ASC_API_KEY_PATH}" -binary \
    | openssl asn1parse -inform DER \
    | awk -F: '/INTEGER/ { printf "%64s", $NF }' \
    | tr ' ' 0 \
    | xxd -r -p \
    | base64url)" || return 1
  printf '%s.%s.%s' "${header}" "${payload}" "${signature}"
}

# Sends one App Store Connect API request and prints the response body. For a status outside 2xx it
# prints Apple's error document, which names the missing permission or the rejected attribute, and
# fails. Like asc_api_token, it returns on failure explicitly because callers use it in command
# substitutions.
# Arguments: method, resource path with query (for example /v1/profiles?limit=200), optional JSON body.
asc_api() {
  local method="$1" resource="$2" body="${3:-}"
  local token status_code
  local response_file="${ASC_API_KEY_DIRECTORY}/response.json"
  token="$(asc_api_token)" || return 1
  local curl_arguments=(--silent --show-error --globoff --request "${method}"
    --header "Authorization: Bearer ${token}"
    --output "${response_file}" --write-out '%{http_code}')
  if [ -n "${body}" ]; then
    curl_arguments+=(--header "Content-Type: application/json" --data "${body}")
  fi
  status_code="$(curl "${curl_arguments[@]}" "https://api.appstoreconnect.apple.com${resource}")" || return 1
  if [ "${status_code}" -lt 200 ] || [ "${status_code}" -ge 300 ]; then
    echo "Error: ${method} ${resource} returned HTTP ${status_code}" >&2
    cat "${response_file}" >&2
    return 1
  fi
  cat "${response_file}"
}

# Reads the Release build settings of the app target into APP_BUILD_SETTINGS. The project is the
# source of truth for the team and the app's bundle identifier.
read_app_build_settings() {
  APP_BUILD_SETTINGS="$(xcodebuild -project SecChain.xcodeproj -target SecChain -configuration Release -showBuildSettings -json)"
}

# Prints one value from APP_BUILD_SETTINGS, and fails when the setting is missing.
app_build_setting() {
  jq -er --arg name "$1" '.[0].buildSettings[$name]' <<< "${APP_BUILD_SETTINGS}"
}

# The Info.plist of the embedded tool is the source of truth for the tool's bundle identifier.
cli_bundle_identifier() {
  plutil -extract CFBundleIdentifier raw SecChainCLISupport/Info.plist
}
