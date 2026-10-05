"""Run git in an agent-writable repo via the shared bash primitive cast_git_safe.

CAST hooks run git OUTSIDE the sandbox, in repos an agent can write to. Repo
config (fsmonitor, hooks, filters, ...) can make git execute programs, so the
hardening lives in ONE reviewed place: ``cast_git_safe`` in
``scripts/cast-hook-lib.sh``. This module is a thin wrapper that executes that
bash function -- no second implementation that could drift.

Return-code contract of ``run`` (see the header of cast_git_safe for the bash side):
  2    refused by cast_git_safe: bad args (empty or '-'-leading dir; missing, empty,
       '-'-leading or newline-bearing first git arg) OR a subcommand not on the
       ALLOWLIST (status rev-parse rev-list for-each-ref ls-files cherry branch diff
       diff-files diff-index, and `worktree list` only); git was NOT run
  3    hardening config read failed, or no trusted git binary (fixed list
       /opt/homebrew/bin, /usr/local/bin, /usr/bin; the caller's PATH is never
       consulted; a dir not owned by root or the current user, or world-writable, is skipped) -- from cast_git_safe, OR
       this wrapper could not start it (lib missing, unreadable, not a regular file or group/world-
       writable; bash missing; OSError; NUL in an arg); git was NOT run
  124  timeout; the whole process group was killed; stdout is empty
  126  ``env`` hit ARG_MAX -- from cast_git_safe (fail closed)
  else git's own exit status

Callers MUST treat ANY non-zero return code as "unknown", never as "clean".
"""

from __future__ import annotations

import os
import signal
import stat
import subprocess

# realpath, not abspath: resolve a symlinked scripts/ dir once, so the file checked in
# _lib_problem() is the file bash sources.
LIB = os.path.join(os.path.dirname(os.path.realpath(__file__)), "cast-hook-lib.sh")

_BASH = "/bin/bash"
# Every value reaches bash as an ARGV element ($1 = lib, then dir + git args); none is
# interpolated into this script string.
_SCRIPT = 'source "$1" && shift && cast_git_safe "$@"'
# Variables that make bash (or the lib) run or skip code, so they never reach the child:
#   BASH_ENV  sourced at startup; ENV likewise in some modes
#   SHELLOPTS/BASHOPTS/PS4  PS4 expands command substitutions under SHELLOPTS=xtrace
#   POSIXLY_CORRECT  posix mode changes bash semantics (incl. process substitution, which the
#                    lib relies on)
#   _CAST_HOOK_LIB_LOADED  the lib's source-guard returns early when set, leaving
#                          cast_git_safe UNDEFINED
#   BASH_FUNC_*  bash imports exported functions as code. Observed on /bin/bash 3.2.57:
#                `env 'BASH_FUNC_shift%%=() { echo PWNED; }' /bin/bash -c 'shift'` runs the
#                function, and likewise for `source` -- functions shadow these builtins, so the
#                imported code runs whenever the script calls that name.
_BASH_EXEC_VARS = frozenset(
    {
        "BASH_ENV",
        "ENV",
        "SHELLOPTS",
        "BASHOPTS",
        "PS4",
        "POSIXLY_CORRECT",
        "_CAST_HOOK_LIB_LOADED",
    }
)
_DEFAULT_PATH = "/usr/bin:/bin"
_REAP_GRACE = 2.0


def _failed(cmd: list[str], returncode: int, stderr: str) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(cmd, returncode, stdout="", stderr=stderr)


def _clean_path(path: str) -> str:
    """Keep only absolute PATH entries. An empty entry means the cwd, which an agent controls
    (as does any relative entry), so ``env``/``git`` could be resolved to a planted binary."""
    kept = [p for p in path.split(os.pathsep) if p and os.path.isabs(p)]
    return os.pathsep.join(kept) if kept else _DEFAULT_PATH


def _clean_env() -> dict[str, str]:
    env = {
        k: v
        for k, v in os.environ.items()
        if k not in _BASH_EXEC_VARS and not k.startswith("BASH_FUNC_")
    }
    env["PATH"] = _clean_path(env.get("PATH", ""))
    return env


def _lib_problem(lib: str) -> str | None:
    """Why ``lib`` must not be sourced, or None. It is sourced as code outside the sandbox, so it
    must be a regular, readable file that no other user/group can have rewritten."""
    try:
        st = os.stat(lib)
    except OSError as exc:
        return f"lib missing or unreadable: {lib} ({exc.strerror})"
    if not stat.S_ISREG(st.st_mode) or not os.access(lib, os.R_OK):
        return f"lib is not a readable regular file: {lib}"
    if st.st_mode & 0o022:
        return f"lib is group/world-writable (mode {st.st_mode & 0o7777:04o}): {lib}"
    return None


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

    Returns a CompletedProcess whose stdout/stderr are str, decoded from raw bytes as UTF-8 with
    ``surrogateescape`` and NO newline translation: a ``\\r`` inside a ``-z`` NUL-separated path
    survives, and any non-UTF-8 byte round-trips (``os.fsencode(s)`` recovers the exact bytes).
    Unusable lib (missing, unreadable, not a regular file, group/world-writable), missing bash,
    OSError or a NUL byte in an argument -> returncode 3; timeout -> 124; both with empty
    stdout. TypeError if repo_dir is not a str or args is not a list of str.
    """
    if not isinstance(repo_dir, str):
        raise TypeError(f"repo_dir must be str, got {type(repo_dir).__name__}")
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise TypeError("args must be a list of str")

    cmd = [_BASH, "-c", _SCRIPT, "cast_git_safe", LIB, repo_dir, *args]

    problem = _lib_problem(LIB)
    if problem is not None:
        return _failed(cmd, 3, f"cast_git_safe: {problem}\n")

    try:
        # Own session/process group: on timeout, killing only bash would leave env/git
        # alive holding our stdout pipe, and communicate() would block until it exits.
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_clean_env(),
            start_new_session=True,
        )
    except (OSError, ValueError) as exc:
        return _failed(cmd, 3, f"cast_git_safe: could not run: {exc}\n")

    try:
        out_b, err_b = proc.communicate(timeout=timeout)
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
    # Bytes mode + manual decode: text mode's universal newlines would rewrite \r to \n.
    return subprocess.CompletedProcess(
        cmd,
        proc.returncode,
        stdout=out_b.decode("utf-8", "surrogateescape"),
        stderr=err_b.decode("utf-8", "surrogateescape"),
    )
