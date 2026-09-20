#!/bin/bash
# Checks the Claude Code hook that ships with the agent skill (issue #45).
#
# Every case is one hook input on standard input, the way Claude Code sends it, and one assertion
# about what the hook writes: a `deny` decision, or nothing at all, which leaves the normal
# permission flow in place. The values in the cases are names, never secret values.
#
# Usage: hooks.sh
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPOSITORY_ROOT}/skills/secchain/hooks/secchain-guard.py"
SETTINGS="${REPOSITORY_ROOT}/skills/secchain/hooks/settings.json"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# run_hook <tool name> <field of tool_input> <value>
run_hook() {
  set +e
  OUTPUT="$(jq -n --arg tool "$1" --arg field "$2" --arg value "$3" \
    '{hook_event_name: "PreToolUse", tool_name: $tool, tool_input: {($field): $value}}' \
    | python3 "${HOOK}")"
  LAST_STATUS=$?
  set -e
  [ "${LAST_STATUS}" -eq 0 ] || fail "the hook exited with ${LAST_STATUS} for: $3"
}

denied() {
  run_hook "$@"
  [ -n "${OUTPUT}" ] || fail "not denied: $3"
  [ "$(printf '%s' "${OUTPUT}" | jq -r '.hookSpecificOutput.hookEventName')" = "PreToolUse" ] \
    || fail "the decision does not name the event: $3"
  [ "$(printf '%s' "${OUTPUT}" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ] \
    || fail "the decision is not a denial: $3"
  printf '%s' "${OUTPUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'secchain run -- <' \
    || fail "the reason does not say how to run the command instead: $3"
}

allowed() {
  run_hook "$@"
  [ -z "${OUTPUT}" ] || fail "denied although it should pass: $3 (${OUTPUT})"
}

echo "== the settings example is the shape the PreToolUse event expects"
jq -e '.hooks.PreToolUse[0].matcher == "Read|Bash"' "${SETTINGS}" > /dev/null \
  || fail "the settings example does not match Read and Bash"
jq -e '.hooks.PreToolUse[0].hooks[0] | .type == "command" and (.args[0] | endswith("/secchain-guard.py"))' "${SETTINGS}" > /dev/null \
  || fail "the settings example does not run the hook of this repository"

echo "== reading a .env file is denied"
denied Read file_path ".env"
denied Read file_path "/Users/someone/project/.env"
denied Read file_path "/Users/someone/project/.env.local"
denied Bash command "cat .env"
denied Bash command "grep -r OPENAI_API_KEY .env.production"
denied Bash command "source .env"
denied Bash command ". ./.env"
denied Bash command "head -n 20 ../other-project/.env"
denied Bash command "secchain set OPENAI_API_KEY < .env"
denied Bash command "cd app && cat .env.local"
# A file that holds only names is not exempt: nothing tells the hook the file is an example, and a
# real value pasted into one is exactly the accident SecChain exists to prevent.
denied Bash command "cat .env.example"

echo "== printing the environment of a run is denied"
denied Bash command "secchain run -- env"
denied Bash command "secchain run -- printenv"
denied Bash command "secchain run --only OPENAI_API_KEY -- printenv OPENAI_API_KEY"
denied Bash command "secchain run -- sh -c 'echo \$OPENAI_API_KEY'"
denied Bash command "secchain run -- bash -c 'printf \"%s\" \"\${CLOUDFLARE_API_TOKEN}\"'"
denied Bash command "secchain run -- sh -c 'env | grep OPENAI'"
denied Bash command "secchain run -- sh -c 'echo \$OPENAI_API_KEY | cat'"
denied Bash command "secchain run -- sh -c 'npm run build && echo \$OPENAI_API_KEY'"
denied Bash command "secchain run -- sh -c 'env > /tmp/environment.txt'"
denied Bash command "cd app && secchain run -- env"
denied Bash command "bash -c 'secchain run -- printenv'"
# A shell builtin asked for what it holds prints the same environment.
denied Bash command "secchain run -- sh -c 'set'"
denied Bash command "secchain run -- sh -c 'export'"
denied Bash command "secchain run -- sh -c 'export -p'"
denied Bash command "secchain run -- sh -c 'declare -p'"
denied Bash command "secchain run -- sh -c 'typeset -p'"
# A launcher in front of the run does not hide it.
denied Bash command "env secchain run -- env"
denied Bash command "command secchain run -- printenv"
denied Bash command "nohup secchain run -- sh -c 'echo \$OPENAI_API_KEY'"
denied Bash command "secchain run -- env NODE_ENV=production printenv"

echo "== a script this hook cannot read is not run with the secrets"
denied Bash command "secchain run -- python3 -c 'import os; print(os.environ)'"
denied Bash command "secchain run -- node -e 'console.log(process.env)'"
denied Bash command "secchain run -- ruby -e 'puts ENV.to_h'"
denied Bash command "secchain run -- sh -c 'python3 -c \"import os; print(os.environ)\"'"

echo "== the documented ways of using a secret pass"
allowed Bash command "secchain run -- npm run dev"
allowed Bash command "secchain run --only CLOUDFLARE_API_TOKEN -- ./scripts/deploy.sh"
# The pattern the skill itself documents: the value is piped into the program that consumes it.
allowed Bash command "secchain run -- sh -c 'printf \"Authorization: Bearer %s\" \"\$OPENAI_API_KEY\" | curl -H @- https://api.openai.com/v1/models'"
allowed Bash command "secchain run -- env NODE_ENV=production npm start"
allowed Bash command "secchain run -- sh -c 'npm run build && npm test'"
# The same builtins with something to set: they change the shell and print nothing.
allowed Bash command "secchain run -- sh -c 'set -euo pipefail; npm ci && npm test'"
allowed Bash command "secchain run -- sh -c 'export NODE_ENV=production; npm start'"
allowed Bash command "secchain run -- sh -c 'declare -r LIMIT=1; ./run.sh'"
allowed Bash command "secchain run -- python3 scripts/deploy.py"
allowed Bash command "secchain run -- ruby -E UTF-8 scripts/deploy.rb"
allowed Bash command "env NODE_ENV=production secchain run -- npm run dev"
allowed Bash command "secchain list"
allowed Bash command "secchain set OPENAI_API_KEY"
# Outside a run an inline script has no secret in its environment.
allowed Bash command "python3 -c 'print(1 + 1)'"

echo "== calls that have nothing to do with secrets pass"
allowed Read file_path "/Users/someone/project/.secchain"
allowed Read file_path "/Users/someone/project/.gitignore"
allowed Bash command "npm run dev"
allowed Bash command "git commit -m 'stop reading .env'"
allowed Bash command "echo '.env' >> .gitignore"
allowed Bash command "rm .env"
allowed Bash command "ls -la .env"
# Outside a run the environment holds no secret of this repository.
allowed Bash command "printenv"
allowed Bash command "env | sort"
allowed Bash command "export -p"
allowed Write file_path ".env"

echo "== input the hook cannot read decides nothing"
set +e
OUTPUT="$(printf 'not json' | python3 "${HOOK}")"
LAST_STATUS=$?
set -e
[ "${LAST_STATUS}" -eq 0 ] || fail "the hook exited with ${LAST_STATUS} for unreadable input"
[ -z "${OUTPUT}" ] || fail "the hook decided something for unreadable input (${OUTPUT})"

echo "PASS (hooks)"
