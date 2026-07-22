#!/usr/bin/env python3
"""
cast-stale-memories.py — canonical stale-memory scanner

Definition: auto-memory files where verified_at > STALE_DAYS days AND
body names a concrete path / function / flag.

Used by:
  - bin/cast doctor (check 9)
  - scripts/cast-session-start-health.sh

Output (stdout):
  Line 1: integer count of stale memories
  Lines 2+: pipe-separated  filepath|verified_at|age_days  (one per stale file, all results)

Exit codes: 0 always — callers decide how to surface results.

Env overrides (for testing):
  CAST_MEMORIES_BASE_DIR  — override ~/.claude/projects (must contain */memory/ subdirs)
  CAST_STALE_DAYS         — override 30
"""

import os
import re
import glob
from datetime import date, datetime

# ── Config ────────────────────────────────────────────────────────────────────
STALE_DAYS = int(os.environ.get("CAST_STALE_DAYS", "30"))
home = os.path.expanduser("~")
base_dir = os.environ.get(
    "CAST_MEMORIES_BASE_DIR",
    os.path.join(home, ".claude", "projects"),
)

# Patterns that indicate a concrete path/function/flag reference in the file body
CONCRETE_PATTERNS = [
    re.compile(r"/scripts/"),
    re.compile(r"~/\.claude/"),
    re.compile(r"~/.claude/"),
    re.compile(r"\b\w+\(\)"),
    re.compile(r"--[a-z]"),
]

# ── Scanner ───────────────────────────────────────────────────────────────────
today = date.today()
stale = []

memory_glob = os.path.join(base_dir, "*", "memory", "*.md")
for filepath in sorted(glob.glob(memory_glob)):
    # Skip the index file — it is a human-edited pointer list, not an auto-memory
    if os.path.basename(filepath) == "MEMORY.md":
        continue

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
    # We strip each line before comparing, so both top-level and nested keys match.
    verified_at = None
    in_frontmatter = False
    lines = content.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if i == 0 and stripped == "---":
            in_frontmatter = True
            continue
        if not in_frontmatter:
            break
        if stripped == "---":
            break  # end of frontmatter
        if stripped.startswith("verified_at:"):
            val = stripped.split(":", 1)[1].strip().strip('"').strip("'")
            try:
                verified_at = datetime.strptime(val, "%Y-%m-%d").date()
            except ValueError:
                pass
            break

    if verified_at is None:
        continue

    age_days = (today - verified_at).days
    if age_days <= STALE_DAYS:
        continue

    # ── Require a concrete reference in the file body ─────────────────────────
    # Search the full content (frontmatter may also contain paths)
    if not any(p.search(content) for p in CONCRETE_PATTERNS):
        continue

    stale.append((filepath, str(verified_at), age_days))

# ── Output ────────────────────────────────────────────────────────────────────
print(len(stale))
for filepath, vdate, age in stale:
    print(f"{filepath}|{vdate}|{age}")
