#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
AGENT_COLOR_SH="$REPO_DIR/scripts/cast-agent-color.sh"

# Default (no-color) ANSI code returned for unknown agents
DEFAULT_CODE='\033[0m'

# Helper: source the script and call get_agent_color, then hex-dump the result
agent_color_hex() {
  local agent_name="$1"
  source "$AGENT_COLOR_SH"
  get_agent_color "$agent_name" | xxd -p
}

# ---------------------------------------------------------------------------
# Test 1: Known agent returns a non-empty, non-default color code
# ---------------------------------------------------------------------------

@test "known agent 'commit' returns a non-default color code" {
  source "$AGENT_COLOR_SH"
  local result
  result="$(get_agent_color commit | xxd -p)"
  # Default is ESC[0m = 1b 5b 30 6d
  [ "$result" != "1b5b306d" ]
  [ -n "$result" ]
}

# ---------------------------------------------------------------------------
# Test 2: Unknown agent returns the default reset color code
# ---------------------------------------------------------------------------

@test "unknown agent returns the default reset color code" {
  source "$AGENT_COLOR_SH"
  local result
  result="$(get_agent_color totally-unknown-agent-xyz | xxd -p)"
  # Default is ESC[0m = 1b5b306d
  [ "$result" = "1b5b306d" ]
}

# ---------------------------------------------------------------------------
# Test 3: All core agents in agents/core/*.md have a non-default color entry
# ---------------------------------------------------------------------------

@test "all core agents have a non-default color entry in cast-agent-color.sh" {
  source "$AGENT_COLOR_SH"
  local failed=0
  local agent_name

  for agent_file in "$REPO_DIR/agents/core/"*.md; do
    # Derive agent name from filename (strip path and .md extension)
    agent_name="$(basename "$agent_file" .md)"
    local result
    result="$(get_agent_color "$agent_name" | xxd -p)"
    # Default reset code is 1b5b306d (ESC[0m)
    if [ "$result" = "1b5b306d" ]; then
      echo "MISSING color entry for core agent: $agent_name" >&2
      failed=1
    fi
  done

  [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 4: portfolio-sync (personal agent) now has a non-default color entry
# ---------------------------------------------------------------------------

@test "portfolio-sync returns a non-default color code" {
  source "$AGENT_COLOR_SH"
  local result
  result="$(get_agent_color portfolio-sync | xxd -p)"
  # Must not be default ESC[0m
  [ "$result" != "1b5b306d" ]
  [ -n "$result" ]
}

# ---------------------------------------------------------------------------
# Test 5: No-argument call uses 'main' as default and returns non-default color
# ---------------------------------------------------------------------------

@test "calling get_agent_color with no args uses 'main' and returns non-default color" {
  source "$AGENT_COLOR_SH"
  local result
  result="$(get_agent_color | xxd -p)"
  # 'main' has its own entry (38;5;255), not the default reset
  [ "$result" != "1b5b306d" ]
  [ -n "$result" ]
}
