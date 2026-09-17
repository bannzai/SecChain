#!/bin/bash
# End-to-end checks of the command-line tool against the real Keychain. Needs the signed embedded
# tool. Uses a throwaway repository identifier and a dummy value, and deletes what it stored.
#
# The value is never echoed by this script: assertions about it run inside the child process or
# search the captured output for it.
#
# Usage: cli.sh <path to the embedded secchain executable>
set -euo pipefail

[ $# -eq 1 ] || { echo "Usage: $0 <path to the embedded secchain executable>" >&2; exit 2; }
# Absolute, because the checks run from a throwaway working directory.
SECCHAIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
DUMMY_VALUE="dummy-value-for-cli-test"
WORK_DIRECTORY="$(mktemp -d)"
CAPTURED_OUTPUT="${WORK_DIRECTORY}/captured-output.log"
REPOSITORY="secchain-cli-test-$$"

cleanup() {
  (cd "${WORK_DIRECTORY}" && "${SECCHAIN}" delete CLI_TEST_KEY > /dev/null 2>&1 || true)
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Runs a command, appends everything it prints to the captured output, and stores its exit status
# in LAST_STATUS without tripping `set -e`.
capture() {
  set +e
  "$@" >> "${CAPTURED_OUTPUT}" 2>&1
  LAST_STATUS=$?
  set -e
}

cd "${WORK_DIRECTORY}"
printf '@repository %s\n' "${REPOSITORY}" > .secchain

echo "== set reads the value from standard input"
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_KEY"
[ "${LAST_STATUS}" -eq 0 ] || fail "set exited with ${LAST_STATUS}"
grep -qx "CLI_TEST_KEY" .secchain || fail "set did not declare the name in .secchain"

echo "== a value passed as an argument is rejected"
capture "${SECCHAIN}" set CLI_TEST_KEY value-given-as-argument
[ "${LAST_STATUS}" -ne 0 ] || fail "set accepted a value argument"

echo "== list prints the name"
capture "${SECCHAIN}" list
[ "${LAST_STATUS}" -eq 0 ] || fail "list exited with ${LAST_STATUS}"
"${SECCHAIN}" list | grep -qx "CLI_TEST_KEY" || fail "list did not print the name"
capture "${SECCHAIN}" list --long
capture "${SECCHAIN}" list --repositories
"${SECCHAIN}" list --repositories | grep -qx "${REPOSITORY}" || fail "list --repositories did not print the repository"

echo "== run hands the secret to the command as an environment variable"
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run -- sh -c 'test "${CLI_TEST_KEY}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "the command did not see the expected value (status ${LAST_STATUS})"

echo "== run returns the command's exit status"
capture "${SECCHAIN}" run -- sh -c 'exit 7'
[ "${LAST_STATUS}" -eq 7 ] || fail "expected status 7, got ${LAST_STATUS}"

echo "== run reports a signal the way a shell does"
capture "${SECCHAIN}" run -- sh -c 'kill -TERM $$'
[ "${LAST_STATUS}" -eq 143 ] || fail "expected status 143 (SIGTERM), got ${LAST_STATUS}"

echo "== run fails for a command that does not exist"
capture "${SECCHAIN}" run -- secchain-no-such-command
[ "${LAST_STATUS}" -eq 127 ] || fail "expected status 127, got ${LAST_STATUS}"

echo "== run refuses to start while a declared secret has no value"
printf 'CLI_TEST_MISSING_KEY\n' >> .secchain
capture "${SECCHAIN}" run -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run started although CLI_TEST_MISSING_KEY has no value"
grep -q "CLI_TEST_MISSING_KEY" "${CAPTURED_OUTPUT}" || fail "the error did not name the missing secret"

echo "== run --only passes just the selected secret"
capture "${SECCHAIN}" run --only CLI_TEST_KEY -- sh -c 'test -n "${CLI_TEST_KEY}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run --only exited with ${LAST_STATUS}"

echo "== a missing secret is reported by name"
capture "${SECCHAIN}" run --only CLI_TEST_MISSING_KEY -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run --only succeeded for a secret without a value"

echo "== delete removes the secret and its declaration"
capture "${SECCHAIN}" delete CLI_TEST_KEY
[ "${LAST_STATUS}" -eq 0 ] || fail "delete exited with ${LAST_STATUS}"
[ -z "$("${SECCHAIN}" list)" ] || fail "list still prints a secret after delete"
! grep -qx "CLI_TEST_KEY" .secchain || fail "delete left the name in .secchain"
capture "${SECCHAIN}" delete CLI_TEST_KEY
[ "${LAST_STATUS}" -eq 0 ] || fail "deleting again is not idempotent (status ${LAST_STATUS})"

echo "== the value appears in no output and in no file of the working directory"
! grep -rq "${DUMMY_VALUE}" "${WORK_DIRECTORY}" || fail "the value leaked into the captured output or a file"

echo "PASS (cli)"
