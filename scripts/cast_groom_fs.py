"""Filesystem primitives for scripts/cast-branch-groomer.sh (stdlib only; os/stat/sys).

The groomer runs UNSANDBOXED (weekly launchd job) and deletes directories an agent may have been
able to influence, so it needs primitives that bash cannot give safely:

  * lstat never follows a symlink: ``identity`` / ``root-ok`` see the path itself, so a symlink
    swapped in for a directory is refused instead of resolved to its target.
  * rename(2) never copies: ``mv`` silently falls back to copy+delete across filesystems, which
    could duplicate or destroy data; ``os.rename`` simply fails (EXDEV) and the caller keeps the tree.

All paths arrive via argv only (never interpolated into code). Every failure, unknown subcommand
or wrong argument count exits 1 with nothing on stdout (never a traceback).

Subcommands:
  identity PATH   print "dev:ino" and exit 0 iff PATH is a real directory (lstat); else exit 1
  rename SRC DST  os.rename(SRC, DST); exit 0/1
  root-ok PATH    exit 0 iff PATH is a real directory owned by the current user with no
                  group/other write bits; else exit 1
  rmtree-pinned PARENT NAME RADIUS
                  cast_guard.safe_rmtree_pinned: delete the directory PARENT/NAME relative to
                  an O_NOFOLLOW-pinned fd of PARENT (every ancestor pinned, so a symlink swapped
                  in after the check cannot redirect the delete); PARENT must be inside RADIUS and must
                  already be canonical (realpath(PARENT) == normpath(PARENT)), else exit 1.
                  cast_guard.py is loaded by explicit path from this file's directory (the
                  groomer runs us with ``python3 -I``, so no sys.path edits); exit 0/1
"""

import importlib.util
import os
import stat
import sys


def _identity(path):
    s = os.lstat(path)
    if not stat.S_ISDIR(s.st_mode):
        return 1
    print(f"{s.st_dev}:{s.st_ino}")
    return 0


def _rename(src, dst):
    os.rename(src, dst)
    return 0


def _root_ok(path):
    s = os.lstat(path)
    ok = stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid() and not (s.st_mode & 0o022)
    return 0 if ok else 1


def _rmtree_pinned(parent, name, radius):
    guard = os.path.join(os.path.dirname(os.path.realpath(__file__)), "cast_guard.py")
    try:
        spec = importlib.util.spec_from_file_location("cast_guard", guard)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        pinned = module.safe_rmtree_pinned
    except Exception as exc:  # missing/broken guard: refuse, never a traceback
        print(f"rmtree-pinned: cannot load {guard}: {exc}", file=sys.stderr)
        return 1
    # PARENT must already be canonical (no symlink in any component). The callers pass paths they
    # resolved earlier (pwd -P), so a component swapped for a symlink BEFORE this call makes the
    # realpath differ and is refused here; one swapped AFTER this check is refused by the O_NOFOLLOW
    # walk inside safe_rmtree_pinned. (Without this, a swap before the call would move PARENT and
    # RADIUS to the same new location and both would still agree.)
    if os.path.realpath(parent) != os.path.normpath(parent):
        print(f"rmtree-pinned: refusing '{parent}' — not a canonical path (symlink in a component)", file=sys.stderr)
        return 1
    try:
        pinned(parent, name, radius, label="groomer")
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "identity":
            return _identity(argv[2])
        if len(argv) == 4 and argv[1] == "rename":
            return _rename(argv[2], argv[3])
        if len(argv) == 3 and argv[1] == "root-ok":
            return _root_ok(argv[2])
        if len(argv) == 5 and argv[1] == "rmtree-pinned":
            return _rmtree_pinned(argv[2], argv[3], argv[4])
    except OSError as exc:
        if argv[1:2] == ["rmtree-pinned"]:
            print(f"rmtree-pinned: {exc}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
