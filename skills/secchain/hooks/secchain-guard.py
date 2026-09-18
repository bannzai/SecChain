#!/usr/bin/env python3
"""A Claude Code `PreToolUse` hook that keeps an agent from reaching secret values.

SecChain keeps values in the Keychain and hands them to a child process; `secchain` itself has no
command that prints one. The two ways an agent can still end up with a value in its context are
reading a `.env` file that predates SecChain, and running a command under `secchain run` whose
purpose is to print its environment. This hook denies both.

It reads the hook input as JSON on standard input and, for a call it denies, writes the `PreToolUse`
decision to standard output and exits 0, as
https://code.claude.com/docs/en/hooks describes. For everything else it writes nothing and exits 0,
which leaves the normal permission flow in place.

Usage: secchain-guard.py  (the hook input arrives on standard input)
"""

import json
import os
import re
import shlex
import sys

ENV_FILE_NAME = re.compile(r"^\.env(\..+)?$")
VARIABLE_REFERENCE = re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*")

# Commands whose output is the environment itself, so that the value of every secret of the run
# reaches whoever reads the output.
ENVIRONMENT_DUMPS = frozenset({"env", "printenv", "export", "set", "declare", "typeset"})
# Commands that print their arguments, which exposes a secret only when an argument names one.
VALUE_PRINTS = frozenset({"echo", "printf"})
# Commands that hand what they read on to their own output, so piping into one of them still ends
# with the value in the terminal.
PASS_THROUGH = frozenset(
    {"cat", "tee", "less", "more", "head", "tail", "nl", "od", "xxd", "base64", "strings", "rev", "pbcopy"}
)
# Commands that take a file path without reading its contents, so naming a `.env` file is not a read.
LEAVE_FILE_UNREAD = frozenset({"rm", "mv", "touch", "ls", "stat", "chmod"}) | VALUE_PRINTS
SHELLS = frozenset({"sh", "bash", "zsh", "dash", "ksh"})

SEPARATORS = frozenset({"|", "||", "&&", ";", "&", "(", ")"})

ENV_FILE_DENIAL = (
    "SecChain hook: .env is not where this project's secrets live. "
    "`secchain list` shows the names that are stored, and "
    "`secchain run -- <command>` gives the values to the command that needs them."
)
PRINT_DENIAL = (
    "SecChain hook: this command would print secret values. "
    "Hand them to the program that consumes them instead: `secchain run -- <command>`."
)


class Command:
    """One simple command of a shell line: its words, the files it reads through a redirect, and
    the operator that follows it."""

    def __init__(self):
        self.words = []
        self.reads = []
        self.separator = None

    @property
    def name(self):
        return os.path.basename(self.words[0]) if self.words else ""


def tokenize(line):
    """The words and the operators of a shell line, with quotes resolved the way a shell resolves
    them, so that `sh -c '...'` arrives as one token."""
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def split_into_commands(tokens):
    commands = [Command()]
    redirect = None
    for token in tokens:
        if redirect is not None:
            if "<" in redirect:
                commands[-1].reads.append(token)
            redirect = None
            continue
        is_operator = token and not set(token) - set("<>&|;()")
        if is_operator and ("<" in token or ">" in token):
            redirect = token
            continue
        if is_operator and token in SEPARATORS:
            commands[-1].separator = token
            commands.append(Command())
            continue
        commands[-1].words.append(token)
    return commands


def pipelines(commands):
    """The commands grouped by the pipeline they belong to: only the last command of a pipeline
    writes to the terminal."""
    current = []
    for command in commands:
        current.append(command)
        if command.separator != "|":
            yield current
            current = []
    if current:
        yield current


def option_value(words, option):
    for index, word in enumerate(words):
        if word == option and index + 1 < len(words):
            return words[index + 1]
    return None


def env_file_denial(command):
    named = command.reads if command.name in LEAVE_FILE_UNREAD else command.words[1:] + command.reads
    for word in named:
        if ENV_FILE_NAME.match(os.path.basename(word)):
            return ENV_FILE_DENIAL
    return None


def print_denial(command, reaches_terminal):
    if command.name in ENVIRONMENT_DUMPS:
        # `env FOO=bar some-command` sets variables for a command instead of printing them; every
        # word before that command is either an option or an assignment. The other commands of the
        # set print a value for every name they are given, so an argument does not exempt them.
        runs_a_command = command.name == "env" and any(
            not word.startswith("-") and "=" not in word for word in command.words[1:]
        )
        return None if runs_a_command else PRINT_DENIAL
    if command.name in VALUE_PRINTS and reaches_terminal:
        if any(VARIABLE_REFERENCE.search(word) for word in command.words[1:]):
            return PRINT_DENIAL
    return None


def scan_line(line, under_run):
    """The denial for a shell line, or None. `under_run` says whether the line runs with the
    repository's secrets in its environment, which is what makes printing the environment a leak."""
    try:
        commands = split_into_commands(tokenize(line))
    except ValueError:
        # An unbalanced quote is not a command a shell would run either; deciding nothing here
        # leaves the call to the normal permission flow.
        return None
    return scan_pipelines(commands, under_run)


def scan_pipelines(commands, under_run):
    for pipeline in pipelines(commands):
        last = pipeline[-1]
        for command in pipeline:
            if not command.words:
                continue
            denial = env_file_denial(command)
            if denial is None and under_run:
                # A pipeline ends in the terminal unless its last command consumes what it reads.
                denial = print_denial(command, command is last or last.name in PASS_THROUGH)
            if denial is None:
                denial = scan_nested(command, under_run)
            if denial:
                return denial
    return None


def scan_nested(command, under_run):
    """The denial for the commands this one starts: the child of `secchain run`, which receives the
    secrets, and the script of a shell."""
    if command.name == "secchain" and command.words[1:2] == ["run"] and "--" in command.words:
        child = Command()
        child.words = command.words[command.words.index("--") + 1 :]
        return scan_pipelines([child], under_run=True)
    if command.name in SHELLS:
        body = option_value(command.words, "-c")
        return scan_line(body, under_run) if body else None
    return None


def denial(tool_name, tool_input):
    if tool_name == "Read":
        path = tool_input.get("file_path")
        return ENV_FILE_DENIAL if isinstance(path, str) and ENV_FILE_NAME.match(os.path.basename(path)) else None
    if tool_name == "Bash":
        command = tool_input.get("command")
        return scan_line(command, under_run=False) if isinstance(command, str) else None
    return None


def main():
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        # Input the hook cannot read says nothing about the tool call, and a decision made without
        # reading it would be a guess.
        return 0
    reason = denial(event.get("tool_name", ""), event.get("tool_input") or {})
    if reason is None:
        return 0
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
