#!/bin/bash
# Captures the screenshots of one device class by running the AppStoreScreenshotsUITests target on
# the matching simulator, once per language, and puts the PNGs it attached into the artifacts
# directory (issue #46).
#
# A run per language because the status bar is part of the picture: the date the iPad shows beside
# the clock is written in the simulator's own language, which is read at startup and therefore set
# here with a restart around it.
#
# The simulator is the project's own, started through sim-boot, and it is given a fixed status bar
# so that the pictures carry no clock, no battery level, and no carrier name.
#
# For a display of iPhone Duo (issue #87) the simulator is also put in the pose that turns that
# display on, after its last boot, because a boot puts the device back in the closed pose. The
# pose is switched through the window of the Device Hub, so these two classes can only be captured
# on a Mac with the simulator on its own desktop and with accessibility access for the terminal.
#
# Usage: capture_appstore_screenshots.sh <device class>
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/screenshot_environment.sh"

[ $# -eq 1 ] || { echo "Usage: $0 <device class: ${SCREENSHOT_DEVICES[*]} ${SCREENSHOT_IPHONE_DUO_DEVICES[*]}>" >&2; exit 2; }
DEVICE="$1"
DEVICE_TYPE="$(screenshot_simulator_device_type "${DEVICE}")" || { echo "Unknown device class: ${DEVICE}" >&2; exit 2; }
SCREENSHOT_SIMULATOR_NUMBER="$(screenshot_simulator_number "${DEVICE}")"
IPHONE_DUO_POSE="$(screenshot_iphone_duo_pose "${DEVICE}" || true)"

mkdir -p "${SCREENSHOT_WORK_DIRECTORY}"

# A number per device class, so that the iPhone and the iPad get simulators of their own instead of
# one being recreated over the other between the two runs.
boot_screenshot_simulator() {
  SCRIPT_QUIET=1 SIM_DEVICE_TYPE="${DEVICE_TYPE}" sim-boot --number "${SCREENSHOT_SIMULATOR_NUMBER}" | sed -n 's/^DEVICE_UDID=//p' | tail -n 1
}

# Puts the iPhone Duo simulator in a pose. Right after a boot the Device Hub cannot yet tell which
# display is on and the script answers STATUS=ERROR, so the switch is tried again a few times.
# set_iphone_duo_pose <UDID> <closed|open>
set_iphone_duo_pose() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if bash "${SCREENSHOT_DUO_POSE_SCRIPT}" set --udid "$1" "$2"; then
      return 0
    fi
    echo "== the pose could not be set (attempt ${attempt}); waiting for the simulator"
    sleep 5
  done
  return 1
}

for language in "${SCREENSHOT_LANGUAGES[@]}"; do
  RESULT_BUNDLE="${SCREENSHOT_WORK_DIRECTORY}/${DEVICE}-${language}.xcresult"
  # xcodebuild refuses to write into a result bundle that exists, and a bundle left by an earlier
  # run would be exported as if it were this one's.
  rm -rf "${RESULT_BUNDLE}"

  echo "== booting the ${DEVICE_TYPE} simulator"
  SIMULATOR_UDID="$(boot_screenshot_simulator)"
  [ -n "${SIMULATOR_UDID}" ] || { echo "sim-boot did not return a simulator" >&2; exit 1; }

  echo "== putting ${SIMULATOR_UDID} in ${language}"
  xcrun simctl spawn "${SIMULATOR_UDID}" defaults write .GlobalPreferences AppleLanguages -array "${language}"
  xcrun simctl spawn "${SIMULATOR_UDID}" defaults write .GlobalPreferences AppleLocale -string "$(screenshot_system_locale "${language}")"
  xcrun simctl shutdown "${SIMULATOR_UDID}"
  SIMULATOR_UDID="$(boot_screenshot_simulator)"

  echo "== fixing the status bar of ${SIMULATOR_UDID}"
  # An empty operator name so that no carrier of the maintainer's can appear. The date the iPad
  # shows beside the clock is not part of the override (every ISO string this runtime was given came
  # back as "Invalid, non-ISO date/time string"), so it follows the day the pictures were taken.
  xcrun simctl status_bar "${SIMULATOR_UDID}" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName '' --batteryState charged --batteryLevel 100

  # The layout puts the app's screen as a light surface on a dark background, so the app is captured
  # in light appearance. Set explicitly because the simulator keeps whatever it was last left in.
  xcrun simctl ui "${SIMULATOR_UDID}" appearance light

  if [ -n "${IPHONE_DUO_POSE}" ]; then
    echo "== putting ${SIMULATOR_UDID} in the ${IPHONE_DUO_POSE} pose"
    set_iphone_duo_pose "${SIMULATOR_UDID}" "${IPHONE_DUO_POSE}"
  fi

  echo "== running ${SCREENSHOT_SCHEME} on ${DEVICE_TYPE} in ${language}"
  # xcodebuild hands the test runner every variable named TEST_RUNNER_<name> as <name>. Parallel
  # testing is off because it would run the test on a clone of the simulator, which boots closed
  # and would capture the outer display for every class.
  TEST_RUNNER_SCREENSHOT_LANGUAGE="${language}" TEST_RUNNER_SCREENSHOT_DEVICE="${DEVICE}" xcodebuild \
    -project "${SCREENSHOT_REPOSITORY_ROOT}/SecChain.xcodeproj" \
    -scheme "${SCREENSHOT_SCHEME}" \
    -configuration Debug \
    -derivedDataPath "${SCREENSHOT_DERIVED_DATA}" \
    -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
    -resultBundlePath "${RESULT_BUNDLE}" \
    -parallel-testing-enabled NO \
    test
done

if [ "${IPHONE_DUO_POSE}" = open ]; then
  echo "== closing ${SIMULATOR_UDID} again"
  set_iphone_duo_pose "${SIMULATOR_UDID}" closed
fi

bash "${SCREENSHOT_REPOSITORY_ROOT}/scripts/generate_screenshots/organize_appstore_screenshots.sh" "${DEVICE}"
