#!/bin/bash
# Checks a directory of App Store screenshots against what App Store Connect accepts (issue #46):
# the pixel size of the device class, no alpha channel, and one file per page.
#
# Usage: verify_appstore_screenshots.sh <directory> <device class> [<directory> <device class> ...]
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/screenshot_environment.sh"

[ $# -ge 2 ] && [ $(($# % 2)) -eq 0 ] || { echo "Usage: $0 <directory> <device class> [...]" >&2; exit 2; }

FAILURES=0
fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

while [ $# -gt 0 ]; do
  directory="$1"
  device="$2"
  shift 2

  read -r expected_width expected_height <<< "$(screenshot_expected_size "${device}")"
  echo "== ${directory} (${device}, ${expected_width}x${expected_height})"

  for page_number in $(seq 1 "${SCREENSHOT_PAGE_COUNT}"); do
    file="${directory}/${device}-${page_number}.png"
    if [ ! -f "${file}" ]; then
      fail "${file} is missing"
      continue
    fi
    width="$(sips -g pixelWidth "${file}" | sed -n 's/.*pixelWidth: //p')"
    height="$(sips -g pixelHeight "${file}" | sed -n 's/.*pixelHeight: //p')"
    has_alpha="$(sips -g hasAlpha "${file}" | sed -n 's/.*hasAlpha: //p')"
    [ "${width}" = "${expected_width}" ] && [ "${height}" = "${expected_height}" ] \
      || fail "${file} is ${width}x${height}, not ${expected_width}x${expected_height}"
    [ "${has_alpha}" = "no" ] || fail "${file} has an alpha channel"
  done

  actual_count="$(find "${directory}" -maxdepth 1 -name "${device}-*.png" | wc -l | tr -d ' ')"
  [ "${actual_count}" = "${SCREENSHOT_PAGE_COUNT}" ] \
    || fail "${directory} has ${actual_count} pages of ${device}, not ${SCREENSHOT_PAGE_COUNT}"
done

if [ "${FAILURES}" -gt 0 ]; then
  echo "FAIL: ${FAILURES} problem(s) in the screenshots" >&2
  exit 1
fi
echo "PASS (screenshots)"
