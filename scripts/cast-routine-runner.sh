#!/usr/bin/env bash
# cast-routine-runner.sh — single entry point for all routine trigger types.
# Usage: cast-routine-runner.sh <routine-name> [--dry-run] [--from-cron]
#
# Env:
#   CAST_ROUTINES_DIR   override default ~/.claude/routines
#   CAST_DB_PATH        override default ~/.claude/cast.db
#   CAST_SCRIPTS_DIR    override default ~/.claude/scripts
#   CAST_CRONTAB_CMD    override crontab binary (useful in tests)

# ── Subprocess bypass ────────────────────────────────────────────────────────
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# ── Constants / defaults ─────────────────────────────────────────────────────
SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-$HOME/.claude/scripts}"
ROUTINES_DIR="${CAST_ROUTINES_DIR:-$HOME/.claude/routines}"

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=0
FROM_CRON=0
ROUTINE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --from-cron) FROM_CRON=1; shift ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$ROUTINE_NAME" ]]; then
        ROUTINE_NAME="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$ROUTINE_NAME" ]]; then
  echo "Usage: cast-routine-runner.sh <routine-name> [--dry-run] [--from-cron]" >&2
  exit 1
fi

# Validate routine name (prevent path traversal)
if ! [[ "$ROUTINE_NAME" =~ ^[a-z][a-z0-9_-]{0,63}$ ]]; then
  echo "Error: Invalid routine name: '$ROUTINE_NAME'. Must match ^[a-z][a-z0-9_-]{0,63}\$ (start with lowercase letter, lowercase alphanumerics + hyphen + underscore, max 64 chars)." >&2
  exit 1
fi

# ── Step 1: Verify YAML exists ───────────────────────────────────────────────
YAML_FILE="$ROUTINES_DIR/$ROUTINE_NAME.yaml"
if [[ ! -f "$YAML_FILE" ]]; then
  echo "Error: routine YAML not found: $YAML_FILE" >&2
  exit 1
fi

# ── Step 2: Parse YAML fields via Python yaml stdlib ─────────────────────────
# Reads agent, prompt_template, output_dir from the YAML.
# Never evals YAML field values — treats them as data.
_parse_yaml() {
  python3 - "$YAML_FILE" <<'PYEOF'
import sys, yaml, json

try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(json.dumps({"error": f"invalid YAML: {e}"}), file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(json.dumps({"error": str(e)}), file=sys.stderr)
    sys.exit(1)

result = {
    "agent":           data.get("agent", ""),
    "prompt_template": data.get("prompt_template", ""),
    "output_dir":      data.get("output_dir", ""),
    "trigger_type":    data.get("trigger", {}).get("type", "manual"),
    "trigger_value":   data.get("trigger", {}).get("value", ""),
    "description":     data.get("description", ""),
}
print(json.dumps(result))
PYEOF
}

PARSED="$(_parse_yaml)"

AGENT="$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['agent'])")"
PROMPT_TEMPLATE="$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['prompt_template'])")"
OUTPUT_DIR_RAW="$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_dir'])")"

# ── Step 5 (early): Verify agent exists in agents/core/ ──────────────────────
# Derive repo dir relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_FILE="$REPO_DIR/agents/core/$AGENT.md"
if [[ ! -f "$AGENT_FILE" ]]; then
  echo "Error: agent not found in agents/core/: $AGENT" >&2
  exit 1
fi

# ── Step 3: Expand output_dir ────────────────────────────────────────────────
OUTPUT_DIR_EXPANDED="${OUTPUT_DIR_RAW/\~/$HOME}"
OUTPUT_DIR_EXPANDED="${OUTPUT_DIR_EXPANDED/\$HOME/$HOME}"

# Security: validate output_dir resolves under ~/.claude/routines-output/
ALLOWED_BASE="$(realpath "$HOME/.claude/routines-output" 2>/dev/null || echo "$HOME/.claude/routines-output")"
# Resolve parent dir with realpath (handles symlinks); accept if parent dir doesn't exist yet
OUTPUT_DIR_REAL="$(python3 -c "
import os, sys
candidate = os.path.expanduser(sys.argv[1])
# Resolve parent directory to handle symlinks
parent_dir = os.path.dirname(candidate)
if os.path.exists(parent_dir):
    parent_real = os.path.realpath(parent_dir)
    basename = os.path.basename(candidate)
    OUTPUT_DIR_REAL = os.path.join(parent_real, basename)
else:
    # Parent doesn't exist yet; resolve what we can
    OUTPUT_DIR_REAL = os.path.realpath(parent_dir + '/dummy')
    OUTPUT_DIR_REAL = OUTPUT_DIR_REAL[:-len('/dummy')]
    OUTPUT_DIR_REAL = os.path.join(OUTPUT_DIR_REAL, os.path.basename(candidate))
print(OUTPUT_DIR_REAL)
" "$OUTPUT_DIR_EXPANDED")"

allowed_base_real="$(python3 -c "import os; print(os.path.realpath(os.path.expanduser('$HOME/.claude/routines-output')))")"
if ! [[ "$OUTPUT_DIR_REAL" == "$allowed_base_real" || "$OUTPUT_DIR_REAL" == "$allowed_base_real"/* ]]; then
  echo "Error: output_dir must resolve under ~/.claude/routines-output/ — got: $OUTPUT_DIR_REAL" >&2
  exit 1
fi

# ── Step 4: Generate output filename ─────────────────────────────────────────
TIMESTAMP="$(date -u +%Y-%m-%d-%H%M)"
OUTPUT_FILE="$OUTPUT_DIR_REAL/$TIMESTAMP.md"

# ── Step 6: Render prompt (substitute {{routine_name}} and {{routine_output_path}}) ──
RENDERED_PROMPT="${PROMPT_TEMPLATE//\{\{routine_name\}\}/$ROUTINE_NAME}"
RENDERED_PROMPT="${RENDERED_PROMPT//\{\{routine_output_path\}\}/$OUTPUT_FILE}"

# ── Dry-run: print plan and exit ─────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "=== cast-routine-runner dry-run ==="
  echo "routine:     $ROUTINE_NAME"
  echo "yaml:        $YAML_FILE"
  echo "agent:       $AGENT"
  echo "output_path: $OUTPUT_FILE"
  echo "--- rendered prompt ---"
  echo "$RENDERED_PROMPT"
  echo "--- end ---"
  exit 0
fi

# ── Step 7: Ensure output dir exists ─────────────────────────────────────────
mkdir -p "$OUTPUT_DIR_REAL"

# ── Step 8: Dispatch agent via cast-managed-agent.sh ─────────────────────────
# CAST_MANAGED_AGENT_CMD overrides the dispatch command (used in BATS tests to mock dispatch)
MANAGED_AGENT_SCRIPT="${CAST_MANAGED_AGENT_CMD:-}"
if [[ -z "$MANAGED_AGENT_SCRIPT" ]]; then
  MANAGED_AGENT_SCRIPT="$SCRIPTS_DIR/cast-managed-agent.sh"
  if [[ ! -f "$MANAGED_AGENT_SCRIPT" ]]; then
    MANAGED_AGENT_SCRIPT="$REPO_DIR/scripts/cast-managed-agent.sh"
  fi
fi

RUN_STATUS="success"

AGENT_OUTPUT=""
if AGENT_OUTPUT="$(bash "$MANAGED_AGENT_SCRIPT" "$AGENT" "$RENDERED_PROMPT" --local-fallback 2>&1)"; then
  RUN_STATUS="success"
else
  RUN_STATUS="failure"
fi

# ── Step 9: Write agent output to file ───────────────────────────────────────
{
  echo "# Routine: $ROUTINE_NAME"
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "$AGENT_OUTPUT"
} > "$OUTPUT_FILE"

# ── Step 10: Update cast.db via cast-db-routines.py ──────────────────────────
DB_ROUTINES_SCRIPT="$SCRIPTS_DIR/cast-db-routines.py"
if [[ ! -f "$DB_ROUTINES_SCRIPT" ]]; then
  DB_ROUTINES_SCRIPT="$REPO_DIR/scripts/cast-db-routines.py"
fi

if [[ -f "$DB_ROUTINES_SCRIPT" ]]; then
  CAST_DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}" \
    python3 "$DB_ROUTINES_SCRIPT" update-status "$ROUTINE_NAME" "$RUN_STATUS" "$OUTPUT_FILE" \
    >/dev/null 2>&1 || true
fi

# ── Step 11: Emit routine_completed event (best-effort) ──────────────────────
EVENTS_SCRIPT="$SCRIPTS_DIR/cast-events.sh"
if [[ ! -f "$EVENTS_SCRIPT" ]]; then
  EVENTS_SCRIPT="$REPO_DIR/scripts/cast-events.sh"
fi

if [[ -f "$EVENTS_SCRIPT" ]]; then
  # shellcheck source=/dev/null
  source "$EVENTS_SCRIPT" 2>/dev/null || true
  cast_emit_event 'routine_completed' 'cast-routine-runner' "$ROUTINE_NAME" '' 'completed' 'DONE' '' 2>/dev/null || true
fi

echo "Routine '$ROUTINE_NAME' completed with status: $RUN_STATUS"
echo "Output: $OUTPUT_FILE"

if [[ "$RUN_STATUS" == "failure" ]]; then
  exit 1
fi

exit 0
