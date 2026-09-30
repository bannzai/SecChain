#!/bin/bash
# Checks the Claude Code hooks that ship with the agent skill: the guard (issue #45, and its rules for
# `secchain set` from issue #76) and the Claude Mods plugin that masks values (issue #70).
#
# Every case of the guard is one hook input on standard input, the way Claude Code sends it, and one
# assertion about what the hook writes: a `deny` decision, or nothing at all, which leaves the
# normal permission flow in place. The values in the cases are names, never secret values. The
# plugin is checked by Claude Code's own `claude plugin validate` and `claude plugin test`, so
# `claude` must be on PATH.
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

# denied_saying <text the reason has to contain> <tool name> <field of tool_input> <value>
denied_saying() {
  local expected_reason="$1"
  shift
  run_hook "$@"
  [ -n "${OUTPUT}" ] || fail "not denied: $3"
  [ "$(printf '%s' "${OUTPUT}" | jq -r '.hookSpecificOutput.hookEventName')" = "PreToolUse" ] \
    || fail "the decision does not name the event: $3"
  [ "$(printf '%s' "${OUTPUT}" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ] \
    || fail "the decision is not a denial: $3"
  printf '%s' "${OUTPUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qF -e "${expected_reason}" \
    || fail "the reason does not say how to do it instead (${expected_reason}): $3"
}

# A call that reaches for a value: the reason names the run that uses the value instead.
denied() {
  denied_saying 'secchain run -- <' "$@"
}

# A `secchain set` that writes the value into the line: the reason names the ways that do not.
denied_set() {
  denied_saying 'secchain set NAME --from-variable' "$@"
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
denied Bash command "secchain run -- sh -c 'npm run build"$'\n'"env'"
denied Bash command "bash -c 'secchain run -- printenv'"
# A shell builtin with nothing to set prints the same environment. `declare -x` and `typeset -x`
# list every exported variable with its value, so an option alone is not a reason to pass.
denied Bash command "secchain run -- sh -c 'set'"
denied Bash command "secchain run -- sh -c 'export'"
denied Bash command "secchain run -- sh -c 'export -p'"
denied Bash command "secchain run -- sh -c 'declare -p'"
denied Bash command "secchain run -- sh -c 'declare -x'"
denied Bash command "secchain run -- sh -c 'typeset -x'"
# The print option prints the names that follow it with their values, so a name does not make the
# call safe. `export -p NAME` prints nothing in bash but prints the value in zsh, and nothing in the
# command line says which shell `sh` is. `+p` prints as well (bash 5.3.9, zsh 5.9).
denied Bash command "secchain run -- bash -c 'declare -p OPENAI_API_KEY'"
denied Bash command "secchain run -- sh -c 'typeset -p NAME'"
denied Bash command "secchain run -- sh -c 'export -p NAME'"
denied Bash command "secchain run -- sh -c 'declare -px NAME'"
denied Bash command "secchain run -- sh -c 'declare +p NAME'"
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
# The same builtins with shell options to set or a name to act on: they print nothing.
allowed Bash command "secchain run -- sh -c 'set -euo pipefail; npm ci && npm test'"
allowed Bash command "secchain run -- sh -c 'set -o pipefail; ./run.sh'"
allowed Bash command "secchain run -- sh -c 'export NODE_ENV=production; npm start'"
allowed Bash command "secchain run -- sh -c 'export -n NAME; ./run.sh'"
allowed Bash command "secchain run -- sh -c 'declare -r LIMIT=1; ./run.sh'"
allowed Bash command "secchain run -- sh -c 'declare -x NAME; ./run.sh'"
allowed Bash command "secchain run -- python3 scripts/deploy.py"
allowed Bash command "secchain run -- ruby -E UTF-8 scripts/deploy.rb"
allowed Bash command "env NODE_ENV=production secchain run -- npm run dev"
allowed Bash command "secchain list"
allowed Bash command "secchain set OPENAI_API_KEY"

echo "== the scope subcommands and options pass"
allowed Bash command "secchain set OPENAI_API_KEY --scope user"
allowed Bash command "secchain set YOUTUBE_API_KEY --scope youtube"
allowed Bash command "secchain list --scope youtube"
allowed Bash command "secchain list --scopes"
allowed Bash command "secchain list --long"
allowed Bash command "secchain delete YOUTUBE_API_KEY --scope youtube"
allowed Bash command "secchain scope allow youtube github.com/bannzai/youtuber"
allowed Bash command "secchain scope allow user 'github.com/bannzai/*'"
allowed Bash command "secchain scope deny youtube github.com/bannzai/youtuber"
# ~/.secchain holds names and patterns only, like a repository's .secchain.
allowed Read file_path "/Users/someone/.secchain"
allowed Bash command "cat ~/.secchain"
# Outside a run an inline script has no secret in its environment.
allowed Bash command "python3 -c 'print(1 + 1)'"

echo "== the environment subcommands and options pass"
# `--env` names an environment of the secrets, not a `.env` file, and `env migrate` is SecChain's
# subcommand, not the `env` command that prints the environment.
allowed Bash command "secchain env migrate local"
allowed Bash command "secchain env migrate local OPENAI_API_KEY"
allowed Bash command "secchain env migrate local --scope user"
allowed Bash command "secchain set OPENAI_API_KEY --env prod"
allowed Bash command "secchain set OPENAI_API_KEY --scope user --env prod"
allowed Bash command "secchain delete OPENAI_API_KEY --env prod"
allowed Bash command "secchain list --env prod"
allowed Bash command "secchain list --envs"
allowed Bash command "secchain run --env local -- npm run dev"
allowed Bash command "secchain run --env prod --only CLOUDFLARE_API_TOKEN -- ./scripts/deploy.sh"
# The environment does not change what the child of a run may do.
denied Bash command "secchain run --env prod -- env"
denied Bash command "secchain run --env prod -- sh -c 'echo \$OPENAI_API_KEY'"

echo "== a secchain set that writes the value into the line is denied"
# `the-value` stands for a value written out; the cases never hold a real one.
denied_set Bash command "printf 'the-value' | secchain set OPENAI_API_KEY"
denied_set Bash command "echo the-value | secchain set OPENAI_API_KEY"
denied_set Bash command "printf '%s' the-value | secchain set OPENAI_API_KEY --scope user --env prod"
denied_set Bash command "secchain set OPENAI_API_KEY <<< the-value"
denied_set Bash command "secchain set OPENAI_API_KEY <<'EOF'"$'\n'"the-value"$'\n'"EOF"
denied_set Bash command "cat <<EOF | secchain set OPENAI_API_KEY"$'\n'"the-value"$'\n'"EOF"
# The text of a here-document is data: a quote in it that a shell would never close is not a reason
# to let the call through.
denied_set Bash command "secchain set OPENAI_API_KEY <<'EOF'"$'\n'"the-value\""$'\n'"EOF"
denied_set Bash command "secchain set OPENAI_API_KEY <<-EOF"$'\n'$'\t'"the-value'"$'\n'$'\t'"EOF"$'\n'"echo done"
denied_set Bash command "OPENAI_API_KEY=the-value secchain set OPENAI_API_KEY --from-variable"
denied_set Bash command "env OPENAI_API_KEY=the-value secchain set OPENAI_API_KEY --from-variable"
denied_set Bash command "export OPENAI_API_KEY=the-value; secchain set OPENAI_API_KEY --from-variable"
denied_set Bash command "OTHER_KEY=the-value && secchain set OPENAI_API_KEY --from-variable OTHER_KEY"
denied_set Bash command "export OPENAI_API_KEY=the-value; sh -c 'secchain set OPENAI_API_KEY --from-variable'"
denied_set Bash command "bash -c 'echo the-value | secchain set OPENAI_API_KEY'"
denied_set Bash command "cd app && echo the-value | command secchain set OPENAI_API_KEY"
# A newline ends a command the way `;` does.
denied_set Bash command "export OPENAI_API_KEY=the-value"$'\n'"secchain set OPENAI_API_KEY --from-variable"
denied_set Bash command "echo the-value |"$'\n'"  secchain set OPENAI_API_KEY"
# A shell or a run started with the value on its standard input hands it on to the set inside.
denied_set Bash command "echo the-value | sh -c 'secchain set OPENAI_API_KEY'"
denied_set Bash command "sh -c 'secchain set OPENAI_API_KEY' <<< the-value"
denied_set Bash command "echo the-value | secchain run -- secchain set OTHER_KEY"
# Reading the value out of a .env file is refused like any other read of one.
denied Bash command "secchain set OPENAI_API_KEY < .env.local"
denied Bash command "grep OPENAI_API_KEY .env | cut -d= -f2 | secchain set OPENAI_API_KEY"
denied Bash command "source .env && secchain set OPENAI_API_KEY --from-variable"

echo "== a secchain set whose value the agent never sees passes"
allowed Bash command "secchain set OPENAI_API_KEY --from-variable"
allowed Bash command "secchain set OPENAI_API_KEY --from-variable OPENAI_KEY --scope user --env prod"
allowed Bash command "direnv exec . secchain set OPENAI_API_KEY --from-variable"
allowed Bash command "op read 'op://vault/item/credential' | secchain set OPENAI_API_KEY"
allowed Bash command "gh api repos/owner/repo/actions/secrets/public-key --jq .key | secchain set GITHUB_PUBLIC_KEY"
allowed Bash command "openssl rand -hex 32 | secchain set SESSION_SECRET --level confirm"
# An echo in another pipeline of the line feeds nothing into the set.
allowed Bash command "echo 'storing'; openssl rand -hex 32 | secchain set SESSION_SECRET"
allowed Bash command "echo 'storing'"$'\n'"openssl rand -hex 32 | secchain set SESSION_SECRET"
# The lines after a here-document are commands again, whatever its delimiter.
allowed Bash command "cat <<'EOF' > notes.txt"$'\n'"it's \"quoted\""$'\n'"EOF"$'\n'"openssl rand -hex 32 | secchain set SESSION_SECRET"
denied Bash command "cat <<'EOF' > notes.txt"$'\n'"it's"$'\n'"EOF"$'\n'"cat .env"
denied Bash command "cat <<EOF-NOTES > notes.txt"$'\n'"it's"$'\n'"EOF-NOTES"$'\n'"cat .env"
# A shell may run the text of a here-document, so what it would run is checked too.
denied Bash command "bash <<'EOF'"$'\n'"cat .env"$'\n'"EOF"
denied Bash command "bash <<'EOF'"$'\n'"echo \"it's"$'\n'"cat .env"$'\n'"EOF"
denied Bash command "cat <<EOF > notes.txt"$'\n'"\$(cat .env)"$'\n'"EOF"
# A backslash before the newline continues the command instead of ending it.
allowed Bash command "op read 'op://vault/item/credential' \\"$'\n'"  | secchain set OPENAI_API_KEY --scope user"

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
allowed Bash command "declare -p OPENAI_API_KEY"
allowed Write file_path ".env"

echo "== input the hook cannot read decides nothing"
set +e
OUTPUT="$(printf 'not json' | python3 "${HOOK}")"
LAST_STATUS=$?
set -e
[ "${LAST_STATUS}" -eq 0 ] || fail "the hook exited with ${LAST_STATUS} for unreadable input"
[ -z "${OUTPUT}" ] || fail "the hook decided something for unreadable input (${OUTPUT})"

echo "== the calls of the plugin that masks values pass"
allowed Bash command "printf '%s' \"\$text\" | secchain mask"
allowed Bash command "secchain mask --count < tool-result.txt"

echo "== the Claude Mods plugin that masks values is one the engine loads"
# The plugin's checks run in Claude Code itself (issue #70). Function hooks are early access, and
# `claude plugin test` refuses to run without this switch (Claude Code 2.1.283).
command -v claude > /dev/null || fail "claude (Claude Code) is not on PATH; the plugin checks need it"
export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
MODS="${REPOSITORY_ROOT}/skills/secchain/hooks/mods"
set +e
VALIDATION="$(claude plugin validate "${MODS}" 2>&1)"
LAST_STATUS=$?
set -e
printf '%s\n' "${VALIDATION}"
[ "${LAST_STATUS}" -eq 0 ] || fail "claude plugin validate refused the plugin"
printf '%s' "${VALIDATION}" | grep -q 'hooks: prompt.submit, tool.call' || fail "the plugin does not hook prompt.submit and tool.call"

echo "== the plugin masks prompts, tool results and the engine's texts through secchain mask"
claude plugin test "${MODS}" || fail "the plugin's tests failed"

echo "PASS (hooks)"
