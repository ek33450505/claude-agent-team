#!/bin/bash
# auto-format.sh — runs prettier on modified files after Write/Edit
# Triggered by PostToolUse hook for Write|Edit operations
# Only formats JS/TS/CSS/JSON files in projects that have prettier configured

read -r INPUT
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)

if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  if [[ "$FILE_PATH" =~ \.(js|jsx|ts|tsx|css|json)$ ]]; then
    # Find the project root (look for package.json)
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
exit 0
