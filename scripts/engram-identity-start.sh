#!/usr/bin/env bash
# engram-identity-start.sh
# Fires on: SessionStart
# Purpose: Always regenerate identity payload, then inject journal context + open threads from DB.
# Security: all Python calls use env vars — no shell string interpolation in Python code.
# Always exits 0 — never blocks session start.

JOURNAL_DIR="${HOME}/.claude/claudes_journal"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
ENGRAM_DB="${HOME}/.claude/engram.db"

# ── Locate Python ──────────────────────────────────────────────────────────
PYTHON="${REPO_DIR}/.venv/bin/python3"
if [[ ! -f "$PYTHON" ]]; then
    PYTHON="python3"
fi

# ── Step 1: Always regenerate identity payload ─────────────────────────────
# Regenerate on every session start so the payload reflects the latest
# profile updates from the prior session's stop hook.
if [[ -f "$ENGRAM_DB" ]]; then
    # Resolve active persona (from .engram/persona file in cwd, if present)
    PERSONA_SLUG=""
    if [[ -f "${PWD}/.engram/persona" ]]; then
        PERSONA_SLUG=$(head -1 "${PWD}/.engram/persona" 2>/dev/null | tr -d '[:space:]')
    fi

    export ENGRAM_DB_PATH="${ENGRAM_DB}"
    export ENGRAM_REPO_DIR="${REPO_DIR}"
    export ENGRAM_PERSONA_SLUG="${PERSONA_SLUG}"
    export ENGRAM_AGENT_NAME="${CAST_AGENT_NAME:-}"

    "$PYTHON" -c "
import sys, os
sys.path.insert(0, os.environ['ENGRAM_REPO_DIR'])
from pathlib import Path
from src.payload.builder import build_payload

build_payload(
    db_path=Path(os.environ['ENGRAM_DB_PATH']),
    persona_slug=os.environ.get('ENGRAM_PERSONA_SLUG') or None,
    agent_name=os.environ.get('ENGRAM_AGENT_NAME') or None,
)
" 2>/dev/null || true
fi

# ── Step 2: Build journal context (last 3 entries) ─────────────────────────
journal_context=""

if [[ -d "$JOURNAL_DIR" ]]; then
    export ENGRAM_JOURNAL_DIR="${JOURNAL_DIR}"
    journal_context=$("$PYTHON" -c "
import os
journal_dir = os.environ.get('ENGRAM_JOURNAL_DIR', '')
try:
    files = sorted(f for f in os.listdir(journal_dir) if f.endswith('.md'))
    recent = files[-3:]
    out = ''
    for fname in recent:
        date_label = fname[:-3]
        path = os.path.join(journal_dir, fname)
        content = open(path).read()
        out += f'### Journal: {date_label}\n{content}\n\n'
    print(out, end='')
except Exception:
    pass
" 2>/dev/null)
fi

# ── Step 3: Build open threads context (from DB) ─────────────────────────
threads_context=""
if [[ -f "$ENGRAM_DB" ]]; then
    export ENGRAM_DB_PATH="${ENGRAM_DB}"
    export ENGRAM_REPO_DIR="${REPO_DIR}"
    threads_context=$("$PYTHON" -c "
import sys, os
sys.path.insert(0, os.environ['ENGRAM_REPO_DIR'])
from pathlib import Path
from src.db import get_connection

try:
    conn = get_connection(db_path=Path(os.environ['ENGRAM_DB_PATH']))
    rows = conn.execute(
        'SELECT thread, date FROM open_threads WHERE resolved = 0 ORDER BY id DESC LIMIT 3'
    ).fetchall()
    if rows:
        items = '\n'.join(f'- [{r[\"date\"] or \"\"}] {r[\"thread\"]}' for r in rows)
        print(f'Open threads from prior sessions:\n{items}')
except Exception:
    pass
" 2>/dev/null)
fi

# ── Step 4: Emit hook output if any context was gathered ──────────────────
if [[ -n "$journal_context" || -n "$threads_context" ]]; then
    payload=""
    [[ -n "$journal_context" ]] && payload+="## Prior Session Journal Entries"$'\n\n'"${journal_context}"
    [[ -n "$threads_context" ]] && payload+=$'\n'"## ${threads_context}"

    "$PYTHON" -c "
import json, sys
payload = sys.stdin.read()
print(json.dumps({'hookSpecificOutput': payload}))
" <<< "$(printf '%s' "$payload")"
fi

exit 0
