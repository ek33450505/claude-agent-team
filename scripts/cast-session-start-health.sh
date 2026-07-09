#!/bin/bash
# cast-session-start-health.sh — SessionStart health surface
# Surfaces two silent failures at every session start (read-only, zero agent cost):
#   (a) auto-memories with stale verified_at (>30 days) AND naming a concrete path/fn/flag
#   (b) com.cast.* launchd jobs with non-zero last-exit-status
#
# Emits ONE JSON object (systemMessage + hookSpecificOutput) only when something needs attention.
# Exits 0 always — never blocks a session.
#
# Escape hatch: CAST_HEALTH_LAUNCHCTL_CMD overrides the launchctl binary (for testing).

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Capture launchctl output via overridable command (enables deterministic testing)
LAUNCHCTL="${CAST_HEALTH_LAUNCHCTL_CMD:-launchctl}"
LAUNCHCTL_OUTPUT="$("$LAUNCHCTL" list 2>/dev/null || true)"

_HEALTH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAST_HEALTH_SCRIPT_DIR="$_HEALTH_SCRIPT_DIR"
export CAST_INPUT="$INPUT"
export CAST_LAUNCHCTL_OUTPUT="$LAUNCHCTL_OUTPUT"
export CAST_HOME="$HOME"

python3 - <<'PYEOF' || _log_error "session-start-health python block failed (exit $?)"
import json, os, subprocess, sys

home = os.environ.get("CAST_HOME", os.path.expanduser("~"))
launchctl_out = os.environ.get("CAST_LAUNCHCTL_OUTPUT", "")

# ── Stale memory detection ────────────────────────────────────────────────────
# Canonical logic lives in cast-stale-memories.py (shared with bin/cast doctor).
# Output format: line 1 = count, lines 2+ = filepath|verified_at|age_days
_scanner = os.path.join(home, ".claude", "scripts", "cast-stale-memories.py")
if not os.path.isfile(_scanner):
    # Fall back to sibling in same directory (repo/CI context)
    _sib = os.path.join(os.environ.get("CAST_HEALTH_SCRIPT_DIR", ""), "cast-stale-memories.py")
    if _sib and os.path.isfile(_sib):
        _scanner = _sib
if not os.path.isfile(_scanner):
    # Final fallback: explicit repo dir env var
    _repo = os.environ.get("CAST_REPO_DIR", "")
    if _repo:
        _scanner = os.path.join(_repo, "scripts", "cast-stale-memories.py")

stale_memories = []  # list of (display_name, age_days)
if os.path.isfile(_scanner):
    try:
        result = subprocess.run(
            [sys.executable, _scanner],
            capture_output=True, text=True, timeout=10,
        )
        scanner_lines = result.stdout.splitlines()
        stale_count_raw = int(scanner_lines[0].strip()) if scanner_lines else 0
        for row in scanner_lines[1:]:
            parts = row.split("|", 2)
            if len(parts) < 3:
                continue
            filepath, _vdate, age_str = parts
            # Use the frontmatter name field if readable; fall back to filename stem
            mem_name = os.path.splitext(os.path.basename(filepath))[0]
            try:
                with open(filepath, "r", errors="replace") as fh:
                    in_fm = False
                    for i2, line in enumerate(fh):
                        stripped = line.strip()
                        if i2 == 0 and stripped == "---":
                            in_fm = True
                            continue
                        if not in_fm:
                            break
                        if stripped == "---":
                            break  # end of frontmatter
                        if stripped.startswith("name:"):
                            mem_name = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                            break
            except OSError:
                pass
            try:
                stale_memories.append((mem_name, int(age_str)))
            except ValueError:
                pass
    except Exception:
        pass  # scanner unavailable — silently skip stale memory check

# ── Failing launchd jobs ──────────────────────────────────────────────────────
failing_jobs = []
for line in launchctl_out.splitlines():
    parts = line.split(None, 2)
    if len(parts) < 3:
        continue
    pid_col, status_col, label_col = parts[0], parts[1], parts[2].strip()
    if "com.cast." not in label_col:
        continue
    try:
        status_int = int(status_col)
    except ValueError:
        continue
    if status_int != 0:
        short = label_col.replace("com.cast.", "")
        failing_jobs.append((short, status_int))

# ── Emit banner only when something is wrong ──────────────────────────────────
stale_count = len(stale_memories)
fail_count = len(failing_jobs)

if stale_count == 0 and fail_count == 0:
    import sys; sys.exit(0)

# Build compact banner line
mem_word = "memory" if stale_count == 1 else "memories"
job_word = "job" if fail_count == 1 else "jobs"

parts = []
if stale_count > 0:
    parts.append(f"{stale_count} stale {mem_word}")
if fail_count > 0:
    parts.append(f"{fail_count} launchd {job_word} failing")
banner = "🩺 health | " + " · ".join(parts)

# Build detail lines (cap at 5 each to stay terse)
detail_lines = []
if stale_memories:
    detail_lines.append("## Stale memories (verified_at > 30 days + concrete ref):")
    for name, age in stale_memories[:5]:
        detail_lines.append(f"  • {name} ({age}d ago)")
    if stale_count > 5:
        detail_lines.append(f"  … and {stale_count - 5} more")
if failing_jobs:
    detail_lines.append("## Failing launchd jobs (com.cast.*):")
    for short, status in failing_jobs[:5]:
        detail_lines.append(f"  • {short} (exit {status})")
    if fail_count > 5:
        detail_lines.append(f"  … and {fail_count - 5} more")

detail_text = "\n".join(detail_lines)

output = {
    "systemMessage": banner,
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": detail_text
    }
}
print(json.dumps(output))
PYEOF

exit 0
