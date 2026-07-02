#!/usr/bin/env python3
"""
cast-commit-reconcile.py — Pre-push hatch audit reconciler.

Enforcement rule (Ed-locked design):
  A COMMIT_HATCH_USED audit event with in_claude_session==true and NO
  commit_provenance row recorded within [event_ts - 60s, event_ts + 15min]
  = unauthorized in-session self-commit.

Exit codes:
  0 — clean / acked / skipped (infra absence)
  1 — unacked violations found OR DB error (fail-closed)

Output: valid JSON on stdout regardless of exit code.
Errors: stderr only.

Cooperative-tier limitations (D5 threat model — accepted traceless bypasses):
  Physical or repo-write access can bypass this gate via: (1) edit/delete
  audit.jsonl directly, (2) write the checkpoint file directly,
  (3) CAST_SKIP_RECONCILE=1 git push, (4) git push --no-verify.
  These require direct filesystem/repo access and are outside the model's scope.
"""

import datetime
import json
import os
import re
import sqlite3
import sys

# cast_db abstraction — mirrors pattern used in cast-commit-provenance.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cast_db import db_query  # noqa: E402


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

AUDIT_PATH = os.environ.get(
    "CAST_AUDIT_PATH",
    os.path.expanduser("~/.claude/logs/audit.jsonl"),
)
DB_PATH = os.environ.get(
    "CAST_DB_PATH",
    os.path.expanduser("~/.claude/cast.db"),
)
CHECKPOINT_PATH = os.environ.get(
    "CAST_RECONCILE_CHECKPOINT",
    os.path.expanduser("~/.claude/run/commit-reconcile-checkpoint"),
)
ACK_MODE = os.environ.get("CAST_RECONCILE_ACK", "0") == "1"

# CLAUDECODE is set in every Claude Code harness shell; absent in Ed's terminal.
# Used to mark whether reconcile events originate from an agent context.
IN_CLAUDE_SESSION: bool = os.environ.get("CLAUDECODE") == "1"

# Window for commit_provenance match: [event_ts - 60s, event_ts + 15min]
WINDOW_BEFORE_SEC = 60
WINDOW_AFTER_SEC = 15 * 60

# Fallback lookback when checkpoint is absent or malformed
DEFAULT_LOOKBACK_DAYS = 30

# Regex for L1 sanitization: strip non-safe chars from audit-derived terminal output
_SAFE_CHARS_RE = re.compile(r"[^a-zA-Z0-9._:TZ+\-]")


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class _DBError(Exception):
    """Raised when a DB query fails in a way that warrants blocking the push (fail-closed)."""


# ---------------------------------------------------------------------------
# Sanitization (L1)
# ---------------------------------------------------------------------------

def _sanitize(s: str) -> str:
    """Strip terminal-escape-unsafe characters from audit-derived strings."""
    return _SAFE_CHARS_RE.sub("?", str(s))


# ---------------------------------------------------------------------------
# Audit event helpers
# ---------------------------------------------------------------------------

def _append_audit_event(record: dict) -> None:
    """Append a JSON record line to audit.jsonl (best-effort, never crash)."""
    try:
        with open(AUDIT_PATH, "a") as f:
            f.write(json.dumps(record) + "\n")
    except Exception as exc:  # noqa: BLE001
        print(
            f"[cast-commit-reconcile] WARNING: could not append audit event: {exc}",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------
# Checkpoint helpers
# ---------------------------------------------------------------------------

def read_checkpoint() -> datetime.datetime | None:
    """Return the checkpoint datetime (UTC-naive), or None if absent/malformed."""
    try:
        with open(CHECKPOINT_PATH) as f:
            raw = f.read().strip()
        ts = datetime.datetime.fromisoformat(raw)
        # Normalise to UTC-naive
        if ts.tzinfo is not None:
            ts = datetime.datetime(*ts.utctimetuple()[:6])
        return ts
    except (FileNotFoundError, ValueError):
        return None


def write_checkpoint(ts: datetime.datetime, old_ts: datetime.datetime | None = None) -> None:
    """
    Advance the checkpoint to ts (best-effort, never crash).
    Appends a CHECKPOINT_ADVANCED audit event with old/new values.
    """
    try:
        os.makedirs(os.path.dirname(CHECKPOINT_PATH), exist_ok=True)
        with open(CHECKPOINT_PATH, "w") as f:
            f.write(ts.isoformat())
    except Exception as exc:  # noqa: BLE001
        print(
            f"[cast-commit-reconcile] WARNING: could not write checkpoint: {exc}",
            file=sys.stderr,
        )
        return  # Don't emit CHECKPOINT_ADVANCED if the write itself failed

    # Emit CHECKPOINT_ADVANCED so every advance is traceable in audit.jsonl
    _append_audit_event({
        "event": "CHECKPOINT_ADVANCED",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "old_checkpoint": old_ts.isoformat() if old_ts is not None else None,
        "new_checkpoint": ts.isoformat(),
        "in_claude_session": IN_CLAUDE_SESSION,
    })


# ---------------------------------------------------------------------------
# Audit log reader
# ---------------------------------------------------------------------------

def _parse_ts(raw_ts: str) -> datetime.datetime | None:
    """Parse an ISO timestamp string to a UTC-naive datetime, or None."""
    try:
        ts = datetime.datetime.fromisoformat(raw_ts)
        if ts.tzinfo is not None:
            # Convert timezone-aware → UTC-naive
            ts = datetime.datetime(*ts.utctimetuple()[:6])
        return ts
    except (ValueError, TypeError):
        return None


def load_hatch_events(since: datetime.datetime) -> list[dict]:
    """
    Parse audit.jsonl and return COMMIT_HATCH_USED events with
    in_claude_session==True that are strictly newer than `since`.

    Grandfathering rules:
      - Events lacking in_claude_session field entirely → ignored (pre-feature lines).
      - Events with in_claude_session==false → not suspicious, skipped.
    Garbage / non-JSON lines are silently skipped.
    """
    events: list[dict] = []
    try:
        with open(AUDIT_PATH) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue  # garbage line — skip silently

                # Only care about COMMIT_HATCH_USED events
                if obj.get("event") != "COMMIT_HATCH_USED":
                    continue

                # GRANDFATHER: missing in_claude_session field → ignore
                if "in_claude_session" not in obj:
                    continue

                # in_claude_session==false → not suspicious, skip
                if not obj["in_claude_session"]:
                    continue

                # Parse timestamp
                raw_ts = obj.get("timestamp") or obj.get("ts") or ""
                evt_ts = _parse_ts(raw_ts)
                if evt_ts is None:
                    continue  # unparseable timestamp → skip

                # Only events strictly newer than checkpoint
                if evt_ts <= since:
                    continue

                events.append({
                    "timestamp": raw_ts,
                    "session_id": obj.get("session_id", "unknown"),
                    "_ts": evt_ts,
                })
    except FileNotFoundError:
        pass  # handled by caller — audit file absent → skip

    return events


# ---------------------------------------------------------------------------
# Provenance DB check
# ---------------------------------------------------------------------------

def provenance_table_exists() -> bool:
    """
    Return True if commit_provenance table is present in the DB.

    Uses raw sqlite3 (not cast_db) to distinguish absence from error:
      - Table absent (0 rows from sqlite_master) → False → caller skips
      - OperationalError "no such table" → False → caller skips
      - Any other OperationalError or exception → raises _DBError → caller blocks push
    """
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        try:
            rows = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='commit_provenance'"
            ).fetchall()
        finally:
            conn.close()
        return bool(rows)
    except sqlite3.OperationalError as exc:
        msg = str(exc).lower()
        if "no such table" in msg:
            return False  # Table genuinely absent — skip
        raise _DBError(f"DB query failed: {exc}") from exc
    except Exception as exc:
        raise _DBError(f"DB query failed: {exc}") from exc


def has_provenance(event_ts: datetime.datetime) -> bool:
    """
    Return True if commit_provenance has a row with recorded_at inside
    [event_ts - WINDOW_BEFORE_SEC, event_ts + WINDOW_AFTER_SEC].
    """
    window_start = (
        event_ts - datetime.timedelta(seconds=WINDOW_BEFORE_SEC)
    ).strftime("%Y-%m-%dT%H:%M:%S")
    window_end = (
        event_ts + datetime.timedelta(seconds=WINDOW_AFTER_SEC)
    ).strftime("%Y-%m-%dT%H:%M:%S")
    rows = db_query(
        "SELECT 1 FROM commit_provenance WHERE recorded_at >= ? AND recorded_at <= ? LIMIT 1",
        (window_start, window_end),
    )
    return bool(rows)


# ---------------------------------------------------------------------------
# ACK event writer
# ---------------------------------------------------------------------------

def append_ack_event(acked_events: list[dict]) -> None:
    """
    Append a RECONCILE_ACK_USED event to audit.jsonl (best-effort, never crash).
    Includes top-level in_claude_session so agent-issued acks are distinguishable
    from human acks (CLAUDECODE env present vs absent).
    """
    _append_audit_event({
        "event": "RECONCILE_ACK_USED",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "in_claude_session": IN_CLAUDE_SESSION,
        "acked_events": [
            {
                "timestamp": e["timestamp"],
                "session_id": e["session_id"],
                "in_claude_session": True,
            }
            for e in acked_events
        ],
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

    # 1. Determine evaluation window from checkpoint
    checkpoint = read_checkpoint()
    if checkpoint is None:
        since = now - datetime.timedelta(days=DEFAULT_LOOKBACK_DAYS)
    else:
        since = checkpoint

    # 2. Skip cleanly if audit file is missing
    if not os.path.exists(AUDIT_PATH):
        result = {
            "status": "skip",
            "reason": "audit file not found",
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        return 0

    # 3. Load candidate events from audit log
    try:
        events = load_hatch_events(since)
    except Exception as exc:  # noqa: BLE001
        result = {
            "status": "skip",
            "reason": f"could not read audit log: {exc}",
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        return 0

    # 4. Skip cleanly if DB is missing (infra not yet deployed)
    if not os.path.exists(DB_PATH):
        result = {
            "status": "skip",
            "reason": "cast.db not found",
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        return 0

    # 5. Check commit_provenance table presence — fail-closed on DB error
    try:
        table_present = provenance_table_exists()
    except _DBError as exc:
        result = {
            "status": "error",
            "reason": str(exc),
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        print(
            f"\n[CAST pre-push] DB query failed — cannot verify provenance; push blocked.\n"
            f"(Fail-closed on infra ERROR; skips only on genuine table absence.)\n"
            f"Reason: {exc}\n",
            file=sys.stderr,
        )
        return 1

    if not table_present:
        result = {
            "status": "skip",
            "reason": "commit_provenance table not found",
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        return 0

    # 6. For each event, check provenance within the window
    violations: list[dict] = []
    violation_events: list[dict] = []
    checked = 0
    for evt in events:
        checked += 1
        if not has_provenance(evt["_ts"]):
            violations.append({
                "timestamp": evt["timestamp"],
                "session_id": evt["session_id"],
            })
            violation_events.append(evt)

    # 7. Build response
    if not violations:
        result = {"status": "clean", "checked": checked, "violations": []}
        print(json.dumps(result))
        write_checkpoint(now, old_ts=checkpoint)
        return 0

    if ACK_MODE:
        result = {"status": "acked", "checked": checked, "violations": violations}
        print(json.dumps(result))
        append_ack_event(violation_events)
        write_checkpoint(now, old_ts=checkpoint)
        return 0

    # Unacked violations — exit 1 with remediation block on stderr (L1: sanitize audit values)
    result = {"status": "violations", "checked": checked, "violations": violations}
    print(json.dumps(result))

    offenders = "".join(
        f"  - session={_sanitize(v['session_id'])}  ts={_sanitize(v['timestamp'])}\n"
        for v in violations
    )
    print(
        f"\n[CAST pre-push] Unauthorized in-session self-commit(s) detected.\n"
        f"Offending sessions / timestamps:\n{offenders}\n"
        f"Remediation:\n"
        f"  1. Re-commit via the commit agent (preferred): the commit agent records provenance.\n"
        f"  2. Human-approved exception: CAST_RECONCILE_ACK=1 git push\n"
        f"     (appends a RECONCILE_ACK_USED event to the audit log)\n",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
