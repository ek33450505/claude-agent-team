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

export CAST_INPUT="$INPUT"
export CAST_LAUNCHCTL_OUTPUT="$LAUNCHCTL_OUTPUT"
export CAST_HOME="$HOME"

python3 - <<'PYEOF' || _log_error "session-start-health python block failed (exit $?)"
import json, os, re, glob
from datetime import date, datetime

home = os.environ.get("CAST_HOME", os.path.expanduser("~"))
launchctl_out = os.environ.get("CAST_LAUNCHCTL_OUTPUT", "")

# ── Stale memory detection ────────────────────────────────────────────────────
STALE_DAYS = 30
today = date.today()

# Patterns that indicate a concrete path/function/flag reference in the body
CONCRETE_PATTERNS = [
    re.compile(r'/scripts/'),
    re.compile(r'~/\.claude/'),
    re.compile(r'~/.claude/'),
    re.compile(r'\b\w+\(\)'),
    re.compile(r'--[a-z]'),
]

stale_memories = []
memory_glob = os.path.join(home, ".claude", "projects", "*", "memory", "*.md")
for filepath in sorted(glob.glob(memory_glob)):
    try:
        with open(filepath, "r", errors="replace") as fh:
            content = fh.read()

        # Parse verified_at from YAML-ish frontmatter
        verified_at = None
        in_frontmatter = False
        lines = content.splitlines()
        for i, line in enumerate(lines):
            stripped = line.strip()
            if i == 0 and stripped == "---":
                in_frontmatter = True
                continue
            if in_frontmatter:
                if stripped == "---":
                    break  # end of frontmatter
                if stripped.startswith("verified_at:"):
                    val = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                    try:
                        verified_at = datetime.strptime(val, "%Y-%m-%d").date()
                    except ValueError:
                        pass
                    break

        if verified_at is None:
            continue

        age_days = (today - verified_at).days
        if age_days <= STALE_DAYS:
            continue

        # Check body for concrete path/function/flag references
        body_has_concrete = any(p.search(content) for p in CONCRETE_PATTERNS)
        if not body_has_concrete:
            continue

        # Extract name: from frontmatter, or fall back to filename stem
        mem_name = os.path.splitext(os.path.basename(filepath))[0]
        for line in lines:
            stripped = line.strip()
            if in_frontmatter and stripped.startswith("name:"):
                mem_name = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                break
            # Re-scan frontmatter for name
        for line in lines[1:]:
            stripped = line.strip()
            if stripped == "---":
                break
            if stripped.startswith("name:"):
                mem_name = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                break

        stale_memories.append((mem_name, age_days))
    except Exception:
        continue  # defensive: skip unreadable files

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
