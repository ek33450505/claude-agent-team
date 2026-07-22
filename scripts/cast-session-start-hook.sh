#!/bin/bash
# cast-session-start-hook.sh — SessionStart hook
# Fires once when a new Claude Code session starts.
# Responsibilities:
#   1. Guard against subprocess invocations
#   2. Write CAST env vars to $CLAUDE_ENV_FILE if set
#   3. Log session start to ~/.claude/cast/session-starts.jsonl
#
# Stdin JSON fields (SessionStart):
#   session_id — the new session's ID
#   cwd        — working directory of the session
#
# Exit codes:
#   0 — always (hook must not block the session)

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Export pane_id for the single consolidated python3 block below
export CAST_PANE_ID_FOR_HOOK="${CAST_DESKTOP_PANE_ID:-}"

# Consolidated block: session upsert (JSONL + DB) and pane-bindings both parse
# the same CAST_INPUT on the unconditional hot path, so they share ONE python3
# cold start instead of two. Each responsibility keeps its own try/except so a
# failure in one does not skip the other (matches prior process independence).
CAST_INPUT="$INPUT" python3 - <<'PYEOF' || _log_error "session-start JSONL+DB+pane-bindings block failed (exit $?)"
import json, os, sqlite3 as _sqlite3
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# ── Part 1: env-file write + session-starts.jsonl (session_id defaults 'unknown') ──
session_id_log = data.get("session_id", "unknown")
cwd_log        = data.get("cwd", "")

env_file = os.environ.get("CLAUDE_ENV_FILE", "")
if env_file:
    try:
        parent = os.path.dirname(env_file)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(env_file, "a") as f:
            f.write(f"CAST_SESSION_ID={session_id_log}\n")
            f.write(f"CAST_SESSION_CWD={cwd_log}\n")
            f.write(f"CAST_SESSION_START_TS={iso_ts}\n")
    except Exception as e:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        log_dir = os.path.expanduser("~/.claude/logs")
        os.makedirs(log_dir, exist_ok=True)
        with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
            lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: env_file write failed: {e}\n")

entry = {
    "timestamp":  iso_ts,
    "session_id": session_id_log,
    "cwd":        cwd_log,
}

log_path = os.path.expanduser("~/.claude/cast/session-starts.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception as e:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_dir = os.path.expanduser("~/.claude/logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
        lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: session-starts.jsonl write failed: {e}\n")

# ── Part 2: sessions DB insert (session_id empty string, not 'unknown') ──
session_id = data.get("session_id", "")
cwd        = data.get("cwd", "")
project    = os.path.basename(cwd.rstrip('/')) if cwd else "unknown"

db_path = os.path.expanduser("~/.claude/cast.db")

# Guard: skip INSERT when session_id is missing/empty — a NULL or empty PK
# produces unresolvable rows (4 found in live DB audit, Phase 5 Wave 2)
if session_id and os.path.exists(db_path):
    try:
        con = _sqlite3.connect(db_path, timeout=3)
        # Add status column if missing (idempotent — silently ignored if already present)
        try:
            con.execute("ALTER TABLE sessions ADD COLUMN status TEXT DEFAULT 'ended'")
            con.commit()
        except Exception:
            pass
        con.execute(
            "INSERT OR IGNORE INTO sessions (id, project, project_root, started_at, status) VALUES (?, ?, ?, ?, 'active')",
            (session_id, project, cwd, now.strftime("%Y-%m-%dT%H:%M:%SZ")),
        )
        # If row already existed (OR IGNORE), update status to active
        con.execute(
            "UPDATE sessions SET status = 'active' WHERE id = ? AND status != 'active'",
            (session_id,),
        )
        con.commit()
        con.close()
    except Exception as e:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        log_dir = os.path.expanduser("~/.claude/logs")
        os.makedirs(log_dir, exist_ok=True)
        with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
            lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: DB INSERT failed: {type(e).__name__}: {e}\n")

# ── Part 3: pane_bindings upsert (session_id defaults 'unknown', separate from Part 2) ──
pane_id = os.environ.get("CAST_PANE_ID_FOR_HOOK", "").strip()
if pane_id and os.path.exists(db_path):
    pane_session_id = data.get("session_id", "unknown")
    try:
        con = _sqlite3.connect(db_path, timeout=3)
        # Create pane_bindings table if missing
        con.execute("""
            CREATE TABLE IF NOT EXISTS pane_bindings (
                pane_id TEXT PRIMARY KEY,
                session_id TEXT,
                started_at INTEGER,
                ended_at INTEGER,
                project_path TEXT
            )
        """)
        # Insert or update pane binding
        con.execute(
            """
            INSERT INTO pane_bindings (pane_id, session_id, started_at, project_path)
            VALUES (?, ?, strftime('%s','now'), ?)
            ON CONFLICT(pane_id) DO UPDATE SET
                session_id=excluded.session_id,
                started_at=excluded.started_at,
                project_path=excluded.project_path,
                ended_at=NULL
            """,
            (pane_id, pane_session_id, cwd),
        )
        con.commit()
        con.close()
    except Exception as e:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        log_dir = os.path.expanduser("~/.claude/logs")
        os.makedirs(log_dir, exist_ok=True)
        with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
            lf.write(f"[{ts}] ERROR cast-session-start-hook.sh: pane-bindings INSERT failed: {type(e).__name__}: {e}\n")
PYEOF

# Notify the Cast Desktop backend of the pane binding
if [ -n "${CAST_DESKTOP_PANE_ID:-}" ]; then
  curl -s -X POST "http://localhost:3001/api/pane-bindings/notify" \
    -H "Content-Type: application/json" \
    -d "{\"paneId\": \"${CAST_DESKTOP_PANE_ID}\"}" \
    --max-time 2 >/dev/null 2>&1 || true
fi

# OTEL export wiring (Phase 12 — native OpenTelemetry, opt-in via OTLP endpoint)
# Native OTel is OFF by default. Setting OTEL_EXPORTER_OTLP_ENDPOINT turns it on and
# routes telemetry to that collector. With no endpoint, telemetry stays disabled so
# interactive sessions are never spammed with console metric dumps.
if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  echo "CLAUDE_CODE_ENABLE_TELEMETRY=1" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
  echo "OTEL_METRICS_EXPORTER=otlp" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
  echo "OTEL_LOGS_EXPORTER=otlp" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null || true
fi

# ── Phase 16: Stack + preference banner (prompt-me-less) ──────────────────────
# Emits {"systemMessage":"..."} to stdout when either CAST_STACK_PROFILE is set
# or top-3 feedback_*.md memories exist. Silent (no output) when neither is present.
# Hard cap: total Phase 16 additions ≤ 500 chars. Preference block ≤ 280 chars.
# Abstention rule: feedback files with body < 30 chars are skipped entirely.
CAST_INPUT="$INPUT" CAST_STACK_PROFILE="${CAST_STACK_PROFILE:-}" python3 - <<'PYEOF4' || _log_error "session-start banner block failed (exit $?)"
import json, os, glob, sys

# ── Section A: Stack banner ────────────────────────────────────────────────────
stack_profile_raw = os.environ.get("CAST_STACK_PROFILE", "").strip()
stack_line = ""
if stack_profile_raw:
    try:
        sp = json.loads(stack_profile_raw)
        fw       = sp.get("fw", "") or sp.get("framework", "")
        test_cmd = sp.get("test_cmd", "")
        build_cmd = sp.get("build_cmd", "")
        parts = []
        if fw:
            parts.append("Stack: " + fw)
        if test_cmd:
            parts.append("test: " + test_cmd)
        if build_cmd:
            parts.append("build: " + build_cmd)
        if parts:
            stack_line = " | ".join(parts)
    except Exception:
        pass

# ── Section B: Preference banner ──────────────────────────────────────────────
home = os.path.expanduser("~")
feedback_glob = os.path.join(home, ".claude", "projects", "*", "memory", "feedback_*.md")
feedback_files = glob.glob(feedback_glob)

pref_entries = []
for fpath in feedback_files:
    try:
        mtime = os.path.getmtime(fpath)
        with open(fpath, "r", encoding="utf-8", errors="replace") as f:
            body = f.read().strip()
        # abstention rule: skip if body < 30 chars
        if len(body) < 30:
            continue
        slug    = os.path.splitext(os.path.basename(fpath))[0]
        snippet = body[:80].replace("\n", " ")
        pref_entries.append((mtime, slug, snippet))
    except Exception:
        continue

# Sort by mtime descending, take top 3
pref_entries.sort(key=lambda x: x[0], reverse=True)
top3 = pref_entries[:3]

pref_line = ""
if top3:
    parts = []
    for _, slug, snippet in top3:
        parts.append("[from: " + slug + "] " + snippet)
    pref_line = "Standing prefs: " + " | ".join(parts)
    if len(pref_line) > 280:
        pref_line = pref_line[:277] + "..."

# ── Combine and enforce 500-char cap ──────────────────────────────────────────
parts_combined = []
if stack_line:
    parts_combined.append(stack_line)
if pref_line:
    parts_combined.append(pref_line)

if not parts_combined:
    sys.exit(0)

banner = "\n".join(parts_combined)

if len(banner) > 500:
    # Truncate preference line first (it's less critical than stack)
    if stack_line and pref_line:
        remaining = 500 - len(stack_line) - 1   # 1 for the joining newline
        if remaining > 3:
            pref_line = pref_line[:remaining - 3] + "..."
        else:
            pref_line = ""
        parts_combined = [p for p in [stack_line, pref_line] if p]
        banner = "\n".join(parts_combined)
    else:
        banner = banner[:500]

print(json.dumps({"systemMessage": banner}))
PYEOF4

exit 0
