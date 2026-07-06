#!/usr/bin/env bats
# Tests for the cast doctor "orphaned agent sessions" check.
# Encodes the honest-degradation contract:
#   - dangling tool_result + old mtime    -> WARN (flagged)
#   - clean assistant-final + old mtime   -> OK (not flagged)
#   - fresh dangling within threshold     -> OK (not flagged)
#   - missing projects dir                -> INFO (not absent == green)
#
# Mtimes are backdated via python3 os.utime — Ubuntu-safe; no BSD date -v.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Backdate a file's mtime by N minutes using python3 os.utime (Ubuntu-safe).
_backdate_min() {
  local file="$1"
  local minutes="$2"
  python3 - "$file" "$minutes" <<'PYEOF'
import os, sys, time
path = sys.argv[1]
minutes = int(sys.argv[2])
target = time.time() - (minutes * 60)
os.utime(path, (target, target))
PYEOF
}

# Write a minimal cast.db with just enough tables so doctor passes the early
# schema checks without erroring out before reaching the orphaned-sessions check.
_create_minimal_db() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, project TEXT, project_root TEXT, started_at TEXT, ended_at TEXT, status TEXT, deleted_at TEXT);
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent TEXT, agent_name TEXT, started_at TEXT, ended_at TEXT, status TEXT, abandoned_at TEXT, cost_usd REAL, duration_ms INTEGER, tool_uses INTEGER, outcome TEXT);
CREATE TABLE IF NOT EXISTS routing_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, matched_route TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, confidence REAL, last_validated_at TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS tool_call_failures (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, tool_name TEXT, error TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_truncations (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, truncated_at TEXT, severity TEXT, snippet TEXT);
CREATE TABLE IF NOT EXISTS injection_log (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, injected_at TEXT, source TEXT, content_preview TEXT);
CREATE TABLE IF NOT EXISTS quality_gates (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, gate_name TEXT, result TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS dispatch_decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, reason TEXT, prompt_snippet TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS task_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, task_name TEXT, agent TEXT, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS routines (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, agent TEXT, schedule TEXT, status TEXT, last_run TEXT);
CREATE TABLE IF NOT EXISTS incidents (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, severity TEXT, description TEXT, problem_summary TEXT, fix_summary TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS plan_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, plan_file TEXT, status TEXT, started_at TEXT, ended_at TEXT);
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ran_at TEXT, merged_count INTEGER, pruned_count INTEGER);
CREATE TABLE IF NOT EXISTS archived_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, archived_at TEXT);
CREATE TABLE IF NOT EXISTS budgets (id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT, budget_usd REAL, spent_usd REAL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);
SQL
}

# Write a JSONL transcript whose last entry is a user message delivering a
# tool_result — the canonical "died mid-tool-loop" signature.
_write_dangling_transcript() {
  local fpath="$1"
  # assistant turn that issued a tool call
  printf '%s\n' \
    '{"role":"assistant","content":[{"type":"tool_use","id":"tu_001","name":"bash","input":{"command":"ls"}}]}' \
    '{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_001","content":"file1.txt\nfile2.txt"}]}' \
    > "$fpath"
}

# Write a JSONL transcript that ends cleanly with an assistant text turn.
_write_clean_transcript() {
  local fpath="$1"
  printf '%s\n' \
    '{"role":"user","content":[{"type":"text","text":"hello"}]}' \
    '{"role":"assistant","content":[{"type":"text","text":"Status: DONE"}]}' \
    > "$fpath"
}

# ── Fixture setup / teardown ─────────────────────────────────────────────────

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CLAUDE_SUBPROCESS=0
  # Use a minimal fake agents dir so doctor's agent-frontmatter check is quiet
  export CAST_AGENTS_DIR="$HOME/.claude/agents"
  mkdir -p "$CAST_AGENTS_DIR"
  # Fake repo dir so routines check degrades gracefully
  export CAST_REPO_DIR="$HOME/fake-repo"
  mkdir -p "$CAST_REPO_DIR"
  # Events dir to silence that check
  mkdir -p "$HOME/.claude/cast/events"
}

teardown() {
  teardown_temp_home
}

# ── Shared helper: run cast doctor and capture stdout+stderr ──────────────────
_run_doctor() {
  run bash "$CAST_BIN" doctor 2>&1
}

# ── Test 1: dangling tool_result + old mtime -> WARN ─────────────────────────
@test "orphaned sessions: dangling tool_result with old mtime is flagged as WARN" {
  _create_minimal_db "$CAST_DB_PATH"

  local proj_dir="$HOME/.claude/projects/proj-abc"
  mkdir -p "$proj_dir"
  local transcript="$proj_dir/session-dangling.jsonl"
  _write_dangling_transcript "$transcript"
  # Backdate to 120 min ago (well past the default 60 min threshold)
  _backdate_min "$transcript" 120

  # Use a low threshold to keep test fast; CAST_ORPHAN_SESSION_MIN=60 is default
  run env CAST_ORPHAN_SESSION_MIN=60 bash "$CAST_BIN" doctor 2>&1
  assert_output --partial "orphaned sessions:"
  assert_output --partial "1 transcript(s) died mid-tool-loop"
  assert_output --partial "session-dangling.jsonl"
}

# ── Test 2: clean assistant-final + old mtime -> NOT flagged ─────────────────
@test "orphaned sessions: clean assistant-final transcript with old mtime is not flagged" {
  _create_minimal_db "$CAST_DB_PATH"

  local proj_dir="$HOME/.claude/projects/proj-clean"
  mkdir -p "$proj_dir"
  local transcript="$proj_dir/session-clean.jsonl"
  _write_clean_transcript "$transcript"
  # Backdate to 120 min ago
  _backdate_min "$transcript" 120

  run env CAST_ORPHAN_SESSION_MIN=60 bash "$CAST_BIN" doctor 2>&1
  # Should NOT flag this transcript
  refute_output --partial "1 transcript(s) died mid-tool-loop"
  # Should show the OK/none-detected line
  assert_output --partial "orphaned sessions: none detected"
}

# ── Test 3: fresh dangling transcript (within threshold) -> NOT flagged ───────
@test "orphaned sessions: dangling transcript newer than threshold is not flagged" {
  _create_minimal_db "$CAST_DB_PATH"

  local proj_dir="$HOME/.claude/projects/proj-fresh"
  mkdir -p "$proj_dir"
  local transcript="$proj_dir/session-fresh.jsonl"
  _write_dangling_transcript "$transcript"
  # Only 5 min old — well within the 60 min default threshold; no backdate needed
  # (file is just-created so mtime is already "now")

  run env CAST_ORPHAN_SESSION_MIN=60 bash "$CAST_BIN" doctor 2>&1
  refute_output --partial "1 transcript(s) died mid-tool-loop"
  assert_output --partial "orphaned sessions: none detected"
}

# ── Test 3b: threshold 0 = flag everything stale (no freshness floor) ─────────
@test "orphaned sessions: threshold 0 flags a fresh dangling transcript (no freshness floor)" {
  _create_minimal_db "$CAST_DB_PATH"

  local proj_dir="$HOME/.claude/projects/proj-zero"
  mkdir -p "$proj_dir"
  local transcript="$proj_dir/session-zero.jsonl"
  _write_dangling_transcript "$transcript"
  # Fresh file (mtime ~now, no backdate). Threshold 0 means "flag every dangling
  # transcript regardless of age" — the honest sentinel semantics, not a degenerate.

  run env CAST_ORPHAN_SESSION_MIN=0 bash "$CAST_BIN" doctor 2>&1
  assert_output --partial "1 transcript(s) died mid-tool-loop"
  assert_output --partial "session-zero.jsonl"
}

# ── Test 4: missing projects dir -> INFO, never green ────────────────────────
@test "orphaned sessions: missing projects dir reports INFO, not OK/green" {
  _create_minimal_db "$CAST_DB_PATH"
  # Deliberately do NOT create ~/.claude/projects/

  _run_doctor
  # Must emit an INFO-style line about the absent dir
  assert_output --partial "orphaned sessions: projects dir absent"
  # Must NOT show a misleading green "none detected" line
  refute_output --partial "orphaned sessions: none detected"
}
