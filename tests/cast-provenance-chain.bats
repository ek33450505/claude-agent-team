#!/usr/bin/env bats
# Tests for cast provenance chain — tamper-evident hash-chain of A5 digests (A7)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"
PROV="$REPO_DIR/scripts/cast-provenance-chain.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CAST_REPO_DIR="$REPO_DIR"

  # Build real schema via cast-db-init.sh (source of truth)
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed 3 sessions (oldest→newest by started_at) — enough for a real digest
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO sessions (id, project, project_root, started_at, ended_at, status) VALUES
  ('sess-1','cast','/x','2026-06-28T10:00:00','2026-06-28T10:30:00','completed'),
  ('sess-2','cast','/x','2026-06-28T11:00:00','2026-06-28T11:30:00','completed'),
  ('sess-3','cast','/x','2026-06-28T12:00:00','2026-06-28T12:30:00','completed');
INSERT INTO agent_runs (session_id, agent, model, started_at, ended_at, status, input_tokens, output_tokens, cost_usd, cache_read_input_tokens, cache_creation_input_tokens, duration_ms, tool_uses) VALUES
  ('sess-1','code-writer','claude-sonnet-4-6','2026-06-28T10:01:00','2026-06-28T10:10:00','completed',1000,500,0.0025,200,50,540000,12),
  ('sess-2','code-writer','claude-sonnet-4-6','2026-06-28T11:01:00','2026-06-28T11:10:00','completed',800,400,0.0020,100,40,480000,9),
  ('sess-3','code-writer','claude-sonnet-4-6','2026-06-28T12:01:00','2026-06-28T12:10:00','completed',600,300,0.0015,80,30,360000,6);
SQL
}

teardown() {
  teardown_temp_home
}

# ── Test 1: append writes one row ─────────────────────────────────────────────

@test "append writes one row" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM provenance_chain;"
  assert_output "1"
}

# ── Test 2: append is idempotent ─────────────────────────────────────────────

@test "append is idempotent (2x = 1 row)" {
  python3 "$PROV" append sess-1 --db "$CAST_DB_PATH" >/dev/null 2>&1
  python3 "$PROV" append sess-1 --db "$CAST_DB_PATH" >/dev/null 2>&1
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM provenance_chain;"
  assert_output "1"
}

# ── Test 3: backfill chains all sessions ──────────────────────────────────────

@test "backfill chains all sessions in order" {
  run python3 "$PROV" backfill --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "3 appended"
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM provenance_chain;"
  assert_output "3"
  run sqlite3 "$CAST_DB_PATH" "SELECT session_id FROM provenance_chain ORDER BY seq LIMIT 1;"
  assert_output "sess-1"
  run sqlite3 "$CAST_DB_PATH" "SELECT session_id FROM provenance_chain ORDER BY seq DESC LIMIT 1;"
  assert_output "sess-3"
}

# ── Test 4: genesis row has empty prev_hash ──────────────────────────────────

@test "genesis row has empty prev_hash" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  run sqlite3 "$CAST_DB_PATH" "SELECT prev_hash FROM provenance_chain ORDER BY seq LIMIT 1;"
  assert_output ""
}

# ── Test 5: verify PASS on clean chain ───────────────────────────────────────

@test "verify PASS on clean chain" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "VERIFY-CHAIN: PASS"
  assert_output --partial "3 links"
}

# ── Test 6: verify BROKEN when a chain_hash is mutated ───────────────────────

@test "verify BROKEN when a chain_hash is mutated" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" "UPDATE provenance_chain SET chain_hash='sha256:deadbeef' WHERE seq=1;"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "BROKEN"
}

# ── Test 7: verify BROKEN on session-data tamper ────────────────────────────

@test "verify BROKEN on session-data tamper (level-2)" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" "UPDATE sessions SET project='HACKED' WHERE id='sess-2';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "session-data tamper"
}

# ── Test 8: verify BROKEN when chain emptied but sessions exist ───────────────

@test "verify BROKEN when chain emptied but sessions exist (the bypass)" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" "DELETE FROM provenance_chain;"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "chain is empty but"
}

# ── Test 9: verify PASS (0 links) when both empty ───────────────────────────

@test "verify PASS (0 links) when both chain and sessions empty" {
  sqlite3 "$CAST_DB_PATH" "DELETE FROM provenance_chain; DELETE FROM agent_runs; DELETE FROM sessions;"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "PASS (0 links)"
}

# ── Test 10: pruned session attestation is skipped ──────────────────────────

@test "pruned session attestation is skipped, not failed" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" "DELETE FROM sessions WHERE id='sess-2';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "pruned-skipped"
}

# ── Test 11: status reports chain length and head ────────────────────────────

@test "status reports chain length and head" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  run python3 "$PROV" status --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "Chain length:"
  assert_output --partial "3"
}

# ── Test 12: bin/cast verify-chain propagates PASS exit 0 ──────────────────

@test "bin/cast verify-chain propagates PASS exit 0" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  run bash "$CAST_BIN" verify-chain
  assert_success
  assert_output --partial "PASS"
}

# ── Test 13: bin/cast verify-chain propagates BROKEN exit 1 ────────────────

@test "bin/cast verify-chain propagates BROKEN exit 1" {
  python3 "$PROV" backfill --db "$CAST_DB_PATH" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" "UPDATE provenance_chain SET chain_hash='sha256:deadbeef' WHERE seq=1;"
  run bash "$CAST_BIN" verify-chain
  assert_failure
}
