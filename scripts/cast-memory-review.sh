#!/bin/bash
# cast-memory-review.sh — TUI for reviewing pending memory queue
# Phase 4.8.2: low-confidence auto-memory review and promotion
#
# Usage:
#   cast-memory-review.sh [--list|--auto-promote]
#   --list              List pending entries across all projects (no prompts)
#   --auto-promote      Promote pending files >7 days old to canonical location

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────

PROJECTS_DIR="${HOME}/.claude/projects"
MODE="${1:-interactive}"  # "interactive", "list", "auto-promote"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: format file age in days
# ─────────────────────────────────────────────────────────────────────────────

_file_age_days() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "?"
    return
  fi

  local mtime
  mtime=$(stat -c "%Y" "$file" 2>/dev/null || stat -f "%m" "$file" 2>/dev/null || echo 0)
  if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
    mtime=0
  fi
  if [ "$mtime" = "0" ]; then
    echo "?"
    return
  fi

  local now
  now=$(date +%s)
  local age_secs=$((now - mtime))
  local age_days=$((age_secs / 86400))
  echo "$age_days"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: read frontmatter fields from a memory file
# ─────────────────────────────────────────────────────────────────────────────

_read_frontmatter() {
  local file="$1"
  local field="$2"

  if [ ! -f "$file" ]; then
    echo ""
    return
  fi

  python3 << PYEOF 2>/dev/null || echo ""
import re
try:
    with open("$file", 'r') as f:
        content = f.read()

    if not content.startswith('---'):
        print("")
        exit()

    parts = content.split('---')
    if len(parts) < 3:
        print("")
        exit()

    frontmatter = parts[1]

    for line in frontmatter.split('\n'):
        if line.startswith('$field:'):
            value = line.split(':', 1)[1].strip()
            # Strip quotes if present
            value = value.strip('\'"')
            print(value)
            exit()

    print("")
except:
    print("")
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Mode: --list — display pending entries
# ─────────────────────────────────────────────────────────────────────────────

_mode_list() {
  local pending_files=()

  # Walk all projects
  if [ ! -d "$PROJECTS_DIR" ]; then
    echo "[review] no pending memories"
    return 0
  fi

  for proj_dir in "$PROJECTS_DIR"/*; do
    if [ ! -d "$proj_dir" ]; then continue; fi

    local pending_dir="$proj_dir/memory/_pending"
    if [ ! -d "$pending_dir" ]; then continue; fi

    for file in "$pending_dir"/*.md; do
      if [ ! -f "$file" ]; then continue; fi
      if [ "$(basename "$file")" = "MEMORY.md" ]; then continue; fi
      pending_files+=("$file")
    done
  done

  if [ ${#pending_files[@]} -eq 0 ]; then
    echo "[review] no pending memories"
    return 0
  fi

  local count=0
  for file in "${pending_files[@]}"; do
    count=$((count + 1))
    local proj_path="${file%/memory/_pending/*}"
    local proj_name
    proj_name="$(basename "$proj_path")"
    local file_name
    file_name="$(basename "$file")"
    local age_days
    age_days=$(_file_age_days "$file")
    local name
    name=$(_read_frontmatter "$file" "name")

    printf "%3d. %s/%s — %s days old\n" "$count" "$proj_name" "$file_name" "$age_days"
    if [ -n "$name" ]; then
      printf "     Name: %s\n" "$name"
    fi
  done

  echo ""
  echo "[review] $count pending entries"
}

# ─────────────────────────────────────────────────────────────────────────────
# Mode: --auto-promote — move files >7 days old to canonical
# ─────────────────────────────────────────────────────────────────────────────

_mode_auto_promote() {
  local pending_files=()
  local promoted=0

  if [ ! -d "$PROJECTS_DIR" ]; then
    echo "[auto-promote] no pending memories"
    return 0
  fi

  for proj_dir in "$PROJECTS_DIR"/*; do
    if [ ! -d "$proj_dir" ]; then continue; fi

    local pending_dir="$proj_dir/memory/_pending"
    if [ ! -d "$pending_dir" ]; then continue; fi

    for file in "$pending_dir"/*.md; do
      if [ ! -f "$file" ]; then continue; fi
      if [ "$(basename "$file")" = "MEMORY.md" ]; then continue; fi

      local age_days
      age_days=$(_file_age_days "$file")
      if [ "$age_days" = "?" ] || [ "$age_days" -lt 7 ]; then
        continue
      fi

      # File is > 7 days old — promote it
      local file_name
      file_name="$(basename "$file")"
      local canonical_file="$proj_dir/memory/$file_name"
      local memory_idx="$proj_dir/memory/MEMORY.md"

      # Move to canonical location (skip if already exists)
      if [ -e "$canonical_file" ]; then
        continue
      fi
      mv "$file" "$canonical_file" || continue
      promoted=$((promoted + 1))

      # Update MEMORY.md index if needed
      if [ ! -f "$memory_idx" ]; then
        mkdir -p "$(dirname "$memory_idx")"
        echo "# Memory Index" > "$memory_idx"
        echo "" >> "$memory_idx"
      fi

      local name
      name=$(_read_frontmatter "$canonical_file" "name")
      local desc
      desc=$(_read_frontmatter "$canonical_file" "description")

      # Check if already in index
      if ! grep -q "^\- \[.*\]($file_name)" "$memory_idx" 2>/dev/null; then
        echo "- [$file_name]($file_name) — $desc" >> "$memory_idx"
      fi
    done
  done

  echo "[auto-promote] promoted $promoted (>7 days old)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Mode: interactive — TUI for approve/reject/skip
# ─────────────────────────────────────────────────────────────────────────────

_mode_interactive() {
  local pending_files=()
  local approved=0
  local rejected=0
  local skipped=0

  if [ ! -d "$PROJECTS_DIR" ]; then
    echo "[review] no pending memories"
    return 0
  fi

  # Collect all pending files
  for proj_dir in "$PROJECTS_DIR"/*; do
    if [ ! -d "$proj_dir" ]; then continue; fi

    local pending_dir="$proj_dir/memory/_pending"
    if [ ! -d "$pending_dir" ]; then continue; fi

    for file in "$pending_dir"/*.md; do
      if [ ! -f "$file" ]; then continue; fi
      if [ "$(basename "$file")" = "MEMORY.md" ]; then continue; fi
      pending_files+=("$file")
    done
  done

  if [ ${#pending_files[@]} -eq 0 ]; then
    echo "[review] no pending memories"
    return 0
  fi

  echo ""
  echo "Pending memory review — $(date +%Y-%m-%d)"
  echo "================================"
  echo ""

  for file in "${pending_files[@]}"; do
    local proj_path="${file%/memory/_pending/*}"
    local proj_name
    proj_name="$(basename "$proj_path")"
    local file_name
    file_name="$(basename "$file")"
    local age_days
    age_days=$(_file_age_days "$file")
    local name
    name=$(_read_frontmatter "$file" "name")
    local desc
    desc=$(_read_frontmatter "$file" "description")
    local type_field
    type_field=$(_read_frontmatter "$file" "type")

    # Print entry header
    printf "\n%s — %s days old\n" "$proj_name/$file_name" "$age_days"
    printf "  Type: %s\n" "$type_field"
    printf "  Name: %s\n" "$name"
    printf "  Desc: %s\n" "$desc"
    echo "  Body (first 30 lines):"

    # Extract and print body (first 30 lines)
    python3 << 'PYEOF' 2>/dev/null || true
import sys
try:
    with open("$file", 'r') as f:
        content = f.read()

    if not content.startswith('---'):
        sys.exit(1)

    parts = content.split('---')
    if len(parts) < 3:
        sys.exit(1)

    body = '---'.join(parts[2:]).strip()
    lines = body.split('\n')

    max_show = 30
    for i, line in enumerate(lines[:max_show]):
        print(f"    {line}")

    if len(lines) > max_show:
        print(f"    ... ({len(lines) - max_show} more lines)")
except:
    pass
PYEOF

    # Prompt for action
    printf "\n  [a]pprove / [r]eject / [s]kip / [q]uit? (default: skip) "

    local choice="s"
    # Try reading from /dev/tty if available, otherwise from stdin
    # Use first character of line read from either source
    if (exec </dev/tty) 2>/dev/null; then
      read -r choice_line </dev/tty 2>/dev/null || choice_line=""
      choice="${choice_line:0:1}"
      [ -z "$choice" ] && choice="s"
    else
      read -r choice_line 2>/dev/null || choice_line=""
      choice="${choice_line:0:1}"
      [ -z "$choice" ] && choice="s"
    fi

    echo ""  # newline after keystroke

    case "$choice" in
      a|A)
        # Approve: move to canonical and update index
        local canonical_file="$proj_path/memory/$file_name"
        local memory_idx="$proj_path/memory/MEMORY.md"

        if [ -e "$canonical_file" ]; then
          printf "  [skip] canonical %s already exists, leaving in _pending/\n" "$file_name" >&2
        else
          mv "$file" "$canonical_file"

          # Create or update index
          if [ ! -f "$memory_idx" ]; then
            mkdir -p "$(dirname "$memory_idx")"
            echo "# Memory Index" > "$memory_idx"
            echo "" >> "$memory_idx"
          fi

          # Add entry if not present
          if ! grep -q "^\- \[.*\]($file_name)" "$memory_idx" 2>/dev/null; then
            echo "- [$file_name]($file_name) — $desc" >> "$memory_idx"
          fi

          echo "  ✓ Approved"
          approved=$((approved + 1))
        fi
        ;;

      r|R)
        # Reject: delete pending file
        rm -f "$file"
        echo "  ✗ Rejected"
        rejected=$((rejected + 1))
        ;;

      q|Q)
        # Quit: stop processing
        echo "  → Quit"
        break
        ;;

      *)
        # Skip or unknown: leave as-is
        echo "  → Skipped"
        skipped=$((skipped + 1))
        ;;
    esac
  done

  # Count remaining pending
  local remaining=0
  for proj_dir in "$PROJECTS_DIR"/*; do
    if [ ! -d "$proj_dir" ]; then continue; fi
    local pending_dir="$proj_dir/memory/_pending"
    if [ ! -d "$pending_dir" ]; then continue; fi
    remaining=$((remaining + $(find "$pending_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | grep -v MEMORY.md | wc -l)))
  done

  echo ""
  echo "================================"
  echo "[review] approved $approved, rejected $rejected, skipped $skipped, remaining $remaining pending"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatch
# ─────────────────────────────────────────────────────────────────────────────

case "${MODE}" in
  --list)
    _mode_list
    ;;
  --auto-promote)
    _mode_auto_promote
    ;;
  interactive|"")
    _mode_interactive
    ;;
  *)
    printf "Usage: %s [--list|--auto-promote]\n" "$(basename "$0")" >&2
    exit 1
    ;;
esac
