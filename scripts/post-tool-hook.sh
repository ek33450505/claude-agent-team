#!/bin/bash
# post-tool-hook.sh — Combined PostToolUse hook for Write|Edit operations
# 1. Auto-formats JS/TS/CSS/JSON files with prettier (all sessions including subagents)
# 2. Injects [CAST-CHAIN] / [CAST-REVIEW] directive differentiated by session context + file type
# 3. Detects Agent Dispatch Manifests in .md plan files (all sessions, including subagents)

set -euo pipefail

INPUT="$(cat)"
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

# --- Part 1: Auto-format with prettier (always, including subagents) ---
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  if [[ "$FILE_PATH" =~ \.(js|jsx|ts|tsx|css|json)$ ]]; then
    # Security: canonicalize path and ensure it stays within $HOME
    REAL_PATH=$(realpath "$FILE_PATH" 2>/dev/null) || REAL_PATH=""
    if [[ -n "$REAL_PATH" && "$REAL_PATH" == "$HOME/"* ]]; then
      DIR=$(dirname "$REAL_PATH")
      SEARCH_DIR="$DIR"
      while [[ "$SEARCH_DIR" != "/" && "$SEARCH_DIR" != "$HOME" ]]; do
        if [[ -f "$SEARCH_DIR/.prettierrc" || -f "$SEARCH_DIR/.prettierrc.json" || -f "$SEARCH_DIR/prettier.config.js" ]]; then
          # Use subshell to avoid mutating the script's working directory
          (cd "$SEARCH_DIR" && npx prettier --write "$REAL_PATH" 2>/dev/null) || true
          break
        fi
        SEARCH_DIR=$(dirname "$SEARCH_DIR")
      done
    fi
  fi
fi

# --- Part 2: Inject review/chain directive ---
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  IS_CODE_FILE=false
  if [[ "$FILE_PATH" =~ \.(js|jsx|ts|tsx|sh|py|mjs|cjs)$ ]]; then
    IS_CODE_FILE=true
  fi

  if [ "${CLAUDE_SUBPROCESS:-0}" != "1" ]; then
    # Main session + code file: HARD [CAST-CHAIN] — mandatory, non-skippable
    if $IS_CODE_FILE; then
      python3 -c "
import json
msg = '[CAST-CHAIN] Code file modified. MANDATORY: After completing your current logical unit, dispatch in sequence: (1) \`code-reviewer\` (haiku) — review all changes in this unit. (2) \`test-writer\` (sonnet) if logic was added. Do NOT proceed to next unit or commit until code-reviewer returns Status: DONE or DONE_WITH_CONCERNS. Skipping is a protocol violation.'
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': msg}}))
"
    else
      # Main session + non-code file: soft review suggestion
      cat <<'DIRECTIVE'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[CAST-REVIEW] Non-code file modified. Dispatch `code-reviewer` if the change is significant."}}
DIRECTIVE
    fi
  else
    # Subagent + code file: reinforcing signal (agent's own instructions are primary)
    if $IS_CODE_FILE; then
      # Check nesting depth — deeper nesting needs stronger warning
      DEPTH_FILE="/tmp/cast-depth-${PPID}.depth"
      SUBAGENT_DEPTH=1
      if [ -f "$DEPTH_FILE" ]; then
        SUBAGENT_DEPTH="$(cat "$DEPTH_FILE" 2>/dev/null || echo 1)"
      fi
      if [ "$SUBAGENT_DEPTH" -ge 2 ]; then
        python3 -c "
import json
msg = 'DEEP NESTING WARNING: [CAST-REVIEW] Code modified in subagent context. Per your agent instructions, dispatch \`code-reviewer\` after this logical unit completes. If Agent tool dispatch fails at this depth, the inline session must re-dispatch code-reviewer as fallback.'
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': msg}}))
"
      else
        python3 -c "
import json
msg = '[CAST-REVIEW] Code modified in subagent context. Per your agent instructions, dispatch \`code-reviewer\` after this logical unit completes.'
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': msg}}))
"
      fi
    fi
  fi
fi

# --- Part 3: Detect Agent Dispatch Manifests in .md plan files (all sessions) ---
# Fires for Write operations on .md files under a /plans/ directory, regardless of
# whether running in a main session or subagent. This ensures planner subagents
# writing plan files also trigger orchestrator dispatch.
# If the file contains a ```json dispatch block, inject [CAST-ORCHESTRATE] directive.
if [[ "$TOOL_NAME" == "Write" && "$FILE_PATH" == *"/plans/"* && "$FILE_PATH" == *.md ]]; then
  REAL_PLAN_PATH=$(realpath "$FILE_PATH" 2>/dev/null) || REAL_PLAN_PATH=""
  if [[ -n "$REAL_PLAN_PATH" && "$REAL_PLAN_PATH" == "$HOME/"* ]]; then
    if grep -q '```json dispatch' "$REAL_PLAN_PATH" 2>/dev/null; then
      python3 -c "
import json, sys
msg = '[CAST-ORCHESTRATE] Plan file at $REAL_PLAN_PATH contains an Agent Dispatch Manifest. Dispatch the \`orchestrator\` agent via the Agent tool with this plan file path. Present the queue to the user for approval before executing any batches.'
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': msg}}))
"
    fi
  fi
fi

# --- Part 4: PostToolUse(Agent) — dispatch logging to routing-log.jsonl ---
if [[ "$TOOL_NAME" == "Agent" ]]; then
  # Parse subagent_type and prompt_preview from the INPUT var (same JSON the outer script reads)
  SUBAGENT_TYPE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ti = data.get('tool_input', {})
    print(ti.get('subagent_type', ti.get('agent_type', 'unknown')))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")

  PROMPT_PREVIEW=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ti = data.get('tool_input', {})
    prompt = ti.get('prompt', ti.get('task', ''))
    print(prompt[:80].replace('\n', ' '))
except Exception:
    print('')
" 2>/dev/null || echo "")

  SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  LOG_FILE="$HOME/.claude/routing-log.jsonl"

  python3 -c "
import json, sys
entry = {
    'timestamp': '$TIMESTAMP',
    'session_id': '$SESSION_ID',
    'action': 'agent_dispatched',
    'matched_route': '$SUBAGENT_TYPE',
    'prompt_preview': $(echo "$PROMPT_PREVIEW" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read().strip()))"),
    'confidence': 'direct'
}
with open('$LOG_FILE', 'a') as f:
    f.write(json.dumps(entry) + '\n')
" 2>/dev/null || true
fi

# --- Part 5: PostToolUse(Bash non-zero exit) → [CAST-DEBUG] directive ---
# Only fires in main session (not in subagents) to avoid infinite loops
if [[ "$TOOL_NAME" == "Bash" && "${CLAUDE_SUBPROCESS:-0}" != "1" ]]; then
  echo "$INPUT" | python3 - <<'PYEOF' || true
import sys, json, re

try:
    data = json.load(sys.stdin)
    tool_input = data.get('tool_input', {})
    tool_response = data.get('tool_response', {})
    command = tool_input.get('command', '')

    # Try to get exit code from tool_response
    exit_code = tool_response.get('exit_code', None)

    # If no exit_code field, try to detect from output
    if exit_code is None:
        output = str(tool_response.get('output', ''))
        # Look for patterns like "Exit code: N" or "exited with N"
        m = re.search(r'[Ee]xit\s+(?:code[:\s]+)?(\d+)', output)
        if m:
            exit_code = int(m.group(1))
        elif tool_response.get('error'):
            exit_code = 1
        else:
            # No indication of non-zero exit — suppress
            sys.exit(0)

    exit_code = int(exit_code)
    if exit_code == 0:
        sys.exit(0)

    # Grace list: suppress CAST-DEBUG for known benign non-zero exits
    cmd = command.strip()
    if exit_code == 1:
        if cmd.startswith('grep') or cmd.startswith('rg'):
            sys.exit(0)  # grep/rg returning 1 = no match, not an error
        if cmd.startswith('git diff'):
            sys.exit(0)  # git diff exit 1 = differences found, not an error
        if cmd.startswith('git log') and exit_code == 1:
            sys.exit(0)  # git log with empty output

    directive = (
        f'[CAST-DEBUG] Bash command exited with code {exit_code}. '
        'Per CAST protocol, route this failure to the `debugger` agent via the Agent tool. '
        'Do NOT inline-triage beyond one tool call. Pass the failed command and its output as context.'
    )
    output = {
        'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': directive
        }
    }
    print(json.dumps(output))
    sys.exit(0)

except Exception:
    sys.exit(0)
PYEOF
fi

exit 0
