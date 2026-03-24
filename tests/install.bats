#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

# Helper: run install.sh with a given stdin
# Uses a temp file for stdin to avoid broken-pipe / SIGPIPE issues with set -euo pipefail
run_install() {
  local input_file
  input_file="$(mktemp)"
  printf '%s\n' "$1" > "$input_file"
  bash "$REPO_DIR/install.sh" < "$input_file" 2>&1
  local rc=$?
  rm -f "$input_file"
  return $rc
}

# =============================================================================
# Full install mode (choice 1)
# =============================================================================

@test "Full install: creates ~/.claude directory structure" {
  run_install "1"

  [ -d "$HOME/.claude/agents" ]
  [ -d "$HOME/.claude/commands" ]
  [ -d "$HOME/.claude/skills" ]
  [ -d "$HOME/.claude/rules" ]
  [ -d "$HOME/.claude/plans" ]
  [ -d "$HOME/.claude/briefings" ]
  [ -d "$HOME/.claude/agent-memory-local" ]
}

@test "Full install: installs all 35 agents" {
  run_install "1"

  local count
  count=$(ls -1 "$HOME/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 35 ]
}

@test "Full install: installs platform-appropriate skills" {
  run_install "1"

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: native skills installed
    [ -d "$HOME/.claude/skills/calendar-fetch" ]
    [ -d "$HOME/.claude/skills/inbox-fetch" ]
    [ -d "$HOME/.claude/skills/reminders-fetch" ]
  else
    # Linux: stubs installed instead
    [ -d "$HOME/.claude/skills/calendar-fetch-linux" ]
    [ -d "$HOME/.claude/skills/inbox-fetch-linux" ]
    [ ! -d "$HOME/.claude/skills/reminders-fetch" ]
  fi

  # Cross-platform skills always installed
  [ -d "$HOME/.claude/skills/careful-mode" ]
  [ -d "$HOME/.claude/skills/freeze-mode" ]
  [ -d "$HOME/.claude/skills/wizard" ]
}

@test "Full install: .template extension stripped from rules" {
  run_install "1"

  [ -f "$HOME/.claude/rules/stack-context.md" ]
  [ ! -f "$HOME/.claude/rules/stack-context.md.template" ]
}

@test "Full install: scripts are executable" {
  run_install "1"

  [ -x "$HOME/.claude/scripts/tidy.sh" ]
}

# =============================================================================
# Core install mode (choice 2)
# =============================================================================

@test "Core install: installs exactly 14 core agents" {
  run_install "2"

  local count
  count=$(ls -1 "$HOME/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 14 ]
}

@test "Core install: does not install extended agents" {
  run_install "2"

  [ ! -f "$HOME/.claude/agents/architect.md" ]
  [ ! -f "$HOME/.claude/agents/e2e-runner.md" ]
}

@test "Core install: does not install macOS skills" {
  run_install "2"

  [ ! -d "$HOME/.claude/skills/calendar-fetch" ]
  [ ! -d "$HOME/.claude/skills/inbox-fetch" ]
}

@test "Core install: core commands are present" {
  run_install "2"

  for cmd in plan review debug test secure commit data query eval; do
    [ -f "$HOME/.claude/commands/$cmd.md" ]
  done
}

# =============================================================================
# Custom install mode (choice 3) + backup behavior
# =============================================================================

@test "Custom install: selecting extended only installs extended + core" {
  run_install "$(printf '3\ny\nn\nn\nn\n')"

  # Core agents should be present
  [ -f "$HOME/.claude/agents/planner.md" ]

  # Extended agents should be present
  [ -f "$HOME/.claude/agents/architect.md" ]

  # Professional agents should NOT be present
  [ ! -f "$HOME/.claude/agents/browser.md" ]

  # Productivity agents should NOT be present
  [ ! -f "$HOME/.claude/agents/researcher.md" ]
}

@test "Custom install: selecting no categories skips non-core" {
  run_install "$(printf '3\nn\nn\nn\nn\n')"

  # Core agents should still be present
  [ -f "$HOME/.claude/agents/planner.md" ]
  [ -f "$HOME/.claude/agents/debugger.md" ]

  # Non-core agents should be absent
  [ ! -f "$HOME/.claude/agents/architect.md" ]
  [ ! -f "$HOME/.claude/agents/researcher.md" ]
  [ ! -f "$HOME/.claude/agents/browser.md" ]

  # 9 core + 5 orchestration always installed
  local count
  count=$(ls -1 "$HOME/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 14 ]
}

@test "Backup: existing agents dir is backed up before overwrite" {
  # First install
  run_install "1"

  # Second install — should trigger backup
  run_install "1"

  # A backup directory should exist containing an agents/ subdirectory
  local backup_base="$HOME/.claude/backups"
  [ -d "$backup_base" ]

  # Find the backup dir (there may be two if both runs created one, we need at least one with agents/)
  local found=false
  for dir in "$backup_base"/*/; do
    if [ -d "${dir}agents" ]; then
      found=true
      break
    fi
  done
  [ "$found" = true ]
}

@test "Rules: existing rule file is not overwritten" {
  # First install
  run_install "1"

  # Modify a rule file
  echo "CUSTOM_MARKER" >> "$HOME/.claude/rules/working-conventions.md"

  # Second install
  run_install "1"

  # The custom marker should still be there (file was not overwritten)
  grep -q "CUSTOM_MARKER" "$HOME/.claude/rules/working-conventions.md"
}

@test "Full install: specialist tier directory has exactly 4 agents" {
  run_install "1"

  local count
  count=$(ls -1 "$HOME/.claude/agents/devops.md" "$HOME/.claude/agents/performance.md" \
              "$HOME/.claude/agents/seo-content.md" "$HOME/.claude/agents/linter.md" \
              2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 4 ]
}

@test "Full install: installs agent-groups.json config" {
  run_install "1"

  [ -f "$HOME/.claude/config/agent-groups.json" ]
}

@test "Custom install: selecting specialist installs specialist agents" {
  run_install "$(printf '3\nn\nn\nn\ny\nn\n')"

  [ -f "$HOME/.claude/agents/devops.md" ]
  [ -f "$HOME/.claude/agents/performance.md" ]
  [ -f "$HOME/.claude/agents/seo-content.md" ]
  [ -f "$HOME/.claude/agents/linter.md" ]
}
