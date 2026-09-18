#!/bin/bash
# Takes the pages out of a capture run's result bundle and names them the way the rest of the
# pipeline expects: artifacts/<device class>/<language>/<device class>-<page>.png (issue #46).
#
# Kept apart from the capture so that a naming change can be re-applied to a result bundle that is
# already there, without running the simulator again.
#
# Usage: organize_appstore_screenshots.sh <device class>
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/screenshot_environment.sh"

[ $# -eq 1 ] || { echo "Usage: $0 <device class: ${SCREENSHOT_DEVICES[*]}>" >&2; exit 2; }
DEVICE="$1"
screenshot_simulator_device_type "${DEVICE}" > /dev/null || { echo "Unknown device class: ${DEVICE}" >&2; exit 2; }

RESULT_BUNDLE="${SCREENSHOT_WORK_DIRECTORY}/${DEVICE}.xcresult"
EXPORT_DIRECTORY="${SCREENSHOT_WORK_DIRECTORY}/${DEVICE}-attachments"

[ -d "${RESULT_BUNDLE}" ] || { echo "No result bundle at ${RESULT_BUNDLE}; run capture_appstore_screenshots.sh first" >&2; exit 1; }

# xcresulttool refuses to write into a directory that exists.
rm -rf "${EXPORT_DIRECTORY}"
echo "== exporting the attached pages of ${DEVICE}"
xcrun xcresulttool export attachments --path "${RESULT_BUNDLE}" --output-path "${EXPORT_DIRECTORY}" > /dev/null

# Starts from nothing so that a page left by an earlier run cannot be delivered as a current one.
rm -rf "${SCREENSHOT_ARTIFACTS_DIRECTORY:?}/${DEVICE}"

python3 - "${EXPORT_DIRECTORY}" "${SCREENSHOT_ARTIFACTS_DIRECTORY}" "${DEVICE}" "${SCREENSHOT_PAGE_COUNT}" "${SCREENSHOT_LANGUAGES[@]}" <<'PY'
import json
import pathlib
import re
import shutil
import sys

export_directory = pathlib.Path(sys.argv[1])
artifacts_directory = pathlib.Path(sys.argv[2])
device = sys.argv[3]
expected = int(sys.argv[4]) * len(sys.argv[5:])
manifest = json.loads((export_directory / "manifest.json").read_text())

# The name the test gave the attachment, which the exporter extends with its own index and
# identifier: screenshot---<language>---<device class>---<page>_0_<uuid>.png
name_pattern = re.compile(r"^screenshot---([a-z-]+)---([a-z0-9]+)---(\d+)(?:_.*)?$")

exported = 0
for test in manifest:
    for attachment in test.get("attachments", []):
        matched = name_pattern.match(pathlib.Path(attachment.get("suggestedHumanReadableName") or "").stem)
        if matched is None or matched.group(2) != device:
            continue
        destination = artifacts_directory / device / matched.group(1)
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(export_directory / attachment["exportedFileName"], destination / f"{device}-{matched.group(3)}.png")
        exported += 1

print(f"organized {exported} page(s) of {device} under {artifacts_directory}")
if exported != expected:
    sys.exit(f"Expected {expected} pages of {device} in the result bundle, found {exported}")
PY
