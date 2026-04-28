#!/usr/bin/env bash
# cast-sync-check.sh — verify runtime locations match repo source of truth
# Exit 0: clean (or warnings only). Exit 2: drift detected.

# CAST subprocess guard — must come before set -euo pipefail
[[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]] && exit 0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CAST_REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

# Runtime-only scripts owned by other repos — not drift
RUNTIME_ONLY_ALLOW_LIST=(
  "cast-session-start-journal.sh"
  "engram-style-capture.py"
  "engram-identity-start.sh"
  "engram-session-end.sh"
  "engram-prompt-sentinel.py"
  "engram-journal-extractor.py"
  "stratum-session-start.sh"
  "stratum-close-sentinel.sh"
  "stratum-session-end.sh"
)

# Runtime path overrides for testability
CAST_RUNTIME_AGENTS="${CAST_RUNTIME_AGENTS:-$HOME/.claude/agents}"
CAST_RUNTIME_SCRIPTS="${CAST_RUNTIME_SCRIPTS:-$HOME/.claude/scripts}"

drift_count=0
warning_count=0
warnings=()

# Track all basenames known to repo agent sources (to detect runtime orphans)
# Bash 3.2-compatible: newline-delimited string set, not associative array
known_agent_basenames=""

# check_effort_model_mismatch <file>
# Emits a WARNING if the file has effort: xhigh but model is not opus.
check_effort_model_mismatch() {
  local file="$1"
  if grep -q "effort: xhigh" "$file" 2>/dev/null; then
    local model
    model=$(grep "^model:" "$file" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$model" != "opus" && "$model" != "claude-opus"* ]]; then
      warnings+=("WARNING: $file has effort:xhigh but model is '${model:-absent}' (field silently ignored)")
      ((warning_count++)) || true
    fi
  fi
}

# check_source_against_runtime <source_dir> <runtime_dir> <label> [track_basenames]
# Checks each file in source_dir against runtime_dir.
# When track_basenames=1, records found basenames into known_agent_basenames.
check_source_against_runtime() {
  local source_dir="$1"
  local runtime_dir="$2"
  local label="$3"
  local track_basenames="${4:-0}"

  if [[ ! -d "$source_dir" ]]; then
    return 0
  fi

  while IFS= read -r -d '' src_file; do
    local rel_path
    rel_path="${src_file#"$source_dir"/}"
    local basename_only
    basename_only="$(basename "$rel_path")"
    local runtime_file="$runtime_dir/$basename_only"

    if [[ "$track_basenames" == "1" ]]; then
      # Bash 3.2-compatible: add to newline-delimited set if not already present
      if ! echo "$known_agent_basenames" | grep -Fxq "$basename_only"; then
        known_agent_basenames+="$basename_only"$'\n'
      fi
    fi

    if [[ ! -e "$runtime_file" ]]; then
      echo "MISSING_IN_RUNTIME: $label/$rel_path"
      ((drift_count++)) || true
    else
      # Content check
      if ! diff -q "$src_file" "$runtime_file" >/dev/null 2>&1; then
        echo "CONTENT_DIFFERS: $label/$rel_path"
        ((drift_count++)) || true
      fi

      # Mode check — executable-bit only (install.sh chmod is expected and not drift)
      local src_mode runtime_mode src_exec runtime_exec
      src_mode="$(stat -c '%a' "$src_file" 2>/dev/null || stat -f '%OLp' "$src_file" 2>/dev/null || echo 'unknown')"
      runtime_mode="$(stat -c '%a' "$runtime_file" 2>/dev/null || stat -f '%OLp' "$runtime_file" 2>/dev/null || echo 'unknown')"
      src_exec=0; runtime_exec=0
      [[ "$src_mode" =~ [75] ]] && src_exec=1 || true
      [[ "$runtime_mode" =~ [75] ]] && runtime_exec=1 || true
      if [[ "$src_exec" != "$runtime_exec" ]]; then
        echo "MODE_DIFFERS: $label/$rel_path (repo: $src_mode, runtime: $runtime_mode)"
        ((drift_count++)) || true
      fi

      # Effort/model mismatch check (for agent .md files)
      if [[ "$src_file" == *.md ]]; then
        check_effort_model_mismatch "$src_file"
      fi
    fi
  done < <(find "$source_dir" -maxdepth 1 -type f -print0 2>/dev/null)
}

# check_runtime_orphans <runtime_dir>
# Detects files in runtime_dir whose basenames are not in known_agent_basenames.
check_runtime_orphans() {
  local runtime_dir="$1"
  if [[ ! -d "$runtime_dir" ]]; then
    return 0
  fi
  while IFS= read -r -d '' rt_file; do
    local bn
    bn="$(basename "$rt_file")"
    # Bash 3.2-compatible: check if basename is in the newline-delimited set
    if ! echo "$known_agent_basenames" | grep -Fxq "$bn"; then
      # Skip basenames owned by other repos
      local skip=0
      for allowed in "${RUNTIME_ONLY_ALLOW_LIST[@]}"; do
        [[ "$bn" == "$allowed" ]] && skip=1 && break
      done
      [[ "$skip" == "1" ]] && continue
      echo "MISSING_IN_REPO: $rt_file"
      ((drift_count++)) || true
    fi
  done < <(find "$runtime_dir" -maxdepth 1 -type f -print0 2>/dev/null)
}

# compare_dir <source_dir> <runtime_dir> <label>
# Checks source vs runtime and also finds runtime orphans (one-to-one mapping).
compare_dir() {
  local source_dir="$1"
  local runtime_dir="$2"
  local label="$3"

  if [[ ! -d "$source_dir" ]]; then
    return 0
  fi

  # Collect known basenames from this source (skip *.template — install.sh strips the suffix on copy)
  # Bash 3.2-compatible: newline-delimited string set
  local local_known=""
  while IFS= read -r -d '' src_file; do
    local bn
    bn="$(basename "$src_file")"
    [[ "$bn" == *.template ]] && continue
    local_known+="$bn"$'\n'
  done < <(find "$source_dir" -maxdepth 1 -type f -print0 2>/dev/null)

  while IFS= read -r -d '' src_file; do
    local rel_path
    rel_path="${src_file#"$source_dir"/}"
    # Skip *.template files — install.sh copies them with the suffix stripped; they are not drift
    [[ "$rel_path" == *.template ]] && continue
    local runtime_file="$runtime_dir/$rel_path"

    if [[ ! -e "$runtime_file" ]]; then
      echo "MISSING_IN_RUNTIME: $label/$rel_path"
      ((drift_count++)) || true
    else
      if ! diff -q "$src_file" "$runtime_file" >/dev/null 2>&1; then
        echo "CONTENT_DIFFERS: $label/$rel_path"
        ((drift_count++)) || true
      fi

      # Mode check — executable-bit only (install.sh chmod is expected and not drift)
      local src_mode runtime_mode src_exec runtime_exec
      src_mode="$(stat -c '%a' "$src_file" 2>/dev/null || stat -f '%OLp' "$src_file" 2>/dev/null || echo 'unknown')"
      runtime_mode="$(stat -c '%a' "$runtime_file" 2>/dev/null || stat -f '%OLp' "$runtime_file" 2>/dev/null || echo 'unknown')"
      src_exec=0; runtime_exec=0
      [[ "$src_mode" =~ [75] ]] && src_exec=1 || true
      [[ "$runtime_mode" =~ [75] ]] && runtime_exec=1 || true
      if [[ "$src_exec" != "$runtime_exec" ]]; then
        echo "MODE_DIFFERS: $label/$rel_path (repo: $src_mode, runtime: $runtime_mode)"
        ((drift_count++)) || true
      fi

      if [[ "$src_file" == *.md ]]; then
        check_effort_model_mismatch "$src_file"
      fi
    fi
  done < <(find "$source_dir" -maxdepth 1 -type f -print0 2>/dev/null)

  # Orphan check: runtime files not in this source
  if [[ -d "$runtime_dir" ]]; then
    while IFS= read -r -d '' rt_file; do
      local bn
      bn="$(basename "$rt_file")"
      # Bash 3.2-compatible: check if basename is in the newline-delimited set
      if ! echo "$local_known" | grep -Fxq "$bn"; then
        # Skip basenames owned by other repos
        local skip=0
        for allowed in "${RUNTIME_ONLY_ALLOW_LIST[@]}"; do
          [[ "$bn" == "$allowed" ]] && skip=1 && break
        done
        [[ "$skip" == "1" ]] && continue
        echo "MISSING_IN_REPO: $rt_file"
        ((drift_count++)) || true
      fi
    done < <(find "$runtime_dir" -maxdepth 1 -type f -print0 2>/dev/null)
  fi
}

# ── Agent comparison ────────────────────────────────────────────────────────
# agents/core and agents/personal both map to CAST_RUNTIME_AGENTS.
# We do source→runtime checks for each, then a single unified orphan check.

# Build the union of known agent basenames from both source dirs
# Bash 3.2-compatible: build newline-delimited string set
while IFS= read -r -d '' f; do
  bn="$(basename "$f")"
  if ! echo "$known_agent_basenames" | grep -Fxq "$bn"; then
    known_agent_basenames+="$bn"$'\n'
  fi
done < <(find "$REPO_ROOT/agents/core"     -maxdepth 1 -type f -print0 2>/dev/null)
while IFS= read -r -d '' f; do
  bn="$(basename "$f")"
  if ! echo "$known_agent_basenames" | grep -Fxq "$bn"; then
    known_agent_basenames+="$bn"$'\n'
  fi
done < <(find "$REPO_ROOT/agents/personal" -maxdepth 1 -type f -print0 2>/dev/null)

check_source_against_runtime "$REPO_ROOT/agents/core"     "$CAST_RUNTIME_AGENTS" "agents/core"
check_source_against_runtime "$REPO_ROOT/agents/personal" "$CAST_RUNTIME_AGENTS" "agents/personal"
check_runtime_orphans "$CAST_RUNTIME_AGENTS"

# ── Scripts comparison ──────────────────────────────────────────────────────
# scripts/ maps one-to-one with CAST_RUNTIME_SCRIPTS — use compare_dir.
compare_dir "$REPO_ROOT/scripts" "$CAST_RUNTIME_SCRIPTS" "scripts"

# ── Warnings output ─────────────────────────────────────────────────────────
if [[ ${#warnings[@]} -gt 0 ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    for w in "${warnings[@]}"; do
      echo "$w"
      ((drift_count++)) || true
    done
  else
    for w in "${warnings[@]}"; do
      echo "$w"
    done
  fi
fi

if [[ $drift_count -gt 0 ]]; then
  exit 2
fi
exit 0
