#!/usr/bin/env python3
"""
cast_memory_meta.py — shared frontmatter parsing for auto-memory files.

Extracted from scripts/cast-stale-memories.py so scripts/cast-verify-memories.py
(CAST v10 item C6) can reuse the identical verified_at parser instead of
duplicating it.

⚠️ THE GOTCHA THIS ENCODES: verified_at: is INDENTED under metadata: in the
real file format, e.g.:

    ---
    name: feedback-foo
    metadata:
      verified_at: 2026-06-02
    ---

Each line MUST be .strip()'d before the startswith("verified_at:") check —
getting this wrong is the documented difference between finding 0 stale
memories and finding 14 (reference_memory_verified_at_parse_gotcha).

No I/O side effects at import time — callers pass their own base_dir.
"""

import glob
import os
import re
from datetime import date, datetime
from typing import List, Optional

# Patterns that indicate a concrete path/function/flag reference in a memory body.
CONCRETE_PATTERNS = [
    re.compile(r"/scripts/"),
    re.compile(r"~/\.claude/"),
    re.compile(r"~/.claude/"),
    re.compile(r"\b\w+\(\)"),
    re.compile(r"--[a-z]"),
]


def parse_verified_at(content: str) -> Optional[date]:
    """Parse the verified_at date from a memory file's YAML-ish frontmatter.

    Handles both a top-level `verified_at:` key and one indented under
    `metadata:` — every line is .strip()'d before comparison so indentation
    never hides the key. Returns None when the key is absent, the frontmatter
    block is absent/malformed, or the date value fails to parse as
    %Y-%m-%d.
    """
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
                return datetime.strptime(val, "%Y-%m-%d").date()
            except ValueError:
                return None
    return None


def has_concrete_ref(content: str) -> bool:
    """True if content contains at least one concrete path/function/flag ref."""
    return any(p.search(content) for p in CONCRETE_PATTERNS)


def iter_memory_files(base_dir: str) -> List[str]:
    """Return sorted memory .md filepaths under base_dir, skipping MEMORY.md.

    Globs `<base_dir>/*/memory/*.md`. Performs no file I/O beyond the glob
    itself — callers are responsible for opening/reading each file.
    """
    memory_glob = os.path.join(base_dir, "*", "memory", "*.md")
    return [
        fp
        for fp in sorted(glob.glob(memory_glob))
        if os.path.basename(fp) != "MEMORY.md"
    ]
