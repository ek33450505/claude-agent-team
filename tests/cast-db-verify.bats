#!/usr/bin/env bats
# tests/cast-db-verify.bats
# Verifies scripts/cast-db-verify.py against fixture databases built in BATS_TEST_TMPDIR.
# Never touches the real ~/.claude/cast.db — every test uses --db with a throwaway fixture.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/cast-db-verify.py"

# Build a minimal, fully-clean cast.db fixture (all invariants satisfied).
setup() {
  DB="${BATS_TEST_TMPDIR}/cast.db"
  sqlite3 "$DB" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at TEXT);
CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, session_id TEXT, agent TEXT, status TEXT, started_at TEXT, ended_at TEXT, duration_ms INTEGER, tool_uses INTEGER);
CREATE TABLE dispatch_decisions (id INTEGER PRIMARY KEY, session_id TEXT, chosen_agent TEXT, outcome TEXT DEFAULT 'pending');
CREATE TABLE agent_truncations (id INTEGER PRIMARY KEY, session_id TEXT, agent_type TEXT NOT NULL, timestamp TEXT NOT NULL);
CREATE TABLE quality_gates (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, status_line TEXT);
CREATE TABLE agent_memories (id INTEGER PRIMARY KEY, agent TEXT NOT NULL, name TEXT, project TEXT, embedding BLOB, last_validated_at TEXT);
INSERT INTO sessions VALUES ('s1','2026-06-03T00:00:00Z');
INSERT INTO agent_runs VALUES (1,'s1','code-writer','DONE','2026-06-03T01:00:00Z','2026-06-03T01:05:00Z',500,3);
INSERT INTO quality_gates VALUES ('g1','s1','code-reviewer','DONE');
INSERT INTO agent_memories VALUES (1,'researcher','m1','proj',x'00','2026-06-03T00:00:00Z');
SQL
}

@test "clean fixture passes with exit 0" {
  run python3 "$SCRIPT" --db "$DB"
  assert_success
  assert_output --partial "0 error"
}

@test "C2: a workflow-subagent truncation row is an error (exit 1)" {
  sqlite3 "$DB" "INSERT INTO agent_truncations VALUES (99,'s1','workflow-subagent','2026-06-03T02:00:00Z');"
  run python3 "$SCRIPT" --db "$DB"
  assert_failure
  assert_output --partial "C2"
  assert_output --partial "violation"
}

@test "C3: a free-text status_line is an error" {
  sqlite3 "$DB" "INSERT INTO quality_gates VALUES ('g2','s1','x','Status: DONE (recovered)');"
  run python3 "$SCRIPT" --db "$DB"
  assert_failure
  assert_output --partial "C3"
}

@test "C1: an orphan session_id is an error" {
  sqlite3 "$DB" "INSERT INTO agent_runs (id,session_id,agent,status,started_at,ended_at) VALUES (2,'NOPE','code-writer','DONE','2026-06-03T01:00:00Z','2026-06-03T01:05:00Z');"
  run python3 "$SCRIPT" --db "$DB"
  assert_failure
  assert_output --partial "C1.agent_runs"
}

@test "C6: ended_at before started_at is an error (real, not a format artifact)" {
  sqlite3 "$DB" "INSERT INTO agent_runs (id,session_id,agent,status,started_at,ended_at) VALUES (3,'s1','debugger','DONE','2026-06-03T05:00:00Z','2026-06-03T04:00:00Z');"
  run python3 "$SCRIPT" --db "$DB"
  assert_failure
  assert_output --partial "C6"
}

@test "C6 tolerates mixed T/Z vs space timestamp formats (no false negative)" {
  # ended is later in real time but uses the space/no-Z dialect; must NOT fail C6.
  sqlite3 "$DB" "INSERT INTO agent_runs (id,session_id,agent,status,started_at,ended_at) VALUES (4,'s1','push','DONE','2026-06-03T00:02:48Z','2026-06-03 13:04:11');"
  run python3 "$SCRIPT" --db "$DB"
  # C7 (warn) will flag the format, but no C6 ERROR should appear → still exit 0.
  assert_success
}

@test "--json emits valid JSON" {
  run python3 "$SCRIPT" --db "$DB" --json
  assert_success
  echo "$output" | python3 -m json.tool >/dev/null
}

@test "missing database exits 2" {
  run python3 "$SCRIPT" --db "${BATS_TEST_TMPDIR}/does-not-exist.db"
  assert_equal "$status" 2
}

@test "warn-only violation passes by default, fails with --fail-on-warn" {
  sqlite3 "$DB" "INSERT INTO agent_memories VALUES (2,'researcher','m2',NULL,NULL,NULL);"
  run python3 "$SCRIPT" --db "$DB"
  assert_success
  run python3 "$SCRIPT" --db "$DB" --fail-on-warn
  assert_failure
}

@test "C4: an unknown agent_runs.status is an error" {
  sqlite3 "$DB" "INSERT INTO agent_runs (id,session_id,agent,status,started_at,ended_at) VALUES (5,'s1','code-writer','frobnicated','2026-06-03T01:00:00Z','2026-06-03T01:05:00Z');"
  run python3 "$SCRIPT" --db "$DB"
  assert_failure
  assert_output --partial "C4"
}

@test "C5: a long-stale running run is a warn (passes default, fails --fail-on-warn)" {
  sqlite3 "$DB" "INSERT INTO agent_runs (id,session_id,agent,status,started_at,ended_at) VALUES (6,'s1','researcher','running','2020-01-01T00:00:00Z',NULL);"
  run python3 "$SCRIPT" --db "$DB"
  assert_success
  run python3 "$SCRIPT" --db "$DB" --fail-on-warn
  assert_failure
  assert_output --partial "C5"
}

@test "C7: a space/no-Z timestamp is a format warn" {
  sqlite3 "$DB" "INSERT INTO agent_runs (id,session_id,agent,status,started_at,ended_at) VALUES (7,'s1','push','DONE','2026-06-03T00:00:00Z','2026-06-03 13:00:00');"
  run python3 "$SCRIPT" --db "$DB" --fail-on-warn
  assert_failure
  assert_output --partial "C7"
}

@test "C8: duplicate (agent,name) memories is an error" {
  sqlite3 "$DB" "INSERT INTO agent_memories VALUES (3,'researcher','m1','proj',x'00','2026-06-03T00:00:00Z');"
  run python3 "$SCRIPT" --db "$DB"
  assert_failure
  assert_output --partial "C8"
}

@test "C9: NULL completeness columns are reported as a warn" {
  sqlite3 "$DB" "INSERT INTO agent_memories VALUES (4,'researcher','m9',NULL,NULL,NULL);"
  run python3 "$SCRIPT" --db "$DB" --fail-on-warn
  assert_failure
  assert_output --partial "C9"
}

@test "missing optional tables are skipped, not failed" {
  # A DB with only sessions + agent_runs (with v7.4.0 columns) should not error on absent tables.
  MIN="${BATS_TEST_TMPDIR}/min.db"
  sqlite3 "$MIN" "CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at TEXT); CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, session_id TEXT, agent TEXT, status TEXT, started_at TEXT, ended_at TEXT, duration_ms INTEGER, tool_uses INTEGER); INSERT INTO sessions VALUES ('s1','2026-06-03T00:00:00Z');"
  run python3 "$SCRIPT" --db "$MIN"
  assert_success
  assert_output --partial "skip"
}

@test "C10: agent_runs with duration_ms+tool_uses and dispatch_decisions with outcome pass" {
  # Build a DB that has all three v7.4.0 init-authoritative columns.
  C10_DB="${BATS_TEST_TMPDIR}/c10_pass.db"
  sqlite3 "$C10_DB" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at TEXT);
CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, session_id TEXT, agent TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, duration_ms INTEGER, tool_uses INTEGER);
CREATE TABLE dispatch_decisions (id INTEGER PRIMARY KEY, session_id TEXT, chosen_agent TEXT,
  outcome TEXT DEFAULT 'pending');
CREATE TABLE agent_truncations (id INTEGER PRIMARY KEY, session_id TEXT, agent_type TEXT NOT NULL, timestamp TEXT NOT NULL);
CREATE TABLE quality_gates (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, status_line TEXT);
CREATE TABLE agent_memories (id INTEGER PRIMARY KEY, agent TEXT NOT NULL, name TEXT, project TEXT,
  embedding BLOB, last_validated_at TEXT);
INSERT INTO sessions VALUES ('s1','2026-06-03T00:00:00Z');
SQL
  run python3 "$SCRIPT" --db "$C10_DB"
  assert_success
  assert_output --partial "C10.agent_runs.duration_ms"
  assert_output --partial "C10.agent_runs.tool_uses"
  assert_output --partial "C10.dispatch_decisions.outcome"
}

@test "C10: missing agent_runs.duration_ms is an error" {
  C10_DB="${BATS_TEST_TMPDIR}/c10_fail_dur.db"
  sqlite3 "$C10_DB" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at TEXT);
CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, session_id TEXT, agent TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, tool_uses INTEGER);
CREATE TABLE dispatch_decisions (id INTEGER PRIMARY KEY, session_id TEXT, chosen_agent TEXT,
  outcome TEXT DEFAULT 'pending');
CREATE TABLE agent_truncations (id INTEGER PRIMARY KEY, session_id TEXT, agent_type TEXT NOT NULL, timestamp TEXT NOT NULL);
CREATE TABLE quality_gates (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, status_line TEXT);
CREATE TABLE agent_memories (id INTEGER PRIMARY KEY, agent TEXT NOT NULL, name TEXT);
SQL
  run python3 "$SCRIPT" --db "$C10_DB"
  assert_failure
  assert_output --partial "C10.agent_runs.duration_ms"
}

@test "C10: missing dispatch_decisions.outcome is an error" {
  C10_DB="${BATS_TEST_TMPDIR}/c10_fail_outcome.db"
  sqlite3 "$C10_DB" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at TEXT);
CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, session_id TEXT, agent TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, duration_ms INTEGER, tool_uses INTEGER);
CREATE TABLE dispatch_decisions (id INTEGER PRIMARY KEY, session_id TEXT, chosen_agent TEXT);
CREATE TABLE agent_truncations (id INTEGER PRIMARY KEY, session_id TEXT, agent_type TEXT NOT NULL, timestamp TEXT NOT NULL);
CREATE TABLE quality_gates (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, status_line TEXT);
CREATE TABLE agent_memories (id INTEGER PRIMARY KEY, agent TEXT NOT NULL, name TEXT);
SQL
  run python3 "$SCRIPT" --db "$C10_DB"
  assert_failure
  assert_output --partial "C10.dispatch_decisions.outcome"
}

@test "C10: absent dispatch_decisions table is skipped not failed" {
  C10_DB="${BATS_TEST_TMPDIR}/c10_skip_dd.db"
  sqlite3 "$C10_DB" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at TEXT);
CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, session_id TEXT, agent TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, duration_ms INTEGER, tool_uses INTEGER);
CREATE TABLE agent_truncations (id INTEGER PRIMARY KEY, session_id TEXT, agent_type TEXT NOT NULL, timestamp TEXT NOT NULL);
CREATE TABLE quality_gates (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, status_line TEXT);
CREATE TABLE agent_memories (id INTEGER PRIMARY KEY, agent TEXT NOT NULL, name TEXT);
SQL
  run python3 "$SCRIPT" --db "$C10_DB"
  assert_success
  assert_output --partial "skip"
}
