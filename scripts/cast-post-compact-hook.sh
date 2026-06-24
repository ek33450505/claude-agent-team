#!/bin/bash
# cast-post-compact-hook.sh — PostCompact hook (Claude Code v2.1.76+)
# Logs context compaction events to cast/events/ and compact-log.jsonl.
# Always exits 0 — PostCompact is observability-only (stdout ignored by Claude Code).

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >>"${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

INPUT="$(cat 2>/dev/null || true)"

CAST_INPUT="$INPUT" python3 - <<'PYEOF' || true
import json, os, uuid
from datetime import datetime, timezone

raw = os.environ.get("CAST_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    import sys; sys.exit(0)

trigger         = data.get("trigger", "unknown")
session_id      = data.get("session_id", "unknown")
transcript_path = data.get("transcript_path", "")

# Map trigger to canonical compaction tier
# Claude Code PostCompact trigger values: 'auto', 'manual', 'micro' (confirmed from source)
def detect_tier(trigger_val):
    t = (trigger_val or "").lower()
    if t in ("micro", "microcompact"):
        return "MicroCompact"
    elif t in ("manual", "full", "user"):
        return "FullCompact"
    elif t in ("auto", "autocompact", ""):
        return "AutoCompact"
    else:
        return f"Unknown({trigger_val})"

compaction_tier = detect_tier(trigger)

now    = datetime.now(timezone.utc)
iso_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

event = {
    "id":               str(uuid.uuid4()),
    "timestamp":        iso_ts,
    "type":             "post_compact",
    "trigger":          trigger,
    "compaction_tier":  compaction_tier,
    "session_id":       session_id,
    "transcript_path":  transcript_path,
}

# Write to cast/events/
events_dir = os.path.expanduser("~/.claude/cast/events")
os.makedirs(events_dir, exist_ok=True)
short_id   = str(uuid.uuid4())[:8]
event_path = os.path.join(events_dir, f"{iso_ts}-{short_id}-compact.json")
try:
    with open(event_path, "w") as f:
        json.dump(event, f, indent=2)
        f.write("\n")
except Exception as e:
    import sys
    print(f"[cast-post-compact-hook] Failed to write event file: {e}", file=sys.stderr)

# Append to compact-log.jsonl for easy chronological review
log_path = os.path.expanduser("~/.claude/cast/compact-log.jsonl")
try:
    with open(log_path, "a") as f:
        f.write(json.dumps(event) + "\n")
except Exception as e:
    import sys
    print(f"[cast-post-compact-hook] Failed to append to compact-log: {e}", file=sys.stderr)

# compaction_events DB write retired (v9 B3 recorder-subtraction): the native OTEL
# 'compaction' event now lands in otel_events (telemetry on by default).
# Table still populated by cast-precompact-log.py (PreCompact).
# Audit: plans/b3-hook-feed-coverage-audit.md
PYEOF

exit 0
