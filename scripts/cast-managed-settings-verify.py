#!/usr/bin/env python3
"""Verify CAST's root-owned Claude Code managed settings file (G5).

Usage:
    python3 -I scripts/cast-managed-settings-verify.py [--source] [--repo DIR]
                                                       [--installed PATH]
                                                       [--print-install] [--print-floor-hash]
                                                       [--check-onfailure]

Source checks (always run) validate macos/managed-settings.json against the
user fragments managed-settings.d/11-deny.json and 25-hooks-security.json,
and against the code-pinned FLOOR_SHA256 (two independent checks).
Installed checks (skipped with --source) verify the installed copy is a
root-owned, non-writable, readable regular file identical to the source.

--check-onfailure is the install.sh gate: it reads ONLY the installed managed
file and fails (exit 1) unless every CAST enforcement hook in it carries
"onFailure": "block". The highest-scope copy of an identical hook command wins,
so a stale managed copy (no onFailure) cancels the user copy's block. An absent
file is fine (nothing at a higher scope); unreadable/malformed fails closed.
No owner/mode/ACL/byte-identity checks (that is the full mode).

Prints one OK:/FAIL: line per check. Exit 0 only if every check passes; any
failure or unexpected exception exits 1 (fail closed).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
from typing import Any, List, Tuple

DEFAULT_INSTALLED = "/Library/Application Support/ClaudeCode/managed-settings.json"
EXTRA_DENY = "Edit(//Library/Application Support/ClaudeCode/**)"
POLICY_DENY = {"Bash(pkill *)", "Bash(killall *)"}
# Hash pin of the WHOLE managed document (denies in order + hook events): sha256
# of its canonical JSON (see _canonical_sha256). A change to the denies or guard
# hooks is a reviewed edit of three places: the fragment,
# macos/managed-settings.json, and this constant. Recompute it with
# --print-floor-hash.
FLOOR_SHA256 = "fa6bffd579ed4e3c84ad43121bb110885e37708bd5d90fd186cb37e3b36e507a"
REQUIRED_IDS = ("cast-pretool-dispatch", "cast-write-guards")
# Script basenames of the three fail-closed CAST guards (ConfigChange guard, PreToolUse
# dispatcher, Write/Edit guards). Matched as a SUBSTRING of any "command" string anywhere in
# the managed document, so a respelled command (extra spaces, absolute path) or an unusual
# JSON shape still counts as a CAST registration (Claude Code dedupes by command, and its
# normalisation is unprobed). Over-matching fails closed.
ONFAILURE_BASENAMES = (
    "cast-config-change-guard.sh",
    "cast-pretool-dispatch.py",
    "write-guards.sh",
)
ACL_LINE = re.compile(r"^\s*\d+: ")

Result = Tuple[bool, str]


def _read_regular(path: str) -> bytes:
    """Read a regular file via one fd (O_NONBLOCK so a FIFO cannot hang us)."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(f"{path} is not a regular file")
        with os.fdopen(fd, "rb", closefd=False) as fh:
            return fh.read()
    finally:
        os.close(fd)


def _no_dup_keys(pairs: List[Tuple[str, Any]]) -> dict:
    out: dict = {}
    for k, v in pairs:
        if k in out:
            raise ValueError(f"duplicate JSON key {k!r}")
        out[k] = v
    return out


def _reject_constant(name: str) -> Any:
    raise ValueError(f"non-standard JSON constant: {name}")


def _load(path: str) -> Any:
    return json.loads(_read_regular(path).decode("utf-8"),
                      object_pairs_hook=_no_dup_keys, parse_constant=_reject_constant)


def _is_policy(entry: Any) -> bool:
    """Policy (not self-protection) denies that stay in the user fragments."""
    return isinstance(entry, str) and (entry.startswith("Agent(model:") or entry in POLICY_DENY)


def build_expected(repo: str) -> dict:
    """Derive the exact managed document from the user fragments."""
    deny_doc = _load(os.path.join(repo, "managed-settings.d", "11-deny.json"))
    hooks_doc = _load(os.path.join(repo, "managed-settings.d", "25-hooks-security.json"))
    deny = [e for e in deny_doc["permissions"]["deny"] if not _is_policy(e)] + [EXTRA_DENY]
    hooks = hooks_doc["hooks"]
    pre = [e for e in hooks["PreToolUse"] if isinstance(e, dict) and e.get("id") in REQUIRED_IDS]
    found = {e["id"] for e in pre}
    if found != set(REQUIRED_IDS):
        raise ValueError(f"fragment missing required PreToolUse ids: {sorted(set(REQUIRED_IDS) - found)}")
    return {
        "permissions": {"deny": deny},
        "hooks": {"ConfigChange": hooks["ConfigChange"], "PreToolUse": pre},
    }


def _diff_hint(want: Any, got: Any, path: str = "$") -> List[str]:
    if isinstance(want, dict) and isinstance(got, dict):
        out: List[str] = []
        for k in sorted(set(want) | set(got)):
            if k not in got:
                out.append(f"{path}.{k} missing")
            elif k not in want:
                out.append(f"{path}.{k} unexpected")
            else:
                out += _diff_hint(want[k], got[k], f"{path}.{k}")
        return out
    if isinstance(want, list) and isinstance(got, list):
        out = []
        for i in range(max(len(want), len(got))):
            if i >= len(got):
                out.append(f"{path}[{i}] missing")
            elif i >= len(want):
                out.append(f"{path}[{i}] unexpected")
            else:
                out += _diff_hint(want[i], got[i], f"{path}[{i}]")
        return out
    return [] if want == got and type(want) is type(got) else [f"{path} differs"]


def _canonical_sha256(doc: Any) -> str:
    blob = json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def floor_check(src: Any) -> Result:
    """Strict (type-exact) match with the code-pinned FLOOR_SHA256."""
    if _canonical_sha256(src) == FLOOR_SHA256:
        return (True, "floor: managed document hash matches the code-pinned FLOOR_SHA256")
    return (False, "floor: managed document hash differs from the code-pinned FLOOR_SHA256 (see the source check for which path differs)")


def source_checks(repo: str) -> List[Result]:
    src_path = os.path.join(repo, "macos", "managed-settings.json")
    try:
        src = _load(src_path)
    except (OSError, ValueError) as exc:
        return [(False, f"source {src_path} unreadable or malformed JSON: {exc}")]
    try:
        expected = build_expected(repo)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return [(False, f"cannot derive expected document from fragments: {type(exc).__name__}: {exc}")]

    results: List[Result] = []
    if src == expected and json.dumps(src) == json.dumps(expected):
        results.append((True, "source equals the document derived from the user fragments"))
    else:
        hint = _diff_hint(expected, src)[:10]
        results.append((False, "source differs from fragment-derived document (update macos/managed-settings.json by hand and FLOOR_SHA256 in scripts/cast-managed-settings-verify.py until --source passes, then reinstall): " + "; ".join(hint)))

    results.append(floor_check(src))
    return results


def _owner_mode_problems(st: os.stat_result) -> List[str]:
    problems = []
    if st.st_uid != 0:
        problems.append(f"owned by uid {st.st_uid}, not root (0)")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        problems.append(f"group/other writable (mode {stat.S_IMODE(st.st_mode):04o})")
    return problems


def _acl_problems(path: str) -> List[str]:
    try:
        r = subprocess.run(["/bin/ls", "-led", path], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        return [f"cannot inspect ACLs ({exc})"]
    if r.returncode != 0:
        return [f"cannot inspect ACLs (ls exit {r.returncode})"]
    lines = r.stdout.splitlines()[1:]
    if any(ACL_LINE.match(ln) for ln in lines):
        return ["has ACL entries"]
    return []


def installed_checks(repo: str, installed: str) -> List[Result]:
    results: List[Result] = []
    data = None
    problems: List[str] = []
    try:
        fd = os.open(installed, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        problems.append(f"cannot open (missing, symlink, or unreadable; Claude Code silently ignores an unreadable managed file): {exc}")
    else:
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                problems.append("not a regular file")
            else:
                problems += _owner_mode_problems(st)
                with os.fdopen(fd, "rb", closefd=False) as fh:
                    data = fh.read()
        finally:
            os.close(fd)
        problems += _acl_problems(installed)
    if problems:
        results.append((False, f"installed file {installed}: " + "; ".join(problems)))
    else:
        results.append((True, "installed file is a root-owned, non-writable, ACL-free regular file"))

    parent = os.path.dirname(installed)
    try:
        pst = os.lstat(parent)
    except OSError as exc:
        results.append((False, f"parent dir {parent} missing: {exc}"))
    else:
        pprob: List[str] = []
        if stat.S_ISLNK(pst.st_mode) or not stat.S_ISDIR(pst.st_mode):
            pprob.append("not a real directory (symlink or other)")
        else:
            pprob += _owner_mode_problems(pst) + _acl_problems(parent)
        if pprob:
            results.append((False, f"parent dir {parent}: " + "; ".join(pprob)))
        else:
            results.append((True, "parent dir is a root-owned, non-writable, ACL-free directory"))

    try:
        want = _read_regular(os.path.join(repo, "macos", "managed-settings.json"))
    except OSError as exc:
        results.append((False, f"cannot read source for comparison: {exc}"))
    else:
        if data is None:
            results.append((False, "installed bytes unavailable for comparison"))
        elif want == data:
            results.append((True, "installed bytes identical to source"))
        else:
            results.append((False, "installed bytes differ from source (re-run install)"))
    return results


def onfailure_check(installed: str) -> List[Result]:
    """Fail unless every CAST enforcement hook in the INSTALLED managed file
    carries onFailure=block (absent file passes: nothing outranks the user copy)."""
    try:
        fd = os.open(installed, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return [(True, f"no managed settings at {installed}; nothing at a higher scope can cancel onFailure:block")]
    except OSError as exc:
        return [(False, f"cannot open {installed} (symlink or unreadable; fail closed): {exc}")]
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return [(False, f"{installed} is not a regular file (fail closed)")]
        with os.fdopen(fd, "rb", closefd=False) as fh:
            raw = fh.read()
    except OSError as exc:
        return [(False, f"cannot read {installed} (fail closed): {exc}")]
    finally:
        os.close(fd)
    try:
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_dup_keys,
                         parse_constant=_reject_constant)
    except (ValueError, UnicodeDecodeError, RecursionError) as exc:
        return [(False, f"{installed} is malformed (fail closed): {exc}")]

    # Walk the WHOLE document (dicts and lists, any depth, explicit stack): an
    # entry in any shape whose "command" mentions a CAST guard script is a CAST
    # registration and must itself carry onFailure=block. Over-matching fails closed.
    found: List[Tuple[str, Any]] = []
    stack: List[Any] = [doc]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            cmd = node.get("command")
            if cmd is not None:
                # A non-str command (e.g. an argv list) is serialised so a basename inside
                # it still marks a CAST registration (the except below is unreachable after json.loads).
                try:
                    text = cmd if isinstance(cmd, str) else json.dumps(cmd)
                except (TypeError, ValueError):
                    text = ""
                if any(b in text for b in ONFAILURE_BASENAMES):
                    found.append((cmd if isinstance(cmd, str) else text, node.get("onFailure")))
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    results: List[Result] = []
    for cmd, val in sorted(found, key=lambda t: t[0]):
        if isinstance(val, str) and val == "block":
            results.append((True, f"managed hook {cmd!r} carries onFailure=block"))
        else:
            results.append((False, f"managed hook {cmd!r} lacks onFailure=block (got {val!r}); "
                                   "it would CANCEL the user copy's block"))
    if not results:
        results.append((True, "managed file registers no CAST enforcement hooks; nothing cancels onFailure:block"))
    return results


def main(argv: List[str]) -> int:
    default_repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description="Verify CAST managed settings")
    ap.add_argument("--source", action="store_true", help="source checks only")
    ap.add_argument("--repo", default=default_repo)
    ap.add_argument("--installed", default=DEFAULT_INSTALLED)
    ap.add_argument("--print-install", action="store_true", help="print install commands (after source checks)")
    ap.add_argument("--check-onfailure", action="store_true", help="install gate: installed managed hooks must carry onFailure=block")
    ap.add_argument("--print-floor-hash", action="store_true", help="print the canonical sha256 of the source file (hash only, no validation against the fragments; run --source first)")
    args = ap.parse_args(argv)

    if args.print_floor_hash:
        try:
            print(_canonical_sha256(_load(os.path.join(args.repo, "macos", "managed-settings.json"))))
        except (OSError, ValueError) as exc:
            print(f"FAIL: cannot load source: {exc}")
            return 1
        return 0

    if args.check_onfailure:
        results = onfailure_check(args.installed)
        for passed, msg in results:
            print(f"{'OK' if passed else 'FAIL'}: {msg}")
        return 0 if all(p for p, _ in results) else 1

    results = source_checks(args.repo)
    if not (args.source or args.print_install):
        results += installed_checks(args.repo, args.installed)

    ok = True
    for passed, msg in results:
        ok = ok and passed
        print(f"{'OK' if passed else 'FAIL'}: {msg}")

    if args.print_install:
        if not ok:
            print("FAIL: refusing to print install commands while source checks fail")
            return 1
        src = shlex.quote(os.path.join(os.path.abspath(args.repo), "macos", "managed-settings.json"))
        dest = shlex.quote(args.installed)
        print("# Run from a COMMITTED, clean tree, and read the source file first.")
        print("# Run in a separate terminal (not via ! inside Claude), then `sudo -k`.")
        # Short variable-based lines: one long sudo line wrapped on paste and failed.
        print(f"SRC={src}")
        print(f"DEST={dest}")
        # `--` so a leading-dash DEST is a path, not an option, for dirname/install.
        print('sudo mkdir -p "$(dirname -- "$DEST")"')
        print('sudo install -o root -g wheel -m 0644 -- "$SRC" "$DEST"')
        print("sudo -k")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except BaseException as exc:  # fail closed
        print(f"FAIL: unexpected error: {type(exc).__name__}: {exc}")
        sys.exit(1)
