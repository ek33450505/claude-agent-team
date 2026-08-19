#!/usr/bin/env python3
"""
cast-stale-memories.py — canonical stale-memory scanner

Definition: auto-memory files where verified_at > STALE_DAYS days AND
body names a concrete path / function / flag.

Used by:
  - bin/cast doctor (check 9)
  - scripts/cast-session-start-health.sh
  - scripts/cast-verify-memories.py (CAST v10 C6 re-verifier, via
    scripts/cast_memory_meta.py — the frontmatter parsing shared here lives
    there now; this script imports it)

Output (stdout):
  Line 1: integer count of stale memories
  Lines 2+: pipe-separated  filepath|verified_at|age_days  (one per stale file, all results)

Exit codes: 0 always — callers decide how to surface results.

Env overrides (for testing):
  CAST_MEMORIES_BASE_DIR  — override ~/.claude/projects (must contain */memory/ subdirs)
  CAST_STALE_DAYS         — override 30
"""

import os
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cast_memory_meta  # noqa: E402

# ── Config ────────────────────────────────────────────────────────────────────
STALE_DAYS = int(os.environ.get("CAST_STALE_DAYS", "30"))
home = os.path.expanduser("~")
base_dir = os.environ.get(
    "CAST_MEMORIES_BASE_DIR",
    os.path.join(home, ".claude", "projects"),
)

# ── Scanner ───────────────────────────────────────────────────────────────────
today = date.today()
stale = []

for filepath in cast_memory_meta.iter_memory_files(base_dir):
    try:
        with open(filepath, "r", errors="replace") as fh:
            content = fh.read()
    except OSError:
        continue

    # ── Parse verified_at from YAML-ish frontmatter ──────────────────────────
    # Memory files store verified_at indented under metadata:, e.g.:
    #   ---
    #   name: feedback-foo
    #   metadata:
    #     verified_at: 2026-06-02
    #   ---
    # cast_memory_meta.parse_verified_at strips each line before comparing, so
    # both top-level and nested keys match. See its docstring for the gotcha.
    verified_at = cast_memory_meta.parse_verified_at(content)

    if verified_at is None:
        continue

    age_days = (today - verified_at).days
    if age_days <= STALE_DAYS:
        continue

    # ── Require a concrete reference in the file body ─────────────────────────
    # Search the full content (frontmatter may also contain paths)
    if not cast_memory_meta.has_concrete_ref(content):
        continue

    stale.append((filepath, str(verified_at), age_days))

# ── Output ────────────────────────────────────────────────────────────────────
print(len(stale))
for filepath, vdate, age in stale:
    print(f"{filepath}|{vdate}|{age}")
