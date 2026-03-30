#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE_SH="$REPO_DIR/scripts/cast-validate.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal passing fake ~/.claude under the temp HOME
build_clean_install() {
  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/agents"
  mkdir -p "$HOME/.claude/agent-status"
  mkdir -p "$HOME/.claude/scripts"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/cast/state"
  mkdir -p "$HOME/.claude/cast/reviews"
  mkdir -p "$HOME/.claude/cast/artifacts"
  # Stub cast-events.sh (existence check only)
  touch "$HOME/.claude/scripts/cast-events.sh"

  # --- settings.local.json: wires all three required scripts ---
  cat > "$HOME/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "bash ~/.claude/scripts/route.sh"}
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "bash ~/.claude/scripts/pre-tool-guard.sh"}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"type": "command", "command": "bash ~/.claude/scripts/post-tool-hook.sh"}
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "bash ~/.claude/scripts/cast-session-end.sh"}
        ]
      }
    ]
  }
}
JSON

  # --- One minimal valid agent ---
  cat > "$HOME/.claude/agents/planner.md" <<'MD'
---
name: planner
description: Planning agent
tools: Read,Write
model: claude-haiku-4-5
---
Plan things.
MD

  # --- Routing table with valid schema ---
  # Second route includes security in post_chain so Check 11 passes cleanly
  cat > "$HOME/.claude/config/routing-table.json" <<'JSON'
{
  "routes": [
    {
      "patterns": ["^/plan\\b"],
      "agent": "planner",
      "model": "claude-haiku-4-5",
      "confidence": "hard"
    },
    {
      "patterns": ["^/secure\\b"],
      "agent": "security",
      "model": "claude-sonnet-4-5",
      "confidence": "hard",
      "post_chain": ["security"]
    }
  ]
}
JSON

  # --- agent-groups.json: minimal valid config ---
  cat > "$HOME/.claude/config/agent-groups.json" <<'JSON'
{
  "version": "1.0",
  "groups": [
    {
      "id": "test-group",
      "description": "Test group",
      "patterns": ["test pattern"],
      "confidence": "hard",
      "waves": [
        { "id": 1, "description": "Test", "parallel": true, "agents": ["planner"] }
      ]
    }
  ]
}
JSON

  # --- CLAUDE.md with all required directives ---
  cat > "$HOME/.claude/CLAUDE.md" <<'MD'
# CAST

[CAST-DISPATCH] — dispatch agents
[CAST-REVIEW]   — dispatch code-reviewer
[CAST-CHAIN]    — run chains
[CAST-DISPATCH-GROUP] — dispatch agent groups
MD
}

run_validate() {
  run bash "$VALIDATE_SH"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Clean install — all checks pass
# ---------------------------------------------------------------------------

@test "clean install: exits 0 when everything is correct" {
  build_clean_install
  run_validate
  assert_success
}

@test "clean install: output contains 0 errors" {
  build_clean_install
  run_validate
  assert_output --partial "0 errors"
}

@test "clean install: output contains no warnings line" {
  build_clean_install
  run_validate
  assert_output --partial "0 warnings"
}

# ---------------------------------------------------------------------------
# 2. Missing CLAUDE.md
# ---------------------------------------------------------------------------

@test "missing CLAUDE.md: exits 2" {
  build_clean_install
  rm "$HOME/.claude/CLAUDE.md"
  run_validate
  [ "$status" -eq 2 ]
}

@test "missing CLAUDE.md: output contains error about directives" {
  build_clean_install
  rm "$HOME/.claude/CLAUDE.md"
  run_validate
  assert_output --partial "CLAUDE.md"
}

@test "CLAUDE.md missing directives: exits 2 and reports missing directive names" {
  build_clean_install
  # Write a CLAUDE.md that is missing [CAST-REVIEW] and [CAST-CHAIN]
  cat > "$HOME/.claude/CLAUDE.md" <<'MD'
# CAST
[CAST-DISPATCH] — dispatch agents
MD
  run_validate
  [ "$status" -eq 2 ]
  assert_output --partial "CAST-REVIEW"
}

# ---------------------------------------------------------------------------
# 3. Missing agent-status dir — check 5 fails (error), not a warning
# ---------------------------------------------------------------------------

@test "missing agent-status dir: exits 2" {
  build_clean_install
  rm -rf "$HOME/.claude/agent-status"
  run_validate
  [ "$status" -eq 2 ]
}

@test "missing agent-status dir: output mentions agent-status" {
  build_clean_install
  rm -rf "$HOME/.claude/agent-status"
  run_validate
  assert_output --partial "agent-status"
}

# ---------------------------------------------------------------------------
# 5. Partial installs — script completes without crashing
# ---------------------------------------------------------------------------

@test "partial install: missing settings.local.json — script completes" {
  build_clean_install
  rm "$HOME/.claude/settings.local.json"
  run_validate
  # Must not crash (any exit code is acceptable, but must finish)
  [ "$status" -le 2 ]
}

@test "partial install: missing agents dir — script completes" {
  build_clean_install
  rm -rf "$HOME/.claude/agents"
  run_validate
  [ "$status" -le 2 ]
}

@test "partial install: completely empty HOME/.claude — script completes" {
  mkdir -p "$HOME/.claude"
  run_validate
  [ "$status" -le 2 ]
}

# ---------------------------------------------------------------------------
# 6. Hook wiring checks
# ---------------------------------------------------------------------------

@test "hook wiring: missing pre-tool-guard.sh wiring → exits 2" {
  build_clean_install
  python3 - "$HOME/.claude/settings.local.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
d["hooks"].pop("PreToolUse", None)
with open(path, "w") as f:
    json.dump(d, f)
PYEOF
  run_validate
  [ "$status" -eq 2 ]
  assert_output --partial "pre-tool-guard.sh"
}
