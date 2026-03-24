#!/bin/bash
# post-tool-hook.sh — Combined PostToolUse hook for Write|Edit operations
# 1. Auto-formats JS/TS/CSS/JSON files with prettier (all sessions including subagents)
# 2. Injects [CAST-REVIEW] directive for code-reviewer dispatch (main session only)
# 3. Detects Agent Dispatch Manifests in .md plan files (main session only)

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

# --- Part 2: Inject review directive (main session only) ---
# Subagents (CLAUDE_SUBPROCESS=1) should NOT get review directives —
# they are doing focused work and the main session handles review orchestration.
if [ "${CLAUDE_SUBPROCESS:-0}" != "1" ]; then
  cat <<'DIRECTIVE'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[CAST-REVIEW] Code was modified. After completing your current logical unit of changes, dispatch `code-reviewer` agent (haiku) to review. Do not skip this step."}}
DIRECTIVE
fi

# --- Part 3: Detect Agent Dispatch Manifests in .md plan files (main session only) ---
# Only fires for Write operations on .md files under a /plans/ directory.
# If the file contains a ```json dispatch block, inject [CAST-ORCHESTRATE] directive.
if [ "${CLAUDE_SUBPROCESS:-0}" != "1" ]; then
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
fi

exit 0
