#!/bin/bash
# End-to-end checks of the command-line tool against the real Keychain. Needs the signed embedded
# tool. Uses a throwaway repository, a throwaway custom scope, a throwaway ~/.secchain, and dummy
# values, and deletes what it stored. The user scope is the real one, because the Keychain is not
# kept per $HOME: the checks store one throwaway name there, run with '--only' that name while the
# user scope is allowed, so that no other secret of the user scope is read, and delete it.
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
OTHER_DUMMY_VALUE="other-dummy-value-for-cli-test"
WORK_DIRECTORY="$(mktemp -d)"
CAPTURED_OUTPUT="${WORK_DIRECTORY}/captured-output.log"
# secchain reads ~/.secchain from $HOME, so the user's own file is never read or changed here.
export HOME="${WORK_DIRECTORY}/home"
USER_DEFINITION="${HOME}/.secchain"
REPOSITORY_DIRECTORY="${WORK_DIRECTORY}/repository"
REPOSITORY="github.com/secchain-cli-test/repository-$$"
SCOPE="secchain-cli-test-$$"
USER_SCOPE_KEY="CLI_TEST_USER_KEY_$$"

cleanup() {
  (
    cd "${REPOSITORY_DIRECTORY}" || exit 0
    "${SECCHAIN}" delete CLI_TEST_KEY
    "${SECCHAIN}" delete CLI_TEST_SHARED_KEY
    "${SECCHAIN}" delete CLI_TEST_SCOPE_KEY --scope "${SCOPE}"
    "${SECCHAIN}" delete CLI_TEST_SHARED_KEY --scope "${SCOPE}"
    "${SECCHAIN}" delete "${USER_SCOPE_KEY}" --scope user
  ) > /dev/null 2>&1 || true
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

# Runs a command and keeps what it prints in LAST_OUTPUT (and in the captured output).
capture_output() {
  set +e
  LAST_OUTPUT="$("$@" 2>&1)"
  LAST_STATUS=$?
  set -e
  printf '%s\n' "${LAST_OUTPUT}" >> "${CAPTURED_OUTPUT}"
}

mkdir -p "${HOME}" "${REPOSITORY_DIRECTORY}"
cd "${REPOSITORY_DIRECTORY}"
git init --quiet
git remote add origin "https://github.com/secchain-cli-test/repository-$$.git"

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

echo "== run --approve-remotely changes nothing for a secret that needs no authentication"
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run --approve-remotely -- sh -c 'test "${CLI_TEST_KEY}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run --approve-remotely exited with ${LAST_STATUS} for a standard secret"

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
sed -i '' '/^CLI_TEST_MISSING_KEY$/d' .secchain

echo "== .secchain cannot name the repository any more"
cp .secchain "${WORK_DIRECTORY}/secchain.backup"
printf '@repository github.com/secchain-cli-test/anything\n' >> .secchain
capture_output "${SECCHAIN}" list
[ "${LAST_STATUS}" -ne 0 ] || fail "a .secchain with @repository was accepted"
printf '%s' "${LAST_OUTPUT}" | grep -q "@alias" || fail "the error does not say where @repository went"
cp "${WORK_DIRECTORY}/secchain.backup" .secchain

echo "== set --scope stores in a custom scope and declares the name in ~/.secchain only"
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_SCOPE_KEY --scope '${SCOPE}' --no-sync"
[ "${LAST_STATUS}" -eq 0 ] || fail "set --scope exited with ${LAST_STATUS}"
grep -qx "@scope ${SCOPE}" "${USER_DEFINITION}" || fail "set --scope did not create the scope in ~/.secchain"
grep -qx "CLI_TEST_SCOPE_KEY" "${USER_DEFINITION}" || fail "set --scope did not declare the name in ~/.secchain"
! grep -qx "CLI_TEST_SCOPE_KEY" .secchain || fail "set --scope declared the name in the repository's .secchain"
"${SECCHAIN}" list --scope "${SCOPE}" | grep -qx "CLI_TEST_SCOPE_KEY" || fail "list --scope did not print the name"

echo "== a scope without @allow is passed to no repository"
capture "${SECCHAIN}" run -- sh -c 'test -z "${CLI_TEST_SCOPE_KEY:-}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run passed the secret of a scope that allows no repository"
! "${SECCHAIN}" list | grep -qx "CLI_TEST_SCOPE_KEY" || fail "list printed the secret of a scope that is not passed"

echo "== a declared name that only a scope not allowed holds names the scope to allow"
printf 'CLI_TEST_SCOPE_KEY\n' >> .secchain
capture_output "${SECCHAIN}" run -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run started although CLI_TEST_SCOPE_KEY is in a scope that is not allowed"
printf '%s' "${LAST_OUTPUT}" | grep -qF "secchain scope allow ${SCOPE} ${REPOSITORY}" || fail "the error does not say which scope to allow"
sed -i '' '/^CLI_TEST_SCOPE_KEY$/d' .secchain

echo "== scope allow passes the scope to the repository"
capture "${SECCHAIN}" scope allow "${SCOPE}" "${REPOSITORY}"
[ "${LAST_STATUS}" -eq 0 ] || fail "scope allow exited with ${LAST_STATUS}"
grep -qx "@allow ${REPOSITORY}" "${USER_DEFINITION}" || fail "scope allow did not add the @allow line"
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run -- sh -c 'test "${CLI_TEST_SCOPE_KEY}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run did not pass the secret of an allowed scope (status ${LAST_STATUS})"
"${SECCHAIN}" list | grep -qx "CLI_TEST_SCOPE_KEY" || fail "list did not print the secret of an allowed scope"
"${SECCHAIN}" list --long | grep -q "^CLI_TEST_SCOPE_KEY.*${SCOPE}" || fail "list --long did not name the scope the secret comes from"
! "${SECCHAIN}" list --scope repository | grep -qx "CLI_TEST_SCOPE_KEY" || fail "list --scope repository printed a secret of another scope"
"${SECCHAIN}" list --scopes | grep -qx "${SCOPE}"$'\t'"${REPOSITORY}" || fail "list --scopes did not print the scope with its pattern"
capture "${SECCHAIN}" scope allow "${SCOPE}" "${REPOSITORY}"
[ "$(grep -cx "@allow ${REPOSITORY}" "${USER_DEFINITION}")" -eq 1 ] || fail "allowing twice added a second @allow line"

echo "== the repository's own secret wins over a scope's secret of the same name"
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_SHARED_KEY"
capture sh -c "printf '%s\n' '${OTHER_DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_SHARED_KEY --scope '${SCOPE}' --no-sync"
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run -- sh -c 'test "${CLI_TEST_SHARED_KEY}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run did not take the repository's own value (status ${LAST_STATUS})"
"${SECCHAIN}" list --long | grep -q "^CLI_TEST_SHARED_KEY.*repository.*(also in ${SCOPE})" || fail "list --long did not say the name is also in the scope"

echo "== the user scope is passed through a wildcard pattern"
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set '${USER_SCOPE_KEY}' --scope user --no-sync"
[ "${LAST_STATUS}" -eq 0 ] || fail "set --scope user exited with ${LAST_STATUS}"
capture_output "${SECCHAIN}" run --only "${USER_SCOPE_KEY}" -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run passed the user scope before it was allowed"
printf '%s' "${LAST_OUTPUT}" | grep -q "No value is stored for ${USER_SCOPE_KEY}" || fail "run did not report the secret of the user scope as missing"
capture "${SECCHAIN}" scope allow user 'github.com/secchain-cli-test/*'
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run --only "${USER_SCOPE_KEY}" -- sh -c "test \"\${${USER_SCOPE_KEY}}\" = \"\${EXPECTED_VALUE}\""
[ "${LAST_STATUS}" -eq 0 ] || fail "run did not pass the user scope through the wildcard (status ${LAST_STATUS})"
capture "${SECCHAIN}" scope deny user 'github.com/secchain-cli-test/*'
capture "${SECCHAIN}" run --only "${USER_SCOPE_KEY}" -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run still passed the user scope after scope deny"

echo "== invalid scope arguments are usage errors"
capture "${SECCHAIN}" list --scope user --repository "${REPOSITORY}"
[ "${LAST_STATUS}" -ne 0 ] || fail "--scope user was accepted together with --repository"
capture "${SECCHAIN}" scope allow repository "${REPOSITORY}"
[ "${LAST_STATUS}" -ne 0 ] || fail "scope allow accepted the repository scope"
capture "${SECCHAIN}" scope allow Not_A_Scope "${REPOSITORY}"
[ "${LAST_STATUS}" -ne 0 ] || fail "scope allow accepted an invalid scope name"
capture "${SECCHAIN}" scope allow "${SCOPE}" 'github.com/*/repository'
[ "${LAST_STATUS}" -ne 0 ] || fail "scope allow accepted a pattern with a '*' in the middle"
capture "${SECCHAIN}" scope allow "${SCOPE}" 'local/app=v2'
[ "${LAST_STATUS}" -ne 0 ] || fail "scope allow accepted a pattern with '=', which would make ~/.secchain unreadable"
"${SECCHAIN}" list --scopes > /dev/null || fail "a refused pattern left ~/.secchain unreadable"

echo "== a repository cannot be named like a shared scope's Keychain service"
capture_output sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_KEY --repository com.bannzai.SecChain.scope.user"
[ "${LAST_STATUS}" -ne 0 ] || fail "set stored a secret for a repository named like the user scope's service"
printf '%s' "${LAST_OUTPUT}" | grep -q "cannot be a repository identifier" || fail "the error does not say why the identifier is refused"

echo "== in the home directory, ~/.secchain is not read as a repository's .secchain"
(cd "${HOME}" && "${SECCHAIN}" run --repository "${REPOSITORY}" -- true) >> "${CAPTURED_OUTPUT}" 2>&1 \
  || fail "run in the home directory read ~/.secchain as the repository's .secchain"

echo "== @alias makes a fork use its upstream's secrets, @path identifies a directory without a remote"
FORK_DIRECTORY="${WORK_DIRECTORY}/fork"
NOTES_DIRECTORY="${WORK_DIRECTORY}/notes"
mkdir -p "${FORK_DIRECTORY}" "${NOTES_DIRECTORY}/drafts"
(cd "${FORK_DIRECTORY}" && git init --quiet && git remote add origin "git@github.com:secchain-cli-test/fork-$$.git")
printf '@alias github.com/secchain-cli-test/fork-%s %s\n@path %s secchain-cli-test-notes-%s\n' "$$" "${REPOSITORY}" "${NOTES_DIRECTORY}" "$$" >> "${USER_DEFINITION}"
(cd "${FORK_DIRECTORY}" && "${SECCHAIN}" list) | grep -qx "CLI_TEST_KEY" || fail "the fork did not get its upstream's secret"
(cd "${NOTES_DIRECTORY}/drafts" && "${SECCHAIN}" list --long) | grep -qx "# secchain-cli-test-notes-$$ (repository)" || fail "@path did not identify the directory below it"

echo "== scope deny stops passing the scope"
capture "${SECCHAIN}" scope deny "${SCOPE}" "${REPOSITORY}"
[ "${LAST_STATUS}" -eq 0 ] || fail "scope deny exited with ${LAST_STATUS}"
! grep -qx "@allow ${REPOSITORY}" "${USER_DEFINITION}" || fail "scope deny left the @allow line"
capture "${SECCHAIN}" run -- sh -c 'test -z "${CLI_TEST_SCOPE_KEY:-}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run still passed the scope after scope deny"
capture "${SECCHAIN}" scope deny "${SCOPE}" "${REPOSITORY}"
[ "${LAST_STATUS}" -eq 0 ] || fail "denying again is not idempotent (status ${LAST_STATUS})"

echo "== delete --scope removes the secret and its declaration in ~/.secchain"
capture "${SECCHAIN}" delete CLI_TEST_SCOPE_KEY --scope "${SCOPE}"
[ "${LAST_STATUS}" -eq 0 ] || fail "delete --scope exited with ${LAST_STATUS}"
[ -z "$("${SECCHAIN}" list --scope "${SCOPE}" | grep -x "CLI_TEST_SCOPE_KEY")" ] || fail "list --scope still prints the secret after delete"
! grep -qx "CLI_TEST_SCOPE_KEY" "${USER_DEFINITION}" || fail "delete --scope left the name in ~/.secchain"
capture "${SECCHAIN}" delete CLI_TEST_SHARED_KEY --scope "${SCOPE}"
capture "${SECCHAIN}" delete CLI_TEST_SHARED_KEY
capture "${SECCHAIN}" delete "${USER_SCOPE_KEY}" --scope user
[ "${LAST_STATUS}" -eq 0 ] || fail "delete --scope user exited with ${LAST_STATUS}"

echo "== delete removes the secret and its declaration"
capture "${SECCHAIN}" delete CLI_TEST_KEY
[ "${LAST_STATUS}" -eq 0 ] || fail "delete exited with ${LAST_STATUS}"
[ -z "$("${SECCHAIN}" list)" ] || fail "list still prints a secret after delete"
! grep -qx "CLI_TEST_KEY" .secchain || fail "delete left the name in .secchain"
capture "${SECCHAIN}" delete CLI_TEST_KEY
[ "${LAST_STATUS}" -eq 0 ] || fail "deleting again is not idempotent (status ${LAST_STATUS})"

echo "== the values appear in no output and in no file of the working directory or ~/.secchain"
! grep -rqF -e "${DUMMY_VALUE}" -e "${OTHER_DUMMY_VALUE}" "${WORK_DIRECTORY}" || fail "a value leaked into the captured output or a file"

echo "PASS (cli)"
