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
# A second throwaway repository for the environments, so that giving it environments changes nothing
# for the checks of the first one. The user scope never gets an environment here: it is the real one,
# and an environment of it would make every repository of the user need --env.
ENVIRONMENT_REPOSITORY_DIRECTORY="${WORK_DIRECTORY}/environment-repository"
ENVIRONMENT_REPOSITORY="github.com/secchain-cli-test/environment-repository-$$"
SCOPE="secchain-cli-test-$$"
USER_SCOPE_KEY="CLI_TEST_USER_KEY_$$"
# Where the real user scope already has environments, a secret stored there without one is refused
# and `run` needs --env, so the throwaway name goes into the first of them and every command about
# it names that environment. The checks never give the user scope an environment it does not have.
# An environment name has no character a shell splits or expands, so the option is used unquoted.
USER_SCOPE_ENVIRONMENT="$("${SECCHAIN}" list --envs --scope user | cut -f2 | cut -d' ' -f1)"
USER_SCOPE_ENVIRONMENT_OPTION=""
if [ "${USER_SCOPE_ENVIRONMENT}" != "-" ]; then
  USER_SCOPE_ENVIRONMENT_OPTION="--env ${USER_SCOPE_ENVIRONMENT}"
fi

cleanup() {
  (
    cd "${REPOSITORY_DIRECTORY}" || exit 0
    "${SECCHAIN}" delete CLI_TEST_KEY
    "${SECCHAIN}" delete CLI_TEST_SHARED_KEY
    "${SECCHAIN}" delete CLI_TEST_SCOPE_KEY --scope "${SCOPE}"
    "${SECCHAIN}" delete CLI_TEST_SHARED_KEY --scope "${SCOPE}"
    "${SECCHAIN}" delete "${USER_SCOPE_KEY}" --scope user ${USER_SCOPE_ENVIRONMENT_OPTION}
  ) > /dev/null 2>&1 || true
  # Every secret of an environment first: while one is left, a delete without --env is refused.
  for environment in local prod; do
    for key in CLI_TEST_ENV_KEY_A CLI_TEST_ENV_KEY_B; do
      "${SECCHAIN}" delete "${key}" --repository "${ENVIRONMENT_REPOSITORY}" --env "${environment}" > /dev/null 2>&1 || true
    done
    "${SECCHAIN}" delete CLI_TEST_ENV_SCOPE_KEY --scope "${SCOPE}" --env "${environment}" > /dev/null 2>&1 || true
  done
  for key in CLI_TEST_ENV_KEY_A CLI_TEST_ENV_KEY_B; do
    "${SECCHAIN}" delete "${key}" --repository "${ENVIRONMENT_REPOSITORY}" > /dev/null 2>&1 || true
  done
  "${SECCHAIN}" delete CLI_TEST_ENV_SCOPE_KEY --scope "${SCOPE}" > /dev/null 2>&1 || true
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
printf '%s' "${LAST_OUTPUT}" | grep -qF -e "--repository" || fail "the error does not say what replaced @repository"
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
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set '${USER_SCOPE_KEY}' --scope user --no-sync ${USER_SCOPE_ENVIRONMENT_OPTION}"
[ "${LAST_STATUS}" -eq 0 ] || fail "set --scope user exited with ${LAST_STATUS}"
capture_output "${SECCHAIN}" run --only "${USER_SCOPE_KEY}" ${USER_SCOPE_ENVIRONMENT_OPTION} -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run passed the user scope before it was allowed"
printf '%s' "${LAST_OUTPUT}" | grep -q "is stored for ${USER_SCOPE_KEY}" || fail "run did not report the secret of the user scope as missing"
capture "${SECCHAIN}" scope allow user 'github.com/secchain-cli-test/*'
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run --only "${USER_SCOPE_KEY}" ${USER_SCOPE_ENVIRONMENT_OPTION} -- sh -c "test \"\${${USER_SCOPE_KEY}}\" = \"\${EXPECTED_VALUE}\""
[ "${LAST_STATUS}" -eq 0 ] || fail "run did not pass the user scope through the wildcard (status ${LAST_STATUS})"
capture "${SECCHAIN}" scope deny user 'github.com/secchain-cli-test/*'
capture "${SECCHAIN}" run --only "${USER_SCOPE_KEY}" ${USER_SCOPE_ENVIRONMENT_OPTION} -- true
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

echo "== --repository in another letter case names the repository its remote identifies"
# The repository's secret was stored under the lowercase identifier its remote gives it.
(cd "${WORK_DIRECTORY}" && "${SECCHAIN}" list --repository "GitHub.com/SecChain-CLI-Test/Repository-$$") | grep -qx "CLI_TEST_KEY" \
  || fail "--repository spelled in another letter case did not reach the repository's secret"

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
capture "${SECCHAIN}" delete "${USER_SCOPE_KEY}" --scope user ${USER_SCOPE_ENVIRONMENT_OPTION}
[ "${LAST_STATUS}" -eq 0 ] || fail "delete --scope user exited with ${LAST_STATUS}"

echo "== delete removes the secret and its declaration"
capture "${SECCHAIN}" delete CLI_TEST_KEY
[ "${LAST_STATUS}" -eq 0 ] || fail "delete exited with ${LAST_STATUS}"
[ -z "$("${SECCHAIN}" list)" ] || fail "list still prints a secret after delete"
! grep -qx "CLI_TEST_KEY" .secchain || fail "delete left the name in .secchain"
capture "${SECCHAIN}" delete CLI_TEST_KEY
[ "${LAST_STATUS}" -eq 0 ] || fail "deleting again is not idempotent (status ${LAST_STATUS})"

mkdir -p "${ENVIRONMENT_REPOSITORY_DIRECTORY}"
cd "${ENVIRONMENT_REPOSITORY_DIRECTORY}"
git init --quiet
git remote add origin "https://${ENVIRONMENT_REPOSITORY}.git"

echo "== a repository without environments runs without --env, and with one"
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_ENV_KEY_A"
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_ENV_KEY_B"
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run -- sh -c 'test "${CLI_TEST_ENV_KEY_A}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run without --env failed in a repository without environments (status ${LAST_STATUS})"
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run --env prod -- sh -c 'test "${CLI_TEST_ENV_KEY_A}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run --env did not pass the secrets of a repository without environments (status ${LAST_STATUS})"
"${SECCHAIN}" list --envs | grep -qx "repository"$'\t'"-"$'\t'"2 without an environment" || fail "list --envs did not say the repository has no environment"

echo "== moving one secret warns that it is the first environment and names the ones left"
capture_output "${SECCHAIN}" env migrate local CLI_TEST_ENV_KEY_A
[ "${LAST_STATUS}" -eq 0 ] || fail "env migrate of one secret exited with ${LAST_STATUS}"
printf '%s' "${LAST_OUTPUT}" | grep -q "warning: local is the first environment of ${ENVIRONMENT_REPOSITORY}" || fail "moving the first secret did not warn about the first environment"
printf '%s' "${LAST_OUTPUT}" | grep -q "does not pass them: CLI_TEST_ENV_KEY_B" || fail "the warning did not name the secret left without an environment"
printf '%s' "${LAST_OUTPUT}" | grep -qF "secchain env migrate local" || fail "the warning did not say how to move the rest"
"${SECCHAIN}" list --long --scope repository | grep -q "^CLI_TEST_ENV_KEY_A"$'\t'".*"$'\t'"local$" || fail "list --long did not show the environment of the moved secret"
"${SECCHAIN}" list --long --scope repository | grep -q "^CLI_TEST_ENV_KEY_B"$'\t'".*"$'\t'"-$" || fail "list --long did not show '-' for the secret without an environment"

echo "== once the repository has an environment, run needs --env"
capture_output "${SECCHAIN}" run -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run started without --env in a repository with an environment"
printf '%s' "${LAST_OUTPUT}" | grep -qF "secchain run --env <environment>" || fail "the refusal did not say how to name the environment"
printf '%s' "${LAST_OUTPUT}" | grep -qF "secchain env migrate" || fail "the refusal did not say how to move the secret left without an environment"
capture_output "${SECCHAIN}" run --env local -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run --env local started although the declared CLI_TEST_ENV_KEY_B has no value in local"
printf '%s' "${LAST_OUTPUT}" | grep -q "no stored value in the environment local: CLI_TEST_ENV_KEY_B" || fail "the refusal did not name the environment and the secret it lacks"

echo "== set without --env is refused before a value is read"
capture_output sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_ENV_KEY_B"
[ "${LAST_STATUS}" -ne 0 ] || fail "set without --env stored a secret in a repository with an environment"
printf '%s' "${LAST_OUTPUT}" | grep -qF -e "--env <environment>" || fail "the refusal of set did not name --env"

echo "== moving the rest leaves nothing without an environment, and moving again does nothing"
capture "${SECCHAIN}" env migrate local
[ "${LAST_STATUS}" -eq 0 ] || fail "env migrate of every secret exited with ${LAST_STATUS}"
"${SECCHAIN}" list --envs | grep -qx "repository"$'\t'"local"$'\t'"0 without an environment" || fail "list --envs did not show the environment after moving everything"
capture_output "${SECCHAIN}" env migrate local
[ "${LAST_STATUS}" -eq 0 ] || fail "env migrate with nothing to move exited with ${LAST_STATUS}"
printf '%s' "${LAST_OUTPUT}" | grep -q "^Nothing to move" || fail "env migrate with nothing to move did not say so"

echo "== run --env passes the value of that environment, and no other"
capture sh -c "printf '%s\n' '${OTHER_DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_ENV_KEY_A --env prod"
[ "${LAST_STATUS}" -eq 0 ] || fail "set --env prod exited with ${LAST_STATUS}"
capture "${SECCHAIN}" run --env prod -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run --env prod started although CLI_TEST_ENV_KEY_B has no prod value (a fallback to local)"
capture sh -c "printf '%s\n' '${OTHER_DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_ENV_KEY_B --env prod"
EXPECTED_VALUE="${DUMMY_VALUE}" capture "${SECCHAIN}" run --env local -- sh -c 'test "${CLI_TEST_ENV_KEY_A}" = "${EXPECTED_VALUE}" && test "${CLI_TEST_ENV_KEY_B}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run --env local did not pass the local values (status ${LAST_STATUS})"
EXPECTED_VALUE="${OTHER_DUMMY_VALUE}" capture "${SECCHAIN}" run --env prod -- sh -c 'test "${CLI_TEST_ENV_KEY_A}" = "${EXPECTED_VALUE}" && test "${CLI_TEST_ENV_KEY_B}" = "${EXPECTED_VALUE}"'
[ "${LAST_STATUS}" -eq 0 ] || fail "run --env prod did not pass the prod values (status ${LAST_STATUS})"
[ "$("${SECCHAIN}" list --env prod | tr '\n' ' ')" = "CLI_TEST_ENV_KEY_A CLI_TEST_ENV_KEY_B " ] || fail "list --env prod did not print the names of prod"
"${SECCHAIN}" list --envs | grep -qx "repository"$'\t'"local prod"$'\t'"0 without an environment" || fail "list --envs did not show both environments"

echo "== deleting the value of one environment keeps the declaration the other still needs"
capture "${SECCHAIN}" delete CLI_TEST_ENV_KEY_A --env prod
[ "${LAST_STATUS}" -eq 0 ] || fail "delete --env prod exited with ${LAST_STATUS}"
grep -qx "CLI_TEST_ENV_KEY_A" .secchain || fail "delete --env removed the name from .secchain although local still holds it"
! "${SECCHAIN}" list --env prod | grep -qx "CLI_TEST_ENV_KEY_A" || fail "list --env prod still prints the deleted secret"

echo "== a shared scope moves to an environment with --scope"
capture sh -c "printf '%s\n' '${DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_ENV_SCOPE_KEY --scope '${SCOPE}' --no-sync"
capture "${SECCHAIN}" env migrate local --scope "${SCOPE}"
[ "${LAST_STATUS}" -eq 0 ] || fail "env migrate --scope exited with ${LAST_STATUS}"
"${SECCHAIN}" list --long --scope "${SCOPE}" | grep -q "^CLI_TEST_ENV_SCOPE_KEY"$'\t'".*"$'\t'"local$" || fail "env migrate --scope did not move the scope's secret"
capture sh -c "printf '%s\n' '${OTHER_DUMMY_VALUE}' | '${SECCHAIN}' set CLI_TEST_ENV_SCOPE_KEY --scope '${SCOPE}' --env prod --no-sync"
[ "${LAST_STATUS}" -eq 0 ] || fail "set --scope --env exited with ${LAST_STATUS}"
"${SECCHAIN}" list --envs --scope "${SCOPE}" | grep -qx "${SCOPE}"$'\t'"local prod"$'\t'"0 without an environment" || fail "list --envs --scope did not show the scope's environments"

echo "== invalid environment arguments are usage errors"
capture "${SECCHAIN}" run --env Prod -- true
[ "${LAST_STATUS}" -ne 0 ] || fail "run accepted an environment name with an uppercase letter"
capture_output "${SECCHAIN}" list --repository "${ENVIRONMENT_REPOSITORY}#prod"
[ "${LAST_STATUS}" -ne 0 ] || fail "--repository accepted an identifier that contains '#'"
printf '%s' "${LAST_OUTPUT}" | grep -q "cannot be a repository identifier" || fail "the refusal of '#' did not say why"
cd "${REPOSITORY_DIRECTORY}"

echo "== the values appear in no output and in no file of the working directory or ~/.secchain"
! grep -rqF -e "${DUMMY_VALUE}" -e "${OTHER_DUMMY_VALUE}" "${WORK_DIRECTORY}" || fail "a value leaked into the captured output or a file"

echo "PASS (cli)"
