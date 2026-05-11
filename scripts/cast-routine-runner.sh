#!/usr/bin/env bash
# cast-routine-runner.sh — single entry point for all routine trigger types.
# Usage: cast-routine-runner.sh <routine-name> [--dry-run] [--from-cron] [--arg key=value ...]
#
# Env:
#   CAST_ROUTINES_DIR          override default ~/.claude/routines
#   CAST_DB_PATH               override default ~/.claude/cast.db
#   CAST_SCRIPTS_DIR           override default ~/.claude/scripts
#   CAST_CRONTAB_CMD           override crontab binary (useful in tests)
#   CAST_ROUTINE_SKIP_MCP_CHECK  set to 1 to bypass mcp_required pre-flight check

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
declare -A PROMPT_ARGS

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --from-cron) FROM_CRON=1; shift ;;
    --arg)
      shift
      if [[ -z "${1:-}" ]]; then
        echo "Error: --arg requires a key=value argument" >&2
        exit 1
      fi
      _arg_key="${1%%=*}"
      _arg_val="${1#*=}"
      PROMPT_ARGS["$_arg_key"]="$_arg_val"
      shift
      ;;
    --arg=*)
      _kv="${1#--arg=}"
      _arg_key="${_kv%%=*}"
      _arg_val="${_kv#*=}"
      PROMPT_ARGS["$_arg_key"]="$_arg_val"
      shift
      ;;
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
  echo "Usage: cast-routine-runner.sh <routine-name> [--dry-run] [--from-cron] [--arg key=value ...]" >&2
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
    "prompt_args":     data.get("prompt_args", []),
    "mcp_required":    data.get("mcp_required", []),
}
print(json.dumps(result))
PYEOF
}

PARSED="$(_parse_yaml)"

AGENT="$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['agent'])")"
PROMPT_TEMPLATE="$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['prompt_template'])")"
OUTPUT_DIR_RAW="$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_dir'])")"
PROMPT_ARGS_JSON="$(echo "$PARSED" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['prompt_args']))")"
MCP_REQUIRED_JSON="$(echo "$PARSED" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['mcp_required']))")"

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

# ── Step 5b: Validate required prompt_args ───────────────────────────────────
# Build a JSON object of supplied args from the PROMPT_ARGS associative array.
# Use a temp file to avoid heredoc-in-condition parsing issues.
_ARGS_VALIDATE_PY="$(mktemp -t cast-routine-args.XXXXXX)"
cat > "$_ARGS_VALIDATE_PY" <<'PYEOF'
import sys, json

prompt_args_spec = json.loads(sys.argv[1])  # list of {name, required}
supplied        = json.loads(sys.argv[2])   # dict of supplied key->value

errors = []
for spec in prompt_args_spec:
    name     = spec.get("name", "")
    required = spec.get("required", False)
    if required and name not in supplied:
        errors.append(f"required prompt_arg '{name}' not supplied (use --arg {name}=<value>)")

if errors:
    for e in errors:
        print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

# Serialize PROMPT_ARGS associative array to JSON.
# `${PROMPT_ARGS[*]+x}` guards against the bash strict-mode (set -u) edge
# case where an empty associative array reports as "unbound" rather than
# length 0. Short-circuit AND ensures the length check only runs when
# the array has been written to at least once.
SUPPLIED_ARGS_JSON="{}"
if [[ -n "${PROMPT_ARGS[*]+x}" && ${#PROMPT_ARGS[@]} -gt 0 ]]; then
  _supplied_parts=""
  for _k in "${!PROMPT_ARGS[@]}"; do
    _v="${PROMPT_ARGS[$_k]}"
    # Escape backslash and double-quote for JSON
    _v_escaped="${_v//\\/\\\\}"
    _v_escaped="${_v_escaped//\"/\\\"}"
    _k_escaped="${_k//\\/\\\\}"
    _k_escaped="${_k_escaped//\"/\\\"}"
    _supplied_parts="${_supplied_parts},\"${_k_escaped}\":\"${_v_escaped}\""
  done
  SUPPLIED_ARGS_JSON="{${_supplied_parts:1}}"
fi

python3 "$_ARGS_VALIDATE_PY" "$PROMPT_ARGS_JSON" "$SUPPLIED_ARGS_JSON" >&2
_ARGS_RC=$?
rm -f "$_ARGS_VALIDATE_PY"
if [[ "$_ARGS_RC" -ne 0 ]]; then
  exit 1
fi

# ── Step 5c: MCP pre-flight check ────────────────────────────────────────────
if [[ "${CAST_ROUTINE_SKIP_MCP_CHECK:-0}" != "1" ]]; then
  SETTINGS_FILE="$HOME/.claude/settings.json"
  if [[ -n "$MCP_REQUIRED_JSON" && "$MCP_REQUIRED_JSON" != "[]" ]]; then
    if [[ ! -f "$SETTINGS_FILE" ]]; then
      # No settings.json at all — warn but continue
      echo "[MCP pre-flight] Warning: ~/.claude/settings.json not found; skipping MCP check." >&2
    else
      _MCP_PREFLIGHT_PY="$(mktemp -t cast-routine-mcp.XXXXXX)"
      cat > "$_MCP_PREFLIGHT_PY" <<'PYEOF'
import sys, json

mcp_required  = json.loads(sys.argv[1])
routine_name  = sys.argv[2]
settings_path = sys.argv[3]

try:
    with open(settings_path) as f:
        settings = json.load(f)
except Exception as e:
    print(f"[MCP pre-flight] Warning: could not parse {settings_path}: {e}", file=sys.stderr)
    sys.exit(0)

mcp_servers = settings.get("mcpServers", {})
missing = [m for m in mcp_required if m not in mcp_servers]
if missing:
    for m in missing:
        print(
            f"[MCP pre-flight] Routine '{routine_name}' requires MCP server '{m}' "
            f"but it is not configured in ~/.claude/settings.json mcpServers. "
            f"Wire it before triggering, OR set CAST_ROUTINE_SKIP_MCP_CHECK=1 to bypass.",
            file=sys.stderr
        )
    sys.exit(1)
PYEOF
      python3 "$_MCP_PREFLIGHT_PY" "$MCP_REQUIRED_JSON" "$ROUTINE_NAME" "$SETTINGS_FILE" >&2
      _MCP_RC=$?
      rm -f "$_MCP_PREFLIGHT_PY"
      if [[ "$_MCP_RC" -ne 0 ]]; then
        exit 1
      fi
    fi
  fi
fi

# ── Step 6: Render prompt (substitute built-in + prompt_args placeholders) ───
RENDERED_PROMPT="${PROMPT_TEMPLATE//\{\{routine_name\}\}/$ROUTINE_NAME}"
RENDERED_PROMPT="${RENDERED_PROMPT//\{\{routine_output_path\}\}/$OUTPUT_FILE}"

# Substitute {{<arg_name>}} placeholders from supplied PROMPT_ARGS.
# Same `set -u` guard as the JSON serializer above.
if [[ -n "${PROMPT_ARGS[*]+x}" && ${#PROMPT_ARGS[@]} -gt 0 ]]; then
  for _key in "${!PROMPT_ARGS[@]}"; do
    _val="${PROMPT_ARGS[$_key]}"
    RENDERED_PROMPT="${RENDERED_PROMPT//\{\{${_key}\}\}/$_val}"
  done
fi

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
