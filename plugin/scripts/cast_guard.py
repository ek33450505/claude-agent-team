#!/usr/bin/env python3
"""
cast_guard.py — CAST blast-radius write guard (Python).

Provides safe_rmtree(path, blast_radius, label) which removes path only if
it is strictly inside blast_radius (safe_rmtree_pinned additionally pins every
ancestor directory against a symlink swap). Raises RuntimeError (never calls sys.exit)
on refusal so callers can catch and log.

Import as:
    from cast_guard import safe_rmtree, safe_rmtree_pinned

Matches the cast-guard-lib.sh shell guard contract:
  - Realpath canonicalization (handles symlink escapes automatically)
  - Strictly-inside check: canonical path must start with blast_radius + os.sep
  - Refuse if canonical path equals blast_radius root
  - Hard deny-list: filesystem root, real user home, $HOME/.claude
"""

import os
import shutil
import stat
from pathlib import Path


def _refuse_hard_denied(fn: str, canonical_path: str, str_path: str, prefix: str) -> None:
    """Raise RuntimeError if canonical_path is the root, real home, or $HOME/.claude."""
    # Hard deny #1: filesystem root
    if canonical_path == "/":
        raise RuntimeError(
            f"FATAL [{fn}]{prefix}: refusing '{str_path}'"
            " — canonical path is filesystem root"
        )

    # Hard deny #2: real user home (os.path.expanduser respects $HOME env var)
    real_home = os.path.realpath(os.path.expanduser("~"))
    if canonical_path == real_home:
        raise RuntimeError(
            f"FATAL [{fn}]{prefix}: refusing '{str_path}'"
            " — canonical path is user home directory"
        )

    # Hard deny #3: $HOME/.claude
    claude_dir = os.path.join(real_home, ".claude")
    if canonical_path == claude_dir:
        raise RuntimeError(
            f"FATAL [{fn}]{prefix}: refusing '{str_path}'"
            " — canonical path is $HOME/.claude"
        )


def safe_rmtree(
    path: "str | Path",
    blast_radius: "str | Path",
    label: str = "",
) -> None:
    """Remove path recursively only if strictly inside blast_radius.

    Args:
        path: Target path to remove.
        blast_radius: Declared allowed root. path must be strictly inside this.
        label: Human-readable guard label (e.g. "snapshot rotation").
               Included in error messages for diagnostics.

    Raises:
        RuntimeError: Message starts with "FATAL [safe_rmtree]" on any refusal.
                      Does NOT call sys.exit — callers decide how to handle.
    """
    prefix = f" [{label}]" if label else ""
    str_path = str(path)
    str_radius = str(blast_radius)

    # Canonicalize blast_radius (resolve symlinks, e.g. /tmp → /private/tmp on macOS)
    canonical_radius = os.path.realpath(str_radius)

    # Canonicalize path.
    # If target exists or is a symlink, realpath resolves it fully (catches symlink escapes).
    # If target does not exist, canonicalize parent + append basename.
    if os.path.exists(str_path) or os.path.islink(str_path):
        canonical_path = os.path.realpath(str_path)
    else:
        parent = os.path.dirname(str_path) or "."
        basename = os.path.basename(str_path)
        canonical_path = os.path.join(os.path.realpath(parent), basename)

    _refuse_hard_denied("safe_rmtree", canonical_path, str_path, prefix)

    # Check: canonical path must not equal blast_radius root (must be strictly inside)
    if canonical_path == canonical_radius:
        raise RuntimeError(
            f"FATAL [safe_rmtree]{prefix}: refusing '{str_path}'"
            f" — path equals blast radius root '{canonical_radius}'"
            " (must be strictly inside)"
        )

    # Check: canonical path must be strictly inside blast_radius.
    # Append os.sep to avoid prefix collisions (e.g. /tmp/abc not inside /tmp/ab).
    radius_prefix = canonical_radius.rstrip(os.sep) + os.sep
    if not canonical_path.startswith(radius_prefix):
        raise RuntimeError(
            f"FATAL [safe_rmtree]{prefix}: refusing '{str_path}'"
            f" — '{canonical_path}' is outside blast radius '{canonical_radius}'"
        )

    # All checks passed — remove the target
    shutil.rmtree(canonical_path)


def _open_dir_pinned(canonical_path: str) -> int:
    """Open canonical_path component by component from "/" without following symlinks.

    Every component is opened with O_NOFOLLOW|O_DIRECTORY relative to the fd of
    the previous one, so a symlink (or non-directory) at ANY level — including an
    ancestor swapped in after the caller's realpath check — makes os.open raise
    OSError instead of redirecting. Returns an fd for the final directory.
    """
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for comp in canonical_path.split(os.sep):
            if not comp:
                continue
            nfd = os.open(comp, flags, dir_fd=fd)
            os.close(fd)
            fd = nfd
    except BaseException:
        os.close(fd)
        raise
    return fd


def safe_rmtree_pinned(
    parent: "str | Path",
    name: str,
    blast_radius: "str | Path",
    label: str = "",
) -> None:
    """Remove the directory parent/name, immune to a symlink swap of any ancestor.

    safe_rmtree resolves the path, checks it, then calls shutil.rmtree on the
    ABSOLUTE canonical path — so the kernel re-resolves every ancestor at delete
    time, and a parent component swapped for a symlink between check and delete
    redirects the delete. This variant closes that window: after the realpath
    check it walks parent from "/" with O_NOFOLLOW|O_DIRECTORY fds (see
    _open_dir_pinned; any symlinked/non-directory component refuses), lstat()s
    name relative to the pinned fd (must be a real directory, not a symlink),
    then fchdir()s into the pinned fd and removes the RELATIVE name. The previous
    cwd is restored afterwards.

    Python 3.9 constraint: /usr/bin/python3 (3.9.6) may run this from launchd, so
    shutil.rmtree(dir_fd=) (3.11+) is not used; fchdir + relative rmtree is
    equivalent (shutil.rmtree.avoids_symlink_attacks is True on 3.9 and newer).

    Args:
        parent: Directory containing the target. Must be inside (or equal to)
                blast_radius after realpath.
        name: A single path component — the directory entry to remove.
        blast_radius: Declared allowed root.
        label: Human-readable guard label for diagnostics.

    Raises:
        RuntimeError: Message starts with "FATAL [safe_rmtree_pinned]" on any
                      refusal. Does NOT call sys.exit.
    """
    prefix = f" [{label}]" if label else ""
    str_target = os.path.join(str(parent), str(name))

    def refuse(reason: str) -> RuntimeError:
        return RuntimeError(f"FATAL [safe_rmtree_pinned]{prefix}: refusing '{str_target}' — {reason}")

    if (
        not isinstance(name, str)
        or name in ("", ".", "..")
        or os.sep in name
        or "\0" in name
    ):
        raise refuse("name must be a single path component")

    canonical_radius = os.path.realpath(str(blast_radius))
    canonical_parent = os.path.realpath(str(parent))
    radius_prefix = canonical_radius.rstrip(os.sep) + os.sep
    if canonical_parent != canonical_radius and not canonical_parent.startswith(radius_prefix):
        raise refuse(f"parent '{canonical_parent}' is outside blast radius '{canonical_radius}'")

    canonical_target = os.path.join(canonical_parent, name)
    _refuse_hard_denied("safe_rmtree_pinned", canonical_target, str_target, prefix)

    cwd_fd = -1
    dir_fd = -1
    try:
        try:
            dir_fd = _open_dir_pinned(canonical_parent)
            st = os.lstat(name, dir_fd=dir_fd)
            if not stat.S_ISDIR(st.st_mode):
                raise refuse("target is not a real directory (symlink or file)")
            cwd_fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        except OSError as exc:
            raise refuse(f"cannot pin parent directory ({exc})") from exc
        os.fchdir(dir_fd)
        try:
            shutil.rmtree(name)
        finally:
            os.fchdir(cwd_fd)
    finally:
        if dir_fd >= 0:
            os.close(dir_fd)
        if cwd_fd >= 0:
            os.close(cwd_fd)
