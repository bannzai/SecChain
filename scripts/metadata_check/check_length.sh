#!/bin/bash
# Checks that a metadata file stays within the character limit App Store Connect enforces for it.
# Trailing newlines are not counted, because fastlane strips them before uploading.
#
# Usage: check_length.sh <file> <limit>
# Exit codes: 0 within the limit, 1 over the limit, 2 usage error or missing file.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <file> <limit>" >&2
  exit 2
fi
file_path="$1"
limit="$2"

if [ ! -f "${file_path}" ]; then
  echo "Error: no such file: ${file_path}" >&2
  exit 2
fi

character_count=$(tr -d '\n' < "${file_path}" | wc -m | tr -d ' ')
if [ "${character_count}" -le "${limit}" ]; then
  echo "OK ${file_path} (${character_count} / ${limit})"
  exit 0
fi
echo "OVER ${file_path} (${character_count} / ${limit})" >&2
exit 1
