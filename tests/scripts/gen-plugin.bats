#!/usr/bin/env bats
# Tests for scripts/gen-plugin.sh
# Generates CAST plugin build artifact (agents, skills, commands, hooks, scripts).
# All tests use isolated temp output dirs via $BATS_TEST_TMPDIR.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  # No temp HOME needed — gen-plugin.sh only writes to its output dir.
  # Temp output dir is created per-test in $BATS_TEST_TMPDIR.
  :
}

teardown() {
  # Cleanup is automatic via $BATS_TEST_TMPDIR removal.
  :
}

@test "gen-plugin.sh exits 0 and generates to output dir" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  run bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT"
  assert_success
  [ -d "$OUT" ]
}

@test "gen-plugin.sh creates exactly 17 agent files (LEAN_AGENTS)" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  agent_count=$(find "$OUT/agents" -maxdepth 1 -type f | wc -l | tr -d ' ')
  [ "$agent_count" -eq 17 ]
}

@test "gen-plugin.sh excludes push.md and morning-briefing.md from agents/" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  [ ! -f "$OUT/agents/push.md" ]
  [ ! -f "$OUT/agents/morning-briefing.md" ]
}

@test "gen-plugin.sh excludes push.md and morning.md from commands/" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  [ ! -f "$OUT/commands/push.md" ]
  [ ! -f "$OUT/commands/morning.md" ]
}

@test "gen-plugin.sh strips forbidden frontmatter (hooks|mcpServers|permissionMode)" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  # Assert that NO agent file contains these keys at the top level
  result=$(grep -rE '^(hooks|mcpServers|permissionMode):' "$OUT/agents" 2>/dev/null || true)
  [ -z "$result" ]
}

@test "gen-plugin.sh generates valid plugin.json manifest" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  # Verify plugin.json exists and is valid JSON with name='cast'
  [ -f "$OUT/.claude-plugin/plugin.json" ]
  python3 -c "
import json
d=json.load(open('$OUT/.claude-plugin/plugin.json'))
assert d['name']=='cast', 'plugin name is not cast'
" || return 1
}

@test "gen-plugin.sh generates hooks.json with no literal ~/.claude/scripts paths" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  [ -f "$OUT/hooks/hooks.json" ]
  # shellcheck disable=SC2088
  ! grep '~/.claude/scripts' "$OUT/hooks/hooks.json" >/dev/null 2>&1
}

@test "gen-plugin.sh excludes SKILL-personal.md from skills/" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  # Assert no SKILL-personal.md exists under skills/
  result=$(find "$OUT/skills" -name "SKILL-personal.md" 2>/dev/null || true)
  [ -z "$result" ]
}

@test "gen-plugin.sh creates 17 skill directories with SKILL.md each" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  skill_count=$(find "$OUT/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$skill_count" -eq 17 ]

  # Assert every skill has SKILL.md
  result=$(find "$OUT/skills" -mindepth 1 -maxdepth 1 -type d ! -exec test -f "{}/SKILL.md" \; -print | wc -l | tr -d ' ')
  [ "$result" -eq 0 ]
}

@test "gen-plugin.sh with --with-extras includes 4 extra agents (21 total)" {
  OUT="$BATS_TEST_TMPDIR/plugin-extras"
  bash "$REPO_DIR/scripts/gen-plugin.sh" --with-extras "$OUT" >/dev/null 2>&1

  agent_count=$(find "$OUT/agents" -maxdepth 1 -type f | wc -l | tr -d ' ')
  [ "$agent_count" -eq 21 ]
}

@test "gen-plugin.sh with --with-extras includes perf-sentinel, release-notes, api-contract, dep-auditor" {
  OUT="$BATS_TEST_TMPDIR/plugin-extras"
  bash "$REPO_DIR/scripts/gen-plugin.sh" --with-extras "$OUT" >/dev/null 2>&1

  [ -f "$OUT/agents/perf-sentinel.md" ]
  [ -f "$OUT/agents/release-notes.md" ]
  [ -f "$OUT/agents/api-contract.md" ]
  [ -f "$OUT/agents/dep-auditor.md" ]
}

@test "gen-plugin.sh without --with-extras excludes extra agents" {
  OUT="$BATS_TEST_TMPDIR/plugin"
  bash "$REPO_DIR/scripts/gen-plugin.sh" "$OUT" >/dev/null 2>&1

  [ ! -f "$OUT/agents/perf-sentinel.md" ]
  [ ! -f "$OUT/agents/release-notes.md" ]
  [ ! -f "$OUT/agents/api-contract.md" ]
  [ ! -f "$OUT/agents/dep-auditor.md" ]
}
