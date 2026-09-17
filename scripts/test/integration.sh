#!/bin/bash
# Integration checks that need a build signed with the team's identity. They run the embedded
# command-line tool itself, because only that binary carries the shared access group.
#
# Usage: integration.sh <path to the embedded secchain executable>
set -euo pipefail

[ $# -eq 1 ] || { echo "Usage: $0 <path to the embedded secchain executable>" >&2; exit 2; }
SECCHAIN="$1"
[ -x "${SECCHAIN}" ] || { echo "Error: ${SECCHAIN} is not executable. Run 'make build-macos' first." >&2; exit 1; }

HELPER_APP="$(cd "$(dirname "${SECCHAIN}")/../.." && pwd)"
APP="$(cd "${HELPER_APP}/../../.." && pwd)"
EXPECTED_ACCESS_GROUP="TQPN82UBBY.com.bannzai.SecChain.shared"

echo "== The app and the embedded tool are signed with the shared access group"
for bundle in "${APP}" "${HELPER_APP}"; do
  if ! codesign -d --entitlements - --xml "${bundle}" 2>/dev/null | grep -q "${EXPECTED_ACCESS_GROUP}"; then
    echo "FAIL: ${bundle} is not signed with keychain-access-groups ${EXPECTED_ACCESS_GROUP}" >&2
    exit 1
  fi
  echo "ok: ${bundle}"
done

echo "== The embedded tool launches (a tool whose entitlement is not authorized is killed at launch)"
"${SECCHAIN}" --version

echo "PASS"
