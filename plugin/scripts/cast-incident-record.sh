#!/bin/bash
# SubagentStop hook fragment: capture debugger-agent incidents into cast.db
# Triggered on SubagentStop event when agent_type == "debugger" and Status: DONE is present

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# Helper for error logging
_log_error() {
  local msg="$1"
  local log_file="$HOME/.claude/logs/hook-errors.log"
  mkdir -p "$(dirname "$log_file")"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [cast-incident-record] $msg" >>"$log_file"
}

# Read stdin once
INPUT="$(cat 2>/dev/null || true)"
if [[ -z "$INPUT" ]]; then
  exit 0
fi

# Export for python3 inline (Bug 1 fix: same pattern as cast-subagent-stop-hook.sh)
export CAST_INPUT="$INPUT"

# Resolve hook directory for cast-redact.py (heredoc-safe: __file__ is not usable in <<'PYEOF')
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "${HOME}/.claude/scripts")"
export HOOK_DIR

# Resolve DB path and export for python3
DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"

# Parse payload, validate guards, and insert — all in one python3 block
# with bound parameters (Bug 2+3 fix: correct fields + parameterized query)
CAST_DB_PATH="$DB_PATH" python3 <<'PYEOF' || true
import sys, json, os, re, sqlite3, uuid
from datetime import datetime, timezone


def log_error(msg):
    log_file = os.path.expanduser("~/.claude/logs/hook-errors.log")
    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    with open(log_file, "a") as f:
        f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] [cast-incident-record] {msg}\n")


try:
    raw = os.environ.get("CAST_INPUT", "")
    data = json.loads(raw)
except Exception as e:
    log_error(f"JSON parse failed: {e}")
    sys.exit(0)

# Guard: only process debugger agent
agent_type = data.get("agent_type", "")
if agent_type != "debugger":
    sys.exit(0)

# Extract response text: content[] blocks → last_assistant_message → output
response_text = ""
ar = data.get("agent_response", {})
content = ar.get("content", [])
if isinstance(content, list):
    parts = [
        b.get("text", "")
        for b in content
        if isinstance(b, dict) and b.get("type") == "text"
    ]
    response_text = "\n".join(parts)
if not response_text:
    response_text = (
        data.get("last_assistant_message", "") or data.get("output", "") or ""
    )

# Guard: only record when Status: DONE or DONE_WITH_CONCERNS present
if not re.search(r"Status:\s*(DONE|DONE_WITH_CONCERNS)", response_text):
    sys.exit(0)

# problem_summary: "Summary: <text>" first match; else first 200 non-empty chars
m = re.search(r"Summary:\s*(.+)", response_text)
if m:
    problem_summary = m.group(1).strip()[:500]
else:
    problem_summary = " ".join(response_text.split())[:200]
if not problem_summary:
    problem_summary = "(no summary)"

# fix_summary: ## Handoff block content if present; else last 1000 chars
handoff_m = re.search(
    r"## Handoff\s*\n([\s\S]+?)(?=\n## |\Z)", response_text
)
if handoff_m:
    fix_summary = handoff_m.group(1).strip()[:1000]
else:
    fix_summary = response_text[-1000:].strip()

# related_files: files_changed: value from Handoff block; else "[]"
related_files = "[]"
if handoff_m:
    fc_m = re.search(r"files_changed:\s*(.+)", handoff_m.group(1))
    if fc_m:
        related_files = fc_m.group(1).strip()

# related_commit: latest git commit hash in cwd
related_commit = ""
try:
    import subprocess
    r = subprocess.run(
        ["git", "log", "-1", "--format=%H"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if r.returncode == 0:
        related_commit = r.stdout.strip()
except Exception:
    pass

# Redact PII/secrets from summaries before DB write (mirrors cast-subagent-stop-hook.sh)
import subprocess as _sp


def _redact(text):
    if not text:
        return text
    try:
        hook_dir = os.environ.get("HOOK_DIR") or os.path.expanduser("~/.claude/scripts")
        r = _sp.run(
            ["python3", os.path.join(hook_dir, "cast-redact.py"),
             "--engine", "regex", "--field", "redacted_text"],
            input=text, capture_output=True, text=True, timeout=3,
        )
        out = r.stdout.strip()
        if r.returncode == 0 and out:
            return out
        try:
            log_error("WARN: redaction failed — storing [REDACTION_FAILED] marker")
        except Exception:
            pass
        return "[REDACTION_FAILED]" if text else text
    except Exception:
        try:
            log_error("WARN: redaction failed (exception) — storing [REDACTION_FAILED] marker")
        except Exception:
            pass
        return "[REDACTION_FAILED]" if text else text  # fail-closed: never passthrough raw content


problem_summary = _redact(problem_summary)
fix_summary = _redact(fix_summary)

# Insert into incidents with bound parameters (Bug 3 fix: no string interpolation)
db_path = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))
incident_id = str(uuid.uuid4())
occurred_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

try:
    conn = sqlite3.connect(db_path, timeout=5)
    conn.execute(
        """INSERT INTO incidents
           (id, occurred_at, problem_summary, fix_summary, related_files,
            related_commit, resolution_status, surfaced_by)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            incident_id,
            occurred_at,
            problem_summary,
            fix_summary,
            related_files,
            related_commit,
            "open",
            "debugger",
        ),
    )
    conn.commit()
    conn.close()
except Exception as e:
    log_error(f"DB insert failed: {e}")
    sys.exit(0)
PYEOF
exit 0
