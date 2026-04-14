#!/usr/bin/env python3
"""
engram-journal-extractor.py
Called by PostToolUse(Write) hook when a journal file is written.
Stdin: Claude Code hook JSON payload with tool result info.
Writes: identity_signals rows to engram.db, open threads to engram-open-threads.jsonl.
"""
# Copyright 2026 Edward Kubiak
# Apache-2.0 License

import sys
import json
import re
import os
from datetime import date
from pathlib import Path

# Locate engram project — exit gracefully if not installed
ENGRAM_DIR = Path.home() / "Projects" / "personal" / "project-engram"
if not ENGRAM_DIR.exists():
    sys.exit(0)  # engram not installed, skip gracefully
sys.path.insert(0, str(ENGRAM_DIR))
from src.db import get_connection, SOUL_DB_PATH

CORRECTION_PATTERNS = [
    r"I noticed\b",
    r"I defaulted to\b",
    r"my instinct was\b",
    r"I over-built\b",
    r"Ed corrected\b",
    r"recalibrate\b",
    r"course correction\b",
]

THREAD_PATTERNS = [
    r"worth watching\b",
    r"open thread[:\s]",
    r"one thing I want to note\b",
    r"a question I don't\b",
    r"unresolved\b",
    r"I want to return\b",
]

RELATIONAL_PATTERNS = [
    r"the ['\"]we['\"]",
    r"collaboration has matured\b",
    r"first time (touching|working|seeing|using)\b",
    r"naturally used\b",
    r"trust (level|between|earned|provenance)\b",
]

AESTHETIC_PATTERNS = [
    r"stripped down\b",
    r"over-built\b",
    r"plain statement\b",
    r"simpler (approach|version|is better)\b",
    r"shorter\b",
    r"economy\b",
    r"completeness (instinct|trap|over)\b",
]

_PATTERN_MAP = [
    ("correction", CORRECTION_PATTERNS, 0.9),
    ("style_observation", THREAD_PATTERNS, 0.7),
    ("relationship_event", RELATIONAL_PATTERNS, 0.7),
    ("preference", AESTHETIC_PATTERNS, 0.7),
]


def _split_sentences(text: str) -> list[str]:
    """Split text into sentences by . ! ? delimiters."""
    parts = re.split(r"[.!?]", text)
    return [p.strip() for p in parts if p.strip()]


def extract_signals(journal_path: Path, db_path: Path = SOUL_DB_PATH,
                    threads_file: Path | None = None,
                    agent_name: str | None = None) -> list[dict]:
    """
    Read journal_path and extract behavioral signals.
    Returns list of signal dicts ready to insert into identity_signals.
    Also appends unresolved thread entries to threads_file (JSONL).
    When agent_name is provided, all extracted signals are tagged with that agent.
    """
    text = journal_path.read_text(encoding="utf-8")

    # Dedup: skip if this journal has already been extracted
    conn = get_connection(db_path)
    already = conn.execute(
        "SELECT 1 FROM extraction_log WHERE source_path = ?",
        (str(journal_path),)
    ).fetchone()
    if already:
        return []

    sentences = _split_sentences(text)
    session_id = os.environ.get("CLAUDE_SESSION_ID")

    signals: list[dict] = []
    seen_excerpts: set[str] = set()

    # Load existing excerpts from DB to prevent cross-run duplicates
    existing_excerpts: set[str] = set()
    try:
        rows = conn.execute(
            'SELECT raw_excerpt FROM identity_signals WHERE source = ?',
            (str(journal_path),)
        ).fetchall()
        existing_excerpts = {row['raw_excerpt'] for row in rows if row['raw_excerpt']}
    except Exception:
        pass

    for sentence in sentences:
        for signal_type, patterns, confidence in _PATTERN_MAP:
            for pattern in patterns:
                if re.search(pattern, sentence, re.IGNORECASE):
                    excerpt = sentence[:200]
                    if excerpt in seen_excerpts or excerpt in existing_excerpts:
                        break
                    seen_excerpts.add(excerpt)

                    # Use higher confidence for explicit correction phrases
                    effective_confidence = confidence
                    if signal_type == "correction":
                        effective_confidence = 0.9

                    sig = {
                        "signal_type": signal_type,
                        "signal_scope": "universal",
                        "field_name": None,
                        "confidence": effective_confidence,
                        "raw_excerpt": excerpt,
                        "session_id": session_id,
                        "agent_name": agent_name,
                        "source": str(journal_path),
                    }
                    signals.append(sig)

                    # Write open threads to DB table
                    if signal_type == "style_observation":
                        _append_thread(conn, excerpt, str(journal_path), session_id)
                    break  # only one match per signal_type per sentence

    # Write signals to db
    if signals:
        _write_signals(signals, db_path)

    return signals


def _append_thread(conn, thread_text: str, source_path: str, session_id: str | None) -> None:
    """Insert an unresolved thread entry into the open_threads DB table."""
    try:
        conn.execute(
            """INSERT INTO open_threads (thread, resolved, date, source)
               VALUES (?, 0, date('now'), ?)""",
            (thread_text, "journal"),
        )
        conn.commit()
    except Exception:
        pass  # Non-fatal


def _write_signals(signals: list[dict], db_path: Path) -> None:
    """Write signal rows to engram.db."""
    conn = get_connection(db_path)
    conn.executemany(
        """
        INSERT INTO identity_signals
            (signal_type, signal_scope, field_name, confidence, raw_excerpt, session_id, agent_name, source)
        VALUES
            (:signal_type, :signal_scope, :field_name, :confidence, :raw_excerpt, :session_id, :agent_name, :source)
        """,
        signals,
    )
    conn.commit()


def main() -> None:
    """Read hook payload from stdin, extract signals if the file is a journal file."""
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    # Hook payload: look for the file path in tool_input or tool_result
    file_path = None

    # PostToolUse Write hook — tool_input has the file_path key
    tool_input = payload.get("tool_input", {})
    if isinstance(tool_input, dict):
        file_path = tool_input.get("file_path") or tool_input.get("path")

    if not file_path:
        sys.exit(0)

    # Only process journal files
    journal_dir = str(Path.home() / ".claude" / "claudes_journal")
    if journal_dir not in file_path:
        sys.exit(0)

    path = Path(file_path)
    if not path.exists():
        sys.exit(0)

    db_path = os.environ.get("ENGRAM_DB_PATH")
    if db_path:
        db_path = Path(db_path)
    agent_name = os.environ.get("CAST_AGENT_NAME") or None
    extract_signals(path, db_path=db_path, agent_name=agent_name)
    sys.exit(0)


if __name__ == "__main__":
    main()
