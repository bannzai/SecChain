#!/bin/bash
# Integration checks that need a build signed with the team's identity. They run the signed
# binaries themselves, because only those carry the shared access group. Only the doctor's fixed
# dummy value is ever stored.
#
# Usage: integration.sh <path to the embedded secchain executable>
set -euo pipefail

[ $# -eq 1 ] || { echo "Usage: $0 <path to the embedded secchain executable>" >&2; exit 2; }
SECCHAIN="$1"
[ -x "${SECCHAIN}" ] || { echo "Error: ${SECCHAIN} is not executable. Run 'make build-macos' first." >&2; exit 1; }

HELPER_APP="$(cd "$(dirname "${SECCHAIN}")/../.." && pwd)"
APP="$(cd "${HELPER_APP}/../../.." && pwd)"
APP_EXECUTABLE="${APP}/Contents/MacOS/SecChain"
REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPECTED_ACCESS_GROUP="TQPN82UBBY.com.bannzai.SecChain.shared"
# errSecMissingEntitlement. An unsigned binary must fail with this status, which is what lets
# SecChain report a code-signing problem instead of "secret not found".
MISSING_ENTITLEMENT_STATUS="-34018"

echo "== The app and the embedded tool are signed with the shared access group"
for bundle in "${APP}" "${HELPER_APP}"; do
  if ! codesign -d --entitlements - --xml "${bundle}" 2>/dev/null | grep -q "${EXPECTED_ACCESS_GROUP}"; then
    echo "FAIL: ${bundle} is not signed with keychain-access-groups ${EXPECTED_ACCESS_GROUP}" >&2
    exit 1
  fi
  echo "ok: ${bundle}"
done

echo "== Self-contained Keychain checks, run by the embedded tool"
"${SECCHAIN}" doctor

echo "== Self-contained Keychain checks, run by the app"
"${APP_EXECUTABLE}" --doctor

echo "== An item written by the app is readable by the embedded tool"
"${APP_EXECUTABLE}" --doctor-write-fixture from-app
"${SECCHAIN}" doctor --read-fixture from-app

echo "== An item written by the embedded tool is readable by the app"
"${SECCHAIN}" doctor --write-fixture from-cli
"${APP_EXECUTABLE}" --doctor-read-fixture from-cli

echo "== An unsigned 'swift build' product fails with errSecMissingEntitlement"
swift build --package-path "${REPOSITORY_ROOT}/SecChainCore" --product secchain-cli
UNSIGNED_OUTPUT="$("$(swift build --package-path "${REPOSITORY_ROOT}/SecChainCore" --show-bin-path)/secchain-cli" doctor 2>&1 || true)"
echo "${UNSIGNED_OUTPUT}"
if ! echo "${UNSIGNED_OUTPUT}" | grep -q "status ${MISSING_ENTITLEMENT_STATUS}"; then
  echo "FAIL: the unsigned tool did not report status ${MISSING_ENTITLEMENT_STATUS}" >&2
  exit 1
fi

echo "== Command-line tool end to end"
bash "${REPOSITORY_ROOT}/scripts/test/cli.sh" "${SECCHAIN}"

echo "PASS"
