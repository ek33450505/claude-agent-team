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
        "matcher": "mcp__.*|WebFetch|WebSearch|Bash|Read|Write|Edit",
        "hooks": [
          {"type": "command", "command": "python3 ~/.claude/scripts/cast-pretool-dispatch.py"}
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
  load 'helpers/setup'
  setup_temp_home
  # Prepend stub-bin to PATH to prevent real network/keychain calls in ALL tests.
  # Default stubs: security exits 1 (no key found), curl exits 7 (unreachable).
  # Individual tests that need specific curl behaviour rewrite the stub before calling run_validate.
  mkdir -p "$HOME/.stub-bin"
  printf '#!/bin/bash\nexit 1\n' > "$HOME/.stub-bin/security"
  printf '#!/bin/bash\nexit 7\n' > "$HOME/.stub-bin/curl"
  chmod +x "$HOME/.stub-bin/security" "$HOME/.stub-bin/curl"
  export PATH="$HOME/.stub-bin:$PATH"
}

teardown() {
  teardown_temp_home
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

@test "FTS5 check: references record_fts, not the stale agent_memories_fts name" {
  build_clean_install
  run_validate
  refute_output --partial "agent_memories_fts"
}

@test "FTS5 check: cast.db present without record_fts reports not-found hint" {
  build_clean_install
  python3 -c "
import sqlite3
conn = sqlite3.connect('$HOME/.claude/cast.db')
conn.execute('CREATE TABLE placeholder (id INTEGER)')
conn.commit()
conn.close()
"
  run_validate
  assert_output --partial "record_fts table not found (run: cast-db-init.sh then cast-ask-index.py --rebuild)"
}

@test "FTS5 check: record_fts present in cast.db passes" {
  build_clean_install
  python3 -c "
import sqlite3
conn = sqlite3.connect('$HOME/.claude/cast.db')
conn.execute('CREATE VIRTUAL TABLE record_fts USING fts5(kind, ref_id, ts, title, body, agent, project, mtype)')
conn.commit()
conn.close()
"
  run_validate
  assert_output --partial "FTS5: record_fts table present in cast.db"
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

@test "hook wiring: missing cast-pretool-dispatch.py wiring → exits 2" {
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
  assert_output --partial "cast-pretool-dispatch.py"
}

# ---------------------------------------------------------------------------
# 7. Help flag tests
# ---------------------------------------------------------------------------

@test "cast-validate.sh --help exits 0" {
  run bash "$VALIDATE_SH" --help
  [ "$status" -eq 0 ]
}

@test "cast-validate.sh --help output contains Usage:" {
  run bash "$VALIDATE_SH" --help
  assert_output --partial "Usage:"
}

@test "cast-validate.sh -h exits 0" {
  run bash "$VALIDATE_SH" -h
  [ "$status" -eq 0 ]
}

@test "cast-validate.sh -h output contains Usage:" {
  run bash "$VALIDATE_SH" -h
  assert_output --partial "Usage:"
}

# ---------------------------------------------------------------------------
# 8. Check 12: managed-settings.d fragment command validation
# ---------------------------------------------------------------------------

@test "fragment commands: all commands resolve → pass" {
  build_clean_install
  mkdir -p "$HOME/.claude/managed-settings.d"
  # Create a fragment whose command references a script that EXISTS
  touch "$HOME/.claude/scripts/cast-real-hook.sh"
  cat > "$HOME/.claude/managed-settings.d/20-hooks-test.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "bash ~/.claude/scripts/cast-real-hook.sh"}
        ]
      }
    ]
  }
}
JSON
  run_validate
  assert_output --partial "all managed-settings.d hook commands resolve"
}

@test "fragment commands: missing script → error flagged" {
  build_clean_install
  mkdir -p "$HOME/.claude/managed-settings.d"
  # Fragment references a script that does NOT exist
  cat > "$HOME/.claude/managed-settings.d/25-hooks-bad.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "bash ~/.claude/scripts/cast-deleted-script.sh"}
        ]
      }
    ]
  }
}
JSON
  run_validate
  [ "$status" -eq 2 ]
  assert_output --partial "cast-deleted-script.sh"
}

@test "fragment commands: no fragments dir → info only, no error" {
  build_clean_install
  # Ensure managed-settings.d does NOT exist
  rm -rf "$HOME/.claude/managed-settings.d"
  run_validate
  # Missing dir is informational only — must not add errors
  assert_output --partial "not found"
  # Status should be 0 (clean install, dir just not present)
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Backup: retarget to Library/Application Support/cast/db-backups
# ---------------------------------------------------------------------------

@test "backup: uses new default ~/Library/Application Support/cast/db-backups when dir absent" {
  build_clean_install
  # New default dir does not exist in temp HOME — should print info advisory
  run env -u CAST_BACKUP_DIR bash "$VALIDATE_SH"
  # INFO about dir not found at the new default path (not the old ~/.claude/backups path)
  assert_output --partial "Library/Application Support/cast/db-backups"
}

@test "backup: CAST_BACKUP_DIR env override is respected" {
  build_clean_install
  CUSTOM_DIR="$HOME/custom-backup-dir"
  mkdir -p "$CUSTOM_DIR"
  # Populate with a fake backup so the freshness check finds it
  touch "$CUSTOM_DIR/cast-db-2026-01-01.db"

  run env CAST_BACKUP_DIR="$CUSTOM_DIR" bash "$VALIDATE_SH"
  assert_output --partial "cast-db-2026-01-01.db"
}

@test "backup: legacy ~/.claude/backups advisory when old dir is present and non-empty" {
  build_clean_install
  # Simulate legacy colocated backups surviving from before wipe-#2 retarget
  mkdir -p "$HOME/.claude/backups"
  touch "$HOME/.claude/backups/cast-db-2025-12-01.db"

  run env -u CAST_BACKUP_DIR bash "$VALIDATE_SH"
  assert_output --partial "legacy colocated backups"
  assert_output --partial "migrate"
}

@test "backup: no legacy advisory when ~/.claude/backups is absent" {
  build_clean_install
  # Ensure old dir does NOT exist
  rm -rf "$HOME/.claude/backups"

  run env -u CAST_BACKUP_DIR bash "$VALIDATE_SH"
  refute_output --partial "legacy colocated backups"
}

# ---------------------------------------------------------------------------
# Model tier availability check (new — C9)
# All tests rely on setup()'s default stubs: security exits 1, curl exits 7.
# Tests that need curl to return a fixture rewrite the stub first.
# ---------------------------------------------------------------------------

@test "model availability: no API key → info skip, exits 0" {
  build_clean_install
  # Default security stub exits 1 (no keychain key).
  # Explicitly unset ANTHROPIC_API_KEY so key resolution finds nothing.
  run env -u ANTHROPIC_API_KEY bash "$VALIDATE_SH"
  assert_output --partial "Model availability: skipped (no ANTHROPIC_API_KEY"
  assert_success
}

@test "model availability: all tiers present → three pass lines, exits 0" {
  build_clean_install
  # Write fixture JSON to a file; curl stub cats it so the check gets valid data.
  FIXTURE_FILE="$HOME/.stub-bin/_models.json"
  printf '%s' '{"data":[{"type":"model","id":"claude-opus-4-8"},{"type":"model","id":"claude-sonnet-4-6"},{"type":"model","id":"claude-haiku-4-5"}],"has_more":false}' > "$FIXTURE_FILE"
  printf '#!/bin/bash\ncat "%s"\n' "$FIXTURE_FILE" > "$HOME/.stub-bin/curl"
  chmod +x "$HOME/.stub-bin/curl"
  run env ANTHROPIC_API_KEY=test CAST_MODELS_ENDPOINT=https://api.anthropic.com/v1/models bash "$VALIDATE_SH"
  assert_output --partial "Model tier 'opus': available"
  assert_output --partial "Model tier 'sonnet': available"
  assert_output --partial "Model tier 'haiku': available"
  assert_success
}

@test "model availability: haiku tier absent → warn about retired tier, exits 1" {
  build_clean_install
  # Fixture has opus and sonnet but no haiku → haiku tier gets a warn.
  FIXTURE_FILE="$HOME/.stub-bin/_models.json"
  printf '%s' '{"data":[{"type":"model","id":"claude-opus-4-8"},{"type":"model","id":"claude-sonnet-4-6"}],"has_more":false}' > "$FIXTURE_FILE"
  printf '#!/bin/bash\ncat "%s"\n' "$FIXTURE_FILE" > "$HOME/.stub-bin/curl"
  chmod +x "$HOME/.stub-bin/curl"
  run env ANTHROPIC_API_KEY=test CAST_MODELS_ENDPOINT=https://api.anthropic.com/v1/models bash "$VALIDATE_SH"
  assert_output --partial "Model tier 'haiku': no claude-haiku-* model"
  # Warnings only → exit 1; errors would be exit 2.
  [ "$status" -eq 1 ]
}

@test "model availability: endpoint unreachable → info skip, exits 0" {
  build_clean_install
  # Default curl stub exits 7 — simulates a network failure.
  # ANTHROPIC_API_KEY is set so the check attempts the call, then gracefully skips.
  run env ANTHROPIC_API_KEY=test CAST_MODELS_ENDPOINT=https://api.anthropic.com/v1/models bash "$VALIDATE_SH"
  assert_output --partial "Model availability: skipped (could not reach"
  assert_success
}
