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
ENVIRONMENT_DUMPS = frozenset({"env", "printenv"})
# Shell builtins that print that same environment only when they are asked for what they hold. An
# assignment or an option makes them change the shell and print nothing, which is how a script under
# `secchain run` uses them.
ENVIRONMENT_BUILTINS = frozenset({"export", "set", "declare", "typeset"})
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
# Commands that set something up and then run another command, which is the one that matters here.
LAUNCHERS = frozenset({"env", "command", "nohup", "nice", "stdbuf", "time"})
# Language runtimes whose script this hook cannot read. Under `secchain run` an inline script is
# refused rather than guessed at, because printing the environment is one expression in all of them.
INTERPRETERS = frozenset({"python", "python3", "node", "ruby", "perl", "php", "deno", "bun", "osascript"})
# The options those runtimes take a script on the command line with. Options that mean something
# else in one of them (`-E` is inline code in perl and an encoding in ruby) are left out, so that a
# script file is never refused.
INLINE_SCRIPT_OPTIONS = frozenset({"-c", "-e", "--eval"})

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
INLINE_SCRIPT_DENIAL = (
    "SecChain hook: this hook cannot read the script of another language, and under `secchain run` "
    "that script has every secret in its environment. Put it in a file and run "
    "`secchain run -- <interpreter> <file>`."
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
    # `env FOO=bar some-command` sets variables for a command instead of printing them, and after
    # the launcher is removed only a command that really prints is left at the front.
    words = launched_words(command.words)
    name = os.path.basename(words[0]) if words else ""
    if name in ENVIRONMENT_DUMPS:
        return PRINT_DENIAL
    # `-p` is the option that asks a builtin for what it holds. In bash `set -p` is a mode rather
    # than a listing, but a run has no use for it, so the boundary stays one rule for all four.
    if name in ENVIRONMENT_BUILTINS and (len(words) == 1 or "-p" in words[1:]):
        return PRINT_DENIAL
    if name in VALUE_PRINTS and reaches_terminal:
        if any(VARIABLE_REFERENCE.search(word) for word in words[1:]):
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


def launched_words(words):
    """What a line really runs, with the launchers that only prepare its environment removed. Left
    as it is when nothing follows the launcher, because a bare `env` prints the environment."""
    index = 0
    while index < len(words) and os.path.basename(words[index]) in LAUNCHERS:
        index += 1
        while index < len(words) and (words[index].startswith("-") or "=" in words[index]):
            index += 1
    return words[index:] if index < len(words) else words


def scan_nested(command, under_run):
    """The denial for the commands this one starts: the child of `secchain run`, which receives the
    secrets, and the script of a shell."""
    words = launched_words(command.words)
    name = os.path.basename(words[0]) if words else ""
    if name == "secchain" and words[1:2] == ["run"] and "--" in words:
        child = Command()
        child.words = words[words.index("--") + 1 :]
        return scan_pipelines([child], under_run=True)
    if name in SHELLS:
        body = option_value(words, "-c")
        return scan_line(body, under_run) if body else None
    if under_run and name in INTERPRETERS and any(word in INLINE_SCRIPT_OPTIONS for word in words[1:]):
        return INLINE_SCRIPT_DENIAL
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
