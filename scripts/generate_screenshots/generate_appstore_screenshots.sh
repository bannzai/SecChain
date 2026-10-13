#!/bin/bash
# Generates every App Store screenshot and puts them where they are delivered from (issue #46):
# the seven pages of AppStoreScreenshotPages.swift, in English and Japanese, for iPhone 6.9 inch
# and iPad 13 inch into fastlane/screenshots, and when asked for, for the two displays of iPhone
# Duo (issue #87) into fastlane/screenshots_iphone_duo, which is uploaded by hand (README.md).
#
# The whole set comes from one run of the capture target per device class and language. Nothing is
# copied into the delivery directories until the generated files have passed the checks of
# verify_appstore_screenshots.sh.
#
# Usage: generate_appstore_screenshots.sh [device class ...]  (default: the classes fastlane delivers)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/screenshot_environment.sh"

DEVICES=("$@")
[ ${#DEVICES[@]} -gt 0 ] || DEVICES=("${SCREENSHOT_DEVICES[@]}")

for device in "${DEVICES[@]}"; do
  bash "${SCREENSHOT_REPOSITORY_ROOT}/scripts/generate_screenshots/capture_appstore_screenshots.sh" "${device}"
done

VERIFY_ARGUMENTS=()
for device in "${DEVICES[@]}"; do
  for language in "${SCREENSHOT_LANGUAGES[@]}"; do
    VERIFY_ARGUMENTS+=("${SCREENSHOT_ARTIFACTS_DIRECTORY}/${device}/${language}" "${device}")
  done
done
bash "${SCREENSHOT_REPOSITORY_ROOT}/scripts/generate_screenshots/verify_appstore_screenshots.sh" "${VERIFY_ARGUMENTS[@]}"

echo "== placing the pages in the delivery directories"
for device in "${DEVICES[@]}"; do
  for language in "${SCREENSHOT_LANGUAGES[@]}"; do
    destination="$(screenshot_delivery_directory "${device}")/$(screenshot_fastlane_language "${language}")"
    mkdir -p "${destination}"
    # Overwrites the pages of this device class and leaves the other classes alone, so that one
    # class can be regenerated on its own.
    cp "${SCREENSHOT_ARTIFACTS_DIRECTORY}/${device}/${language}"/${device}-*.png "${destination}/"
    echo "${destination} <- ${device}, ${language}"
  done
done
