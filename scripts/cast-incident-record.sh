#!/bin/bash
# SubagentStop hook: capture incidents into cast.db for two classes —
#   (1) debugger agent + Status: DONE/DONE_WITH_CONCERNS; (2) ANY agent with Status: BLOCKED or a BLOCKER verdict line.
# Triggered on SubagentStop event (async, 5s timeout).

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

agent_type = data.get("agent_type", "") or "unknown"

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

# Stripped text for MATCHING ONLY (removes markdown emphasis like ** and __ padding)
# Original response_text is always used for summary extraction.
stripped_text = re.sub(r'[*_]{1,3}', '', response_text)

# Pre-extract handoff block (reused in both capture paths)
handoff_m = re.search(
    r"## Handoff\s*\n([\s\S]+?)(?=\n## |\Z)", response_text
)

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


db_path = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))


def _do_insert(problem_summary, fix_summary, surfaced_by):
    """Redact summaries and insert one incidents row with bound parameters."""
    p_sum = _redact(problem_summary)
    f_sum = _redact(fix_summary)
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
                p_sum,
                f_sum,
                related_files,
                related_commit,
                # surfaced_by (agent_type) is deliberately NOT redacted: it is a CAST runtime
                # enum from the hook payload, not response-derived text, and is a bound parameter.
                "open",
                surfaced_by,
            ),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        log_error(f"DB insert failed: {e}")


# ── PATH 1: debugger + Status: DONE/DONE_WITH_CONCERNS ───────────────────────
# Evaluated first; if this inserts, PATH 2 is skipped entirely.
inserted = False

if agent_type == "debugger" and re.search(
    r"Status:\s*(DONE|DONE_WITH_CONCERNS)", stripped_text
):
    m = re.search(r"Summary:\s*(.+)", response_text)
    if m:
        problem_summary = m.group(1).strip()[:500]
    else:
        problem_summary = " ".join(response_text.split())[:200]
    if not problem_summary:
        problem_summary = "(no summary)"

    if handoff_m:
        fix_summary = handoff_m.group(1).strip()[:1000]
    else:
        fix_summary = response_text[-1000:].strip()

    _do_insert(problem_summary, fix_summary, "debugger")
    inserted = True

# ── PATH 2: BLOCKED / BLOCKER verdict — any agent (only if PATH 1 did not insert) ──
# Matches: Status: BLOCKED (stripped) OR a line starting with BLOCKER (stripped).
# A debugger that ends BLOCKED reaches this path (PATH 1 requires DONE/DONE_WITH_CONCERNS).
if not inserted:
    is_blocked = bool(re.search(r"Status:\s*BLOCKED", stripped_text))
    # Broad ^BLOCKER line anchor is intentional — it is the F3 review-verdict convention
    # ("output a line beginning with the literal token BLOCKER"); requiring a colon would
    # miss real verdicts, and over-recording is bounded (max one row per SubagentStop).
    blocker_match = re.search(r"^\s*BLOCKER\b(.*)", stripped_text, re.MULTILINE)

    if is_blocked or blocker_match:
        # problem_summary: prefer first BLOCKER line content, else Summary: line, else first 200 chars
        if blocker_match:
            blocker_content = blocker_match.group(1).strip()
            base_summary = blocker_content if blocker_content else "(blocker)"
        else:
            sm = re.search(r"Summary:\s*(.+)", response_text)
            if sm:
                base_summary = sm.group(1).strip()[:500]
            else:
                base_summary = " ".join(response_text.split())[:200] or "(no summary)"

        problem_summary = f"[{agent_type} BLOCKED] {base_summary}"[:500]

        # fix_summary: Handoff block if present, else empty string
        if handoff_m:
            fix_summary = handoff_m.group(1).strip()[:1000]
        else:
            fix_summary = ""

        _do_insert(problem_summary, fix_summary, agent_type)
        inserted = True  # noqa: F841 — kept for clarity; no further paths
PYEOF
exit 0
