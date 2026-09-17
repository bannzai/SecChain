#!/bin/bash
# Checks every locale of fastlane/metadata against the character limits App Store Connect enforces,
# so that an upload does not fail on a field that is a few characters too long.
#
# Usage: check_all_metadata.sh [locale...]   (every locale by default)
# Exit codes: 0 all within the limits, 1 at least one over, 2 usage error.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_length="${script_directory}/check_length.sh"
metadata_directory="$(cd "${script_directory}/../.." && pwd)/fastlane/metadata"

if [ ! -d "${metadata_directory}" ]; then
  echo "Error: no such directory: ${metadata_directory}" >&2
  exit 2
fi

if [ $# -gt 0 ]; then
  locales=("$@")
else
  locales=()
  for locale_directory in "${metadata_directory}"/*/; do
    [ -d "${locale_directory}" ] || continue
    locales+=("$(basename "${locale_directory}")")
  done
fi

# Limits from https://developer.apple.com/help/app-store-connect/reference/app-information
declare -a fields=(name subtitle keywords promotional_text description)
declare -a limits=(30 30 100 170 4000)

over_limit_count=0
checked_count=0
for locale in "${locales[@]}"; do
  locale_directory="${metadata_directory}/${locale}"
  if [ ! -d "${locale_directory}" ]; then
    echo "Error: no such locale: ${locale}" >&2
    exit 2
  fi
  for index in "${!fields[@]}"; do
    file_path="${locale_directory}/${fields[${index}]}.txt"
    [ -f "${file_path}" ] || continue
    checked_count=$((checked_count + 1))
    if ! "${check_length}" "${file_path}" "${limits[${index}]}"; then
      over_limit_count=$((over_limit_count + 1))
    fi
  done
done

if [ "${over_limit_count}" -eq 0 ]; then
  echo "PASS ${checked_count} files within their limits"
  exit 0
fi
echo "FAIL ${over_limit_count} of ${checked_count} files over their limits" >&2
exit 1
