#!/bin/bash
# Values and helpers shared by the App Store screenshot scripts (issue #46). Sourced, not executed.
#
# The device classes are the ones App Store Connect asks for, with the simulator whose native
# resolution is exactly the required pixel size, so that a capture never has to be resampled. The
# two displays of iPhone Duo (issue #87) are two classes of one simulator: which display is on is
# decided by the pose the capture script puts the device in.

SCREENSHOT_REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCREENSHOT_ARTIFACTS_DIRECTORY="${SCREENSHOT_REPOSITORY_ROOT}/scripts/generate_screenshots/artifacts"
SCREENSHOT_WORK_DIRECTORY="${SCREENSHOT_REPOSITORY_ROOT}/tmp/screenshots"
SCREENSHOT_DERIVED_DATA="${SCREENSHOT_REPOSITORY_ROOT}/tmp/DerivedData"
SCREENSHOT_SCHEME="AppStoreScreenshotsUITests"
# The pages of AppStoreScreenshotPages.swift.
SCREENSHOT_PAGE_COUNT=7
# The languages of AppStoreScreenshotCopy.xcstrings.
SCREENSHOT_LANGUAGES=(en ja)
# The device classes of AppStoreScreenshotDevice that fastlane delivers.
SCREENSHOT_DEVICES=(iphone69 ipad13)
# The device classes of AppStoreScreenshotDevice that are uploaded by hand: fastlane deliver has no
# entry for the sizes of iPhone Duo and rejects a run that has them (README.md).
SCREENSHOT_IPHONE_DUO_DEVICES=(iphoneduo-outer iphoneduo-inner)
# Switches the pose of an iPhone Duo simulator, which only the window of the Device Hub can do
# (ios-simulator skill of castle, scripts/duo-pose.sh).
SCREENSHOT_DUO_POSE_SCRIPT="${SCREENSHOT_DUO_POSE_SCRIPT:-${HOME}/.agents/skills/ios-simulator/scripts/duo-pose.sh}"

# screenshot_simulator_device_type <device class>
screenshot_simulator_device_type() {
  case "$1" in
    iphone69) echo "iPhone 17 Pro Max" ;;
    ipad13) echo "iPad Pro 13-inch (M4)" ;;
    iphoneduo-outer | iphoneduo-inner) echo "iPhone Duo" ;;
    *) return 1 ;;
  esac
}

# Distinguishes the simulators sim-boot creates for this worktree, so that the device classes do
# not share one name. The two displays of iPhone Duo are one simulator in two poses, so they share
# a number.
# screenshot_simulator_number <device class>
screenshot_simulator_number() {
  case "$1" in
    iphone69) echo 1 ;;
    ipad13) echo 2 ;;
    iphoneduo-outer | iphoneduo-inner) echo 3 ;;
    *) return 1 ;;
  esac
}

# The pose of the iPhone Duo simulator that turns on the display of the class, as duo-pose.sh names
# it. Fails for a class whose simulator has one display.
# screenshot_iphone_duo_pose <device class>
screenshot_iphone_duo_pose() {
  case "$1" in
    iphoneduo-outer) echo closed ;;
    iphoneduo-inner) echo open ;;
    *) return 1 ;;
  esac
}

# The size App Store Connect requires, which AppStoreScreenshotDevice.canvasSize also uses.
# screenshot_expected_size <device class>
screenshot_expected_size() {
  case "$1" in
    iphone69) echo "1320 2868" ;;
    ipad13) echo "2064 2752" ;;
    iphoneduo-outer) echo "1398 2034" ;;
    iphoneduo-inner) echo "2853 2007" ;;
    *) return 1 ;;
  esac
}

# Where the verified pages of a device class are kept: the directory fastlane delivers from, or
# for iPhone Duo a sibling that deliver never reads (README.md).
# screenshot_delivery_directory <device class>
screenshot_delivery_directory() {
  case "$1" in
    iphoneduo-outer | iphoneduo-inner) echo "${SCREENSHOT_REPOSITORY_ROOT}/fastlane/screenshots_iphone_duo" ;;
    *) echo "${SCREENSHOT_REPOSITORY_ROOT}/fastlane/screenshots" ;;
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

# The locale the simulator itself is put in, which is what writes the date beside the iPad's clock
# in the language being captured.
# screenshot_system_locale <language>
screenshot_system_locale() {
  case "$1" in
    ja) echo "ja_JP" ;;
    *) echo "en_US" ;;
  esac
}
