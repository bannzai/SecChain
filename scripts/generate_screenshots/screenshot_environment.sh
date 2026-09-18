#!/bin/bash
# Values and helpers shared by the App Store screenshot scripts (issue #46). Sourced, not executed.
#
# The device classes are the two App Store Connect asks for, with the simulator whose native
# resolution is exactly the required pixel size, so that a capture never has to be resampled.

SCREENSHOT_REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCREENSHOT_ARTIFACTS_DIRECTORY="${SCREENSHOT_REPOSITORY_ROOT}/scripts/generate_screenshots/artifacts"
SCREENSHOT_WORK_DIRECTORY="${SCREENSHOT_REPOSITORY_ROOT}/tmp/screenshots"
SCREENSHOT_DERIVED_DATA="${SCREENSHOT_REPOSITORY_ROOT}/tmp/DerivedData"
SCREENSHOT_SCHEME="AppStoreScreenshotsUITests"
# The pages of AppStoreScreenshotPages.swift.
SCREENSHOT_PAGE_COUNT=7
# The languages of AppStoreScreenshotCopy.xcstrings.
SCREENSHOT_LANGUAGES=(en ja)
# The device classes of AppStoreScreenshotDevice.
SCREENSHOT_DEVICES=(iphone69 ipad13)

# screenshot_simulator_device_type <device class>
screenshot_simulator_device_type() {
  case "$1" in
    iphone69) echo "iPhone 17 Pro Max" ;;
    ipad13) echo "iPad Pro 13-inch (M4)" ;;
    *) return 1 ;;
  esac
}

# Distinguishes the simulators sim-boot creates for this worktree, so that the two device classes
# do not share one name.
# screenshot_simulator_number <device class>
screenshot_simulator_number() {
  case "$1" in
    iphone69) echo 1 ;;
    ipad13) echo 2 ;;
    *) return 1 ;;
  esac
}

# The size App Store Connect requires, which AppStoreScreenshotDevice.canvasSize also uses.
# screenshot_expected_size <device class>
screenshot_expected_size() {
  case "$1" in
    iphone69) echo "1320 2868" ;;
    ipad13) echo "2064 2752" ;;
    *) return 1 ;;
  esac
}

# The directory names App Store Connect and fastlane/metadata use.
# screenshot_fastlane_language <language>
screenshot_fastlane_language() {
  case "$1" in
    en) echo "en-US" ;;
    *) echo "$1" ;;
  esac
}
