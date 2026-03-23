#!/bin/bash
# post-tool-hook.sh — Combined PostToolUse hook for Write|Edit operations
# 1. Auto-formats JS/TS/CSS/JSON files with prettier (all sessions including subagents)
# 2. Injects [CAST-REVIEW] directive for code-reviewer dispatch (main session only)

INPUT="$(cat)"
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)

# --- Part 1: Auto-format with prettier (always, including subagents) ---
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  if [[ "$FILE_PATH" =~ \.(js|jsx|ts|tsx|css|json)$ ]]; then
    DIR=$(dirname "$FILE_PATH")
    while [[ "$DIR" != "/" && "$DIR" != "$HOME" ]]; do
      if [[ -f "$DIR/.prettierrc" || -f "$DIR/.prettierrc.json" || -f "$DIR/prettier.config.js" ]]; then
        cd "$DIR" && npx prettier --write "$FILE_PATH" 2>/dev/null
        break
      fi
      DIR=$(dirname "$DIR")
    done
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

exit 0
