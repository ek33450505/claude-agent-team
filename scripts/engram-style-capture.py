#!/usr/bin/env python3
"""
engram-style-capture.py
Called by PostToolUse(Write|Edit) hook.
Detects style correction keywords in recent user prompts and writes preference signals.
Stdin: Claude Code hook JSON payload.
"""
# Copyright 2026 Edward Kubiak
# Apache-2.0 License

import sys
import json
import os
import time
from pathlib import Path

# Locate engram project — exit gracefully if not installed
ENGRAM_DIR = Path.home() / "Projects" / "personal" / "project-engram"
if not ENGRAM_DIR.exists():
    sys.exit(0)  # engram not installed, skip gracefully
sys.path.insert(0, str(ENGRAM_DIR))
from src.db import get_connection, SOUL_DB_PATH

_SENTINEL_MAX_BYTES = 32 * 1024  # 32KB
_SENTINEL_MAX_AGE_SECS = 60


def safe_read_sentinel(sentinel_path: Path) -> str:
    """Read sentinel file with security checks.

    Rejects files that:
    - Do not exist
    - Are not owned by the current process UID
    - Exceed 32KB
    - Were last modified more than 60 seconds ago

    Returns the stripped file text, with null bytes removed. Returns empty string on any failure.
    """
    try:
        if not sentinel_path.exists():
            return ""
        st = sentinel_path.stat()
        # Ownership check: must be owned by current UID
        if st.st_uid != os.getuid():
            return ""
        # Size check: reject files larger than 32KB
        if st.st_size > _SENTINEL_MAX_BYTES:
            return ""
        # Recency check: reject files not modified within the last 60 seconds
        if time.time() - st.st_mtime > _SENTINEL_MAX_AGE_SECS:
            return ""
        content = sentinel_path.read_text(encoding="utf-8")
        # Strip null bytes
        content = content.replace("\x00", "")
        return content.strip()
    except OSError:
        return ""

STYLE_CORRECTIONS: dict[str, list[str]] = {
    "brevity": ["simpler", "shorter", "brief", "concise"],
    "plainness": ["strip", "just say", "plain", "no narrative", "cut"],
    "negation": ["don't", "not that", "stop doing", "remove"],
    "directness": ["direct", "just say", "straight", "simply"],
}

# Groups that map to verbosity_preference field
_VERBOSITY_GROUPS = {"brevity"}


def _field_name_for_group(group: str) -> str:
    return "verbosity_preference" if group in _VERBOSITY_GROUPS else "communication_style"


def _is_duplicate(conn, raw_excerpt: str, session_id: str | None) -> bool:
    """Check if the same raw_excerpt was written in the last 10 rows (for this session)."""
    rows = conn.execute(
        """
        SELECT raw_excerpt FROM identity_signals
        WHERE signal_type = 'preference'
        ORDER BY id DESC LIMIT 10
        """,
    ).fetchall()
    return any(r["raw_excerpt"] == raw_excerpt for r in rows)


def capture_style_signals(
    prompt_preview: str,
    db_path: Path = SOUL_DB_PATH,
    session_id: str | None = None,
    agent_name: str | None = None,
) -> list[dict]:
    """
    Scan prompt_preview for style correction keywords.
    Returns list of signals written (may be empty if no match or duplicate).
    When agent_name is provided, signals are tagged as agent-scoped.
    """
    if not prompt_preview or not prompt_preview.strip():
        return []

    if len(prompt_preview.strip()) < 20:
        return []

    conn = get_connection(db_path)

    # Consent gate — do not capture style signals without explicit consent
    from src.consent import has_consent
    if not has_consent(conn):
        return []

    prompt_lower = prompt_preview.lower()

    written: list[dict] = []
    for group, keywords in STYLE_CORRECTIONS.items():
        matched = any(kw in prompt_lower for kw in keywords)
        if not matched:
            continue

        raw_excerpt = prompt_preview[:200]
        if _is_duplicate(conn, raw_excerpt, session_id):
            continue

        sig = {
            "signal_type": "preference",
            "signal_scope": "universal",
            "field_name": _field_name_for_group(group),
            "confidence": 0.6,
            "raw_excerpt": raw_excerpt,
            "session_id": session_id,
            "agent_name": agent_name,
            "source": "style_capture",
        }
        conn.execute(
            """
            INSERT INTO identity_signals
                (signal_type, signal_scope, field_name, confidence, raw_excerpt, session_id, agent_name, source)
            VALUES
                (:signal_type, :signal_scope, :field_name, :confidence, :raw_excerpt, :session_id, :agent_name, :source)
            """,
            sig,
        )
        conn.commit()
        written.append(sig)
        # Only write one signal per prompt (first matching group wins dedup check)
        break

    return written


def main() -> None:
    """Read hook payload from stdin; extract style signals from prompt preview."""
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    # Try env var first, then sentinel file
    prompt_preview = os.environ.get("CAST_LAST_PROMPT_PREVIEW", "")

    if not prompt_preview:
        sentinel = Path.home() / ".claude" / "engram-last-prompt.txt"
        prompt_preview = safe_read_sentinel(sentinel)

    if not prompt_preview:
        sys.exit(0)

    session_id = os.environ.get("CLAUDE_SESSION_ID")
    agent_name = os.environ.get("ENGRAM_AGENT_NAME") or os.environ.get("CAST_AGENT_NAME") or None
    db_path = os.environ.get("ENGRAM_DB_PATH")
    if db_path:
        db_path = Path(db_path)
    capture_style_signals(prompt_preview, db_path=db_path, session_id=session_id, agent_name=agent_name)
    sys.exit(0)


if __name__ == "__main__":
    main()
