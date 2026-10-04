"""Run git in an agent-writable repo via the shared bash primitive cast_git_safe.

CAST hooks run git OUTSIDE the sandbox, in repos an agent can write to. Repo
config (fsmonitor, hooks, filters, ...) can make git execute programs, so the
hardening lives in ONE reviewed place: ``cast_git_safe`` in
``scripts/cast-hook-lib.sh``. This module is a thin wrapper that executes that
bash function -- no second implementation that could drift.

Return-code contract of ``run`` (see the header of cast_git_safe for the bash side):
  2    bad args (leading option, empty or '-'-leading dir) -- from cast_git_safe
  3    hardening config read failed (from cast_git_safe), OR this wrapper could
       not start it (lib/bash missing or unreadable, OSError, NUL in an arg);
       git was NOT run
  124  timeout; the whole process group was killed; stdout is empty
  126  ``env`` hit ARG_MAX -- from cast_git_safe (fail closed)
  else git's own exit status

Callers MUST treat ANY non-zero return code as "unknown", never as "clean".
"""

from __future__ import annotations

import os
import signal
import subprocess

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cast-hook-lib.sh")

_BASH = "/bin/bash"
# Every value reaches bash as an ARGV element ($1 = lib, then dir + git args); none is
# interpolated into this script string.
_SCRIPT = 'source "$1" && shift && cast_git_safe "$@"'
# Variables a non-interactive bash obeys by executing/importing code: BASH_ENV is sourced at
# startup; PS4 expands command substitutions under SHELLOPTS=xtrace; BASH_FUNC_* imports
# exported functions that could shadow `source`/`shift`.
_BASH_EXEC_VARS = frozenset({"BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4"})
_REAP_GRACE = 2.0


def _failed(cmd: list[str], returncode: int, stderr: str) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(cmd, returncode, stdout="", stderr=stderr)


def _clean_env() -> dict[str, str]:
    return {
        k: v
        for k, v in os.environ.items()
        if k not in _BASH_EXEC_VARS and not k.startswith("BASH_FUNC_")
    }


def _kill_group(proc: subprocess.Popen) -> None:
    """SIGKILL the child's whole process group (it is its own session leader)."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.kill()
    except OSError:
        pass


def run(repo_dir: str, args: list[str], timeout: float = 10.0) -> subprocess.CompletedProcess:
    """Run ``git -C repo_dir <args>`` through cast_git_safe; never raise for git failure.

    Returns a text-mode CompletedProcess (stdout/stderr decoded with errors="replace").
    Missing lib / bash, OSError or a NUL byte in an argument -> returncode 3; timeout ->
    124; both with empty stdout. TypeError if repo_dir is not a str or args is not a
    list of str.
    """
    if not isinstance(repo_dir, str):
        raise TypeError(f"repo_dir must be str, got {type(repo_dir).__name__}")
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise TypeError("args must be a list of str")

    cmd = [_BASH, "-c", _SCRIPT, "cast_git_safe", LIB, repo_dir, *args]

    if not (os.path.isfile(LIB) and os.access(LIB, os.R_OK)):
        return _failed(cmd, 3, f"cast_git_safe: lib missing or unreadable: {LIB}\n")

    try:
        # Own session/process group: on timeout, killing only bash would leave env/git
        # alive holding our stdout pipe, and communicate() would block until it exits.
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            env=_clean_env(),
            start_new_session=True,
        )
    except (OSError, ValueError) as exc:
        return _failed(cmd, 3, f"cast_git_safe: could not run: {exc}\n")

    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        try:
            proc.communicate(timeout=_REAP_GRACE)
        except subprocess.TimeoutExpired:
            pass  # something left our process group while holding a pipe; give up on it
        return _failed(cmd, 124, "cast_git_safe: timed out\n")
    except BaseException:
        _kill_group(proc)
        raise
    return subprocess.CompletedProcess(cmd, proc.returncode, stdout=stdout, stderr=stderr)
