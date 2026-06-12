#!/usr/bin/env python3
"""
cast_guard.py — CAST blast-radius write guard (Python).

Provides safe_rmtree(path, blast_radius, label) which removes path only if
it is strictly inside blast_radius. Raises RuntimeError (never calls sys.exit)
on refusal so callers can catch and log.

Import as:
    from cast_guard import safe_rmtree

Matches the cast-guard-lib.sh shell guard contract:
  - Realpath canonicalization (handles symlink escapes automatically)
  - Strictly-inside check: canonical path must start with blast_radius + os.sep
  - Refuse if canonical path equals blast_radius root
  - Hard deny-list: filesystem root, real user home, $HOME/.claude
"""

import os
import shutil
from pathlib import Path


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

    # Hard deny #1: filesystem root
    if canonical_path == "/":
        raise RuntimeError(
            f"FATAL [safe_rmtree]{prefix}: refusing '{str_path}'"
            " — canonical path is filesystem root"
        )

    # Hard deny #2: real user home (os.path.expanduser respects $HOME env var)
    real_home = os.path.realpath(os.path.expanduser("~"))
    if canonical_path == real_home:
        raise RuntimeError(
            f"FATAL [safe_rmtree]{prefix}: refusing '{str_path}'"
            " — canonical path is user home directory"
        )

    # Hard deny #3: $HOME/.claude
    claude_dir = os.path.join(real_home, ".claude")
    if canonical_path == claude_dir:
        raise RuntimeError(
            f"FATAL [safe_rmtree]{prefix}: refusing '{str_path}'"
            " — canonical path is $HOME/.claude"
        )

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
