#!/usr/bin/env bash
# cast-compat.sh — CAST compatibility check runner
# Provides cast_compat_check, version save, and version diff operations.
#
# Usage (direct):
#   bash scripts/cast-compat.sh test
#   bash scripts/cast-compat.sh save
#   bash scripts/cast-compat.sh diff
#
# Usage (via cast CLI):
#   cast compat test
#   cast compat save
#   cast compat diff

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAST_STATE_DIR="${HOME}/.claude/cast"
LKG_FILE="${CAST_STATE_DIR}/last-known-good-version"
COMPAT_BATS="${REPO_ROOT}/tests/compat.bats"

# ── Colors ─────────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  C_GREEN='\033[0;32m'
  C_RED='\033[0;31m'
  C_YELLOW='\033[0;33m'
  C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_GREEN='' C_RED='' C_YELLOW='' C_BOLD='' C_RESET=''
fi

# ── Ensure state dir exists ────────────────────────────────────────────────────
_ensure_state_dir() {
  mkdir -p "$CAST_STATE_DIR"
}

# ── cast_compat_check — main entry point ───────────────────────────────────────
# Runs the BATS contract suite and compares version to last-known-good.
# Returns 0 on all tests passing, 1 on any failure or version mismatch.
cast_compat_check() {
  local subcmd="${1:-test}"
  case "$subcmd" in
    test)  _compat_test ;;
    save)  _compat_save ;;
    diff)  _compat_diff ;;
    *)
      printf "Usage: cast compat test|save|diff\n" >&2
      return 1
      ;;
  esac
}

# ── Run BATS contract suite ────────────────────────────────────────────────────
_compat_test() {
  if ! command -v bats >/dev/null 2>&1; then
    printf "${C_RED}Error: bats not found in PATH.${C_RESET}\n" >&2
    printf "  Install: brew install bats-core  (or: npm i -g bats)\n" >&2
    return 1
  fi

  if [ ! -f "$COMPAT_BATS" ]; then
    printf "${C_RED}Error: compat.bats not found at %s${C_RESET}\n" "$COMPAT_BATS" >&2
    return 1
  fi

  printf "${C_BOLD}CAST Compatibility Contract Tests${C_RESET}\n"
  printf "Suite: %s\n\n" "$COMPAT_BATS"

  # Run with repo root as working directory so relative script paths resolve
  (cd "$REPO_ROOT" && bats "$COMPAT_BATS")
  local exit_code=$?

  echo ""
  if [ "$exit_code" -eq 0 ]; then
    printf "${C_GREEN}All contract tests passed.${C_RESET}\n"
  else
    printf "${C_RED}One or more contract tests failed. See output above.${C_RESET}\n"
    printf "  Run 'cast compat save' after verifying the new Claude version is compatible.\n"
  fi

  return "$exit_code"
}

# ── Save current claude version as last-known-good ────────────────────────────
_compat_save() {
  _ensure_state_dir

  local current_version
  current_version="$(claude --version 2>/dev/null | head -1 || echo "")"

  if [ -z "$current_version" ]; then
    printf "${C_RED}Error: could not determine claude version (is claude installed?).${C_RESET}\n" >&2
    return 1
  fi

  printf "%s" "$current_version" > "$LKG_FILE"
  printf "${C_GREEN}Saved last-known-good version: %s${C_RESET}\n" "$current_version"
  printf "  File: %s\n" "$LKG_FILE"
}

# ── Compare installed version to last-known-good ───────────────────────────────
_compat_diff() {
  if [ ! -f "$LKG_FILE" ]; then
    printf "${C_YELLOW}No last-known-good version recorded.${C_RESET}\n"
    printf "  Run: cast compat save\n"
    return 0
  fi

  local lkg
  lkg="$(cat "$LKG_FILE")"
  local current
  current="$(claude --version 2>/dev/null | head -1 || echo "")"

  if [ -z "$current" ]; then
    printf "${C_RED}Error: could not determine installed claude version.${C_RESET}\n" >&2
    return 1
  fi

  if [ "$lkg" = "$current" ]; then
    printf "${C_GREEN}no change${C_RESET}  (version: %s)\n" "$current"
    return 0
  else
    printf "${C_YELLOW}Version changed:${C_RESET}\n"
    printf "  Last-known-good:  %s\n" "$lkg"
    printf "  Installed:        %s\n" "$current"
    printf "\n"
    printf "  Run 'cast compat test' to verify contract compliance.\n"
    printf "  Run 'cast compat save' to accept this version as new baseline.\n"
    return 1
  fi
}

# ── Direct invocation ──────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cast_compat_check "${1:-test}"
fi
