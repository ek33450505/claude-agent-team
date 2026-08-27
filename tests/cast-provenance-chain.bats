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

# ── PROV-1: attestation is against the STORED receipt, not live data ──────────
#
# verify once re-derived session_digest from LIVE data, and the inputs to that
# derivation keep changing for reasons that are not tamper: cast-db-prune deletes
# agent_runs while provenance_chain is never pruned, and cost/tool_uses/model are
# backfilled at completion. Measured 2026-08-27 on the live chain: 244 of 929 rows
# (26%) reported "session-data tamper detected" and not one was tamper. A chain
# that is permanently part-red carries no information.

@test "PROV-1: append stores the canonical receipt it hashed" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  run sqlite3 "$CAST_DB_PATH" "SELECT receipt_json IS NOT NULL FROM provenance_chain WHERE session_id='sess-1';"
  assert_output "1"
  # The stored payload must be exactly what the digest was taken over.
  run python3 -c "
import hashlib, sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute(
    \"SELECT session_digest, receipt_json FROM provenance_chain WHERE session_id='sess-1'\").fetchone()
print('match' if row[0] == 'sha256:' + hashlib.sha256(row[1].encode()).hexdigest() else 'MISMATCH')
" "$CAST_DB_PATH"
  assert_output "match"
}

@test "PROV-1: a post-append cost backfill is DRIFT, not tamper" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  # Exactly what CAST's own stage-2 transcript pass does after a session ends.
  sqlite3 "$CAST_DB_PATH" "UPDATE agent_runs SET cost_usd = 9.99, tool_uses = 77 WHERE session_id='sess-1';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "PASS"
  assert_output --partial "1 drifted from live data"
  refute_output --partial "tamper"
}

@test "PROV-1: agent_runs pruned out from under a receipt is DRIFT, not tamper" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  # Retention deletes agent_runs; provenance_chain is never pruned. This is the
  # dominant historical cause — the live chain's oldest surviving agent_runs row
  # was 2026-07-28 and July chain rows were 40% "broken" against August's 9%.
  sqlite3 "$CAST_DB_PATH" "DELETE FROM agent_runs WHERE session_id='sess-1';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "1 drifted from live data"
  refute_output --partial "tamper"
}

@test "PROV-1: editing the stored receipt IS detected" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  sqlite3 "$CAST_DB_PATH" "UPDATE provenance_chain SET receipt_json = replace(receipt_json, 'code-writer', 'ghost-agent') WHERE session_id='sess-1';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "BROKEN"
  assert_output --partial "stored receipt does not match its digest"
}

@test "PROV-1: editing the stored digest still breaks level-1 linkage" {
  # Legacy rows carry no receipt, so this is the guarantee they keep: level 1
  # covers every row regardless, and an unverifiable attestation is not an
  # unguarded row.
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  sqlite3 "$CAST_DB_PATH" "UPDATE provenance_chain SET session_digest = 'sha256:0000' WHERE session_id='sess-1';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "chain_hash mismatch"
}

@test "PROV-1: a legacy row with no receipt reports unverifiable, not broken" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  sqlite3 "$CAST_DB_PATH" "UPDATE provenance_chain SET receipt_json = NULL WHERE session_id='sess-1';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "1 unverifiable"
  refute_output --partial "BROKEN"
}

@test "PROV-1: --require-attestation turns unverifiable into a failure" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  sqlite3 "$CAST_DB_PATH" "UPDATE provenance_chain SET receipt_json = NULL WHERE session_id='sess-1';"
  run python3 "$PROV" verify --require-attestation --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "carry no stored receipt"
}

@test "PROV-1: append still works on a DB predating the receipt_json column" {
  # _append_session is fail-open: an unconditional 5-column INSERT against an
  # un-upgraded DB would raise into its own except and turn "not migrated yet"
  # into "the chain silently stopped growing".
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE provenance_chain RENAME TO provenance_chain_new;"
  sqlite3 "$CAST_DB_PATH" "CREATE TABLE provenance_chain (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
    prev_hash TEXT NOT NULL DEFAULT '', session_digest TEXT NOT NULL,
    chain_hash TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));"
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM provenance_chain;"
  assert_output "1"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_success
  assert_output --partial "1 unverifiable"
}

@test "PROV-1: tamper in an IMMUTABLE session field is still BROKEN, not drift" {
  # The complement of the drift tests. Downgrading every live-data divergence to
  # "drift" would have removed the coverage test 7 exists for — project,
  # project_root, started_at and id are written once and never updated, so they
  # cannot drift for any benign reason.
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  sqlite3 "$CAST_DB_PATH" "UPDATE sessions SET project='HACKED' WHERE id='sess-1';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "session-data tamper detected"
  assert_output --partial "project"
}

@test "PROV-1: a mutable-field change alongside an immutable one still reports tamper" {
  run python3 "$PROV" append sess-1 --db "$CAST_DB_PATH"
  assert_success
  sqlite3 "$CAST_DB_PATH" "UPDATE agent_runs SET cost_usd=9.99 WHERE session_id='sess-1';"
  sqlite3 "$CAST_DB_PATH" "UPDATE sessions SET started_at='2020-01-01T00:00:00' WHERE id='sess-1';"
  run python3 "$PROV" verify --db "$CAST_DB_PATH"
  assert_failure
  assert_output --partial "started_at"
}
