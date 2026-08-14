#!/usr/bin/env bats
# Tests for the cast doctor honesty surface (section 13)
# Encodes the honest-degradation contract: missing table = INFO, not green OK.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# DDL for the three honesty tables (sourced from scripts/cast-db-init.sh)
# code_ref_checks was RETIRED in v9 Phase C U7b — removed from fixture.
_create_honesty_tables() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_hallucinations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    agent_name TEXT NOT NULL,
    claim_type TEXT NOT NULL,
    claimed_value TEXT,
    actual_value TEXT,
    verified INTEGER DEFAULT 0,
    timestamp TEXT
);
CREATE TABLE IF NOT EXISTS completeness_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT NOT NULL,
    truncated_at TEXT NOT NULL,
    snippet TEXT,
    severity TEXT DEFAULT 'MEDIUM',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS agent_protocol_violations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT,
    agent_type   TEXT NOT NULL,
    agent_id     TEXT,
    batch_id     INTEGER,
    violation    TEXT NOT NULL,
    pattern      TEXT,
    timestamp    TEXT NOT NULL,
    raw_excerpt  TEXT
);
SQL
}

# Minimal cast.db with the required tables that cast doctor checks before the
# honesty block (sessions, agent_runs, routing_events, etc.)
_create_minimal_core_tables() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT, model TEXT, project_dir TEXT, session_type TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0.0, duration_ms INTEGER, tool_uses INTEGER DEFAULT 0, outcome TEXT);
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, started_at TEXT, ended_at TEXT, status TEXT, duration_ms INTEGER, tool_uses INTEGER, outcome TEXT);
CREATE TABLE IF NOT EXISTS routing_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, matched_route TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, confidence REAL DEFAULT 1.0, last_validated_at TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS stream_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS swarm_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, status TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS teammate_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, teammate_name TEXT, started_at TEXT, status TEXT);
CREATE TABLE IF NOT EXISTS teammate_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, role TEXT, content TEXT, ts TEXT);
CREATE TABLE IF NOT EXISTS tool_call_failures (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, tool_name TEXT, error TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_truncations (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, truncated_at TEXT, severity TEXT, snippet TEXT);
CREATE TABLE IF NOT EXISTS injection_log (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, injected_at TEXT, source TEXT, content_preview TEXT);
CREATE TABLE IF NOT EXISTS quality_gates (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, gate_name TEXT, result TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS dispatch_decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, reason TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS task_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, task_name TEXT, agent TEXT, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS routines (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, agent TEXT, schedule TEXT, status TEXT, last_run TEXT);
CREATE TABLE IF NOT EXISTS incidents (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, severity TEXT, description TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS plan_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, plan_file TEXT, status TEXT, started_at TEXT, ended_at TEXT);
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ran_at TEXT, merged_count INTEGER, pruned_count INTEGER);
CREATE TABLE IF NOT EXISTS archived_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, archived_at TEXT);
CREATE TABLE IF NOT EXISTS budgets (id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT, budget_usd REAL, spent_usd REAL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);
SQL
}

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CLAUDE_SUBPROCESS=0
  # No CAST_AGENTS_DIR override: bin/cast now guards it (${CAST_AGENTS_DIR:-
  # ${HOME}/.claude/agents}), so leaving it unset lets doctor fall through to
  # its own default of ${HOME}/.claude/agents — i.e. this temp HOME's fixture
  # dir. Tests that need a populated roster mkdir -p + drop .md fixtures
  # there directly (see the protocol-violations roster-split tests below);
  # this keeps the suite hermetic instead of depending on the real repo's
  # agents/core contents. A prior version of this line pointed at
  # "$REPO_DIR/agents/core" but that override was silently ignored by
  # bin/cast (no guard existed) until 2026-08-14 — removed rather than kept,
  # since making it live here would break the empty-roster test below, which
  # needs an on-demand-empty directory that a real, always-populated repo
  # dir can't provide.
}

teardown() {
  teardown_temp_home
}

# ── Helper: run cast doctor and capture combined stdout+stderr ───────────────
_run_doctor() {
  run bash "$CAST_BIN" doctor 2>&1
}

# ── Test 1: Tables absent — no honesty tables provisioned ───────────────────
@test "tables absent: reports INFO 'no data yet' for each honesty table" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  # Do NOT create any of the three honesty tables

  _run_doctor

  # Should contain the INFO 'no data yet' pattern for all three honesty tables
  # (code_ref_checks was retired in v9 Phase C U7b)
  assert_output --partial "agent_hallucinations — no data yet"
  assert_output --partial "completeness_events — no data yet"
  assert_output --partial "agent_protocol_violations — no data yet"
}

@test "tables absent: does NOT print green OK for honesty tables" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  # Do NOT create any of the three honesty tables

  _run_doctor

  # Must not report a clean OK for these tables (that would be the deep-research bug)
  # (code_ref_checks was retired in v9 Phase C U7b)
  refute_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "completeness_events — none in last 7d"
  refute_output --partial "agent_protocol_violations — none in last 7d"
}

# ── Test 2: DB unreadable — cast.db is not a valid SQLite file ───────────────
@test "unreadable db: cast doctor does not crash and honesty block reports unavailable" {
  # Overwrite cast.db with a non-sqlite file
  echo "notadb" > "$CAST_DB_PATH"

  # cast doctor will fail the first db accessibility check, but should
  # exit cleanly (not crash with unhandled error)
  run bash "$CAST_BIN" doctor 2>&1

  # The command must complete (exit may be non-zero due to db check failing,
  # but it must not produce an uncaught error / crash exit > 1 from bash -e)
  # We check that the output contains an 'unavailable' or error message,
  # and that it does NOT contain the green OK honesty lines.
  refute_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "completeness_events — none in last 7d"
  # Output should mention cast.db is not accessible (from section 1 of doctor)
  assert_output --partial "cast.db not accessible"
}

# ── Test 3: Tables present, 0 rows — all-OK state ───────────────────────────
@test "present empty tables: reports OK 'none in last 7d' for each" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"
  # Tables exist but no rows inserted

  _run_doctor

  assert_output --partial "agent_hallucinations — none in last 7d"
  assert_output --partial "completeness_events — none in last 7d"
  assert_output --partial "agent_protocol_violations — none in last 7d"
  # code_ref_checks was retired in v9 Phase C U7b — not asserted
}

@test "present empty tables: does NOT show INFO 'no data yet'" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  _run_doctor

  refute_output --partial "agent_hallucinations — no data yet"
  refute_output --partial "completeness_events — no data yet"
  refute_output --partial "agent_protocol_violations — no data yet"
  # code_ref_checks was retired in v9 Phase C U7b — not asserted
}

# ── Test 4: Tables present and populated ────────────────────────────────────
@test "populated tables: reports WARN with count and per-agent breakdown" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Insert 2 hallucinations for code-writer (recent)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/some/file.ts', '[NOT FOUND]', 0, datetime('now', '-1 hour'));
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/other/file.ts', '[NOT FOUND]', 0, datetime('now', '-2 hours'));
SQL

  # Insert 1 completeness_event severity HIGH (recent)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO completeness_events (agent, truncated_at, snippet, severity)
VALUES ('debugger', datetime('now', '-30 minutes'), 'Status: ...', 'HIGH');
SQL

  _run_doctor

  # agent_hallucinations: 2 flagged, breakdown shows code-writer
  assert_output --partial "agent_hallucinations — 2 flagged"
  assert_output --partial "code-writer"

  # completeness_events: 1 flagged, HIGH severity
  assert_output --partial "completeness_events — 1 flagged"
  assert_output --partial "HIGH"
}

@test "populated hallucinations: does NOT report OK or 'none in last 7d'" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/some/file.ts', '[NOT FOUND]', 0, datetime('now', '-1 hour'));
SQL

  _run_doctor

  refute_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "agent_hallucinations — no data yet"
}

@test "old rows outside 7d window are ignored: reports none in last 7d" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Insert a hallucination 8 days ago — outside the 7d window
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_hallucinations (agent_name, claim_type, claimed_value, actual_value, verified, timestamp)
VALUES ('code-writer', 'file_exists', '/old/file.ts', '[NOT FOUND]', 0, datetime('now', '-8 days'));
SQL

  _run_doctor

  # Should show OK, not WARN — old row is outside the window
  assert_output --partial "agent_hallucinations — none in last 7d"
  refute_output --partial "agent_hallucinations — 1 flagged"
}

# ── Test: protocol violations — roster vs unclassifiable split ──────────────
# Reporting-only regrouping of agent_protocol_violations by whether agent_type
# resolves against the installed .md roster (setup() points CAST_AGENTS_DIR at
# the real agents/core, so 'commit' and 'frontend-writer' are real roster
# agents; 'census-writer'/'lane-mi' are not — matching the ad-hoc Workflow
# agent names that motivated this split).
#
# NOTE: bin/cast:21 resolves CAST_AGENTS_DIR unconditionally to
# ${HOME}/.claude/agents — it does NOT honor a pre-exported override (no
# ${CAST_AGENTS_DIR:-default} guard), unlike CAST_REPO_DIR/CAST_DB_PATH. This
# file's setup() exports CAST_AGENTS_DIR="$REPO_DIR/agents/core", which is
# therefore a no-op for doctor. These tests build the fixture roster directly
# under ${HOME}/.claude/agents instead — the same workaround already used by
# tests/cast-doctor-expansion.bats. Flagged as a pre-existing concern in the
# handoff rather than fixed here (out of scope for this dispatch).
@test "protocol violations: known roster agent lands in 'roster agents' bucket" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  mkdir -p "${HOME}/.claude/agents"
  echo 'fixture' > "${HOME}/.claude/agents/commit.md"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_protocol_violations (agent_type, violation, timestamp)
VALUES ('commit', 'missing_formality', datetime('now', '-1 hour'));
INSERT INTO agent_protocol_violations (agent_type, violation, timestamp)
VALUES ('commit', 'handoff_schema_violation', datetime('now', '-2 hours'));
SQL

  _run_doctor

  assert_output --partial "agent_protocol_violations — 2 flagged"
  assert_output --partial "roster agents: 2 flagged"
  assert_output --partial "commit"
}

@test "protocol violations: unknown agent_type lands in 'unclassifiable' bucket, not roster" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Roster must be non-empty for the split to activate; 'commit' is present
  # but unused here so the split runs against a real (if minimal) roster.
  mkdir -p "${HOME}/.claude/agents"
  echo 'fixture' > "${HOME}/.claude/agents/commit.md"

  # 'census-writer' is an ad-hoc Workflow agent name, not an installed roster agent
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('census-writer', 'missing_formality', datetime('now', '-1 hour'));"

  _run_doctor

  assert_output --partial "agent_protocol_violations — 1 flagged"
  assert_output --partial "unclassifiable (named dispatch or ad-hoc agent): 1 flagged"
  assert_output --partial "roster agents: 0 flagged"
  assert_output --partial "census-writer"
  # non-alarming: never given the Status contract, so never a WARN glyph tied to this bucket
  assert_output --partial "cannot attribute to a roster agent"
}

# ── '<agent-type>__<label>' convention (working-conventions.md, 2026-08-14) ──
# Roster dispatches SHOULD be named this way so a custom Agent-tool `name`
# (which overwrites agent_type in the hook payload) stays classifiable. The
# part before the FIRST '__' is matched against the roster; '__' alone is
# never trusted — only an actual roster match promotes the row.
@test "protocol violations: '__'-delimited dispatch resolves via its prefix (rule 2 match)" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  mkdir -p "${HOME}/.claude/agents"
  echo 'fixture' > "${HOME}/.claude/agents/backend-writer.md"

  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('backend-writer__unit1-advisory', 'missing_formality', datetime('now', '-1 hour'));"

  _run_doctor

  assert_output --partial "agent_protocol_violations — 1 flagged"
  assert_output --partial "roster agents: 1 flagged"
  assert_output --partial "unclassifiable (named dispatch or ad-hoc agent): 0 flagged"
  assert_output --partial "backend-writer__unit1-advisory"
}

@test "protocol violations: '__'-prefix that does NOT match the roster falls through to unclassifiable (rule 2 non-match)" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Roster must be non-empty for the split to activate; 'backend-writer' is
  # present but irrelevant to 'not-an-agent' — the '__' must NOT be trusted
  # on its own.
  mkdir -p "${HOME}/.claude/agents"
  echo 'fixture' > "${HOME}/.claude/agents/backend-writer.md"

  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('not-an-agent__some-label', 'missing_formality', datetime('now', '-1 hour'));"

  _run_doctor

  assert_output --partial "agent_protocol_violations — 1 flagged"
  assert_output --partial "roster agents: 0 flagged"
  assert_output --partial "unclassifiable (named dispatch or ad-hoc agent): 1 flagged"
  assert_output --partial "not-an-agent__some-label"
}

@test "protocol violations: historical agent_type with no '__' still classifies via verbatim match (rule 1 unaffected)" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  mkdir -p "${HOME}/.claude/agents"
  echo 'fixture' > "${HOME}/.claude/agents/commit.md"

  # No '__' anywhere — this is the pre-convention shape every existing row has.
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('commit', 'missing_formality', datetime('now', '-1 hour'));"

  _run_doctor

  assert_output --partial "agent_protocol_violations — 1 flagged"
  assert_output --partial "roster agents: 1 flagged"
  assert_output --partial "unclassifiable (named dispatch or ad-hoc agent): 0 flagged"
}

@test "protocol violations: roster and unclassifiable totals reconcile with the ungrouped total" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  mkdir -p "${HOME}/.claude/agents"
  echo 'fixture' > "${HOME}/.claude/agents/commit.md"
  echo 'fixture' > "${HOME}/.claude/agents/frontend-writer.md"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('commit', 'missing_formality', datetime('now', '-1 hour'));
INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('frontend-writer', 'missing_formality', datetime('now', '-1 hour'));
INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('census-writer', 'missing_formality', datetime('now', '-1 hour'));
INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('lane-mi', 'missing_formality', datetime('now', '-1 hour'));
SQL

  _run_doctor

  # ungrouped total = 4; roster (commit, frontend-writer) = 2; unclassifiable (census-writer, lane-mi) = 2
  assert_output --partial "agent_protocol_violations — 4 flagged"
  assert_output --partial "roster agents: 2 flagged"
  assert_output --partial "unclassifiable (named dispatch or ad-hoc agent): 2 flagged"
}

@test "protocol violations: empty roster directory reports split unavailable, never a false '0 roster violations'" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_protocol_violations (agent_type, violation, timestamp) VALUES ('commit', 'missing_formality', datetime('now', '-1 hour'));"

  # ${HOME}/.claude/agents exists but is empty — roster cannot be resolved,
  # so the split must degrade honestly instead of reading as "checked and clean".
  mkdir -p "${HOME}/.claude/agents"

  _run_doctor

  # Ungrouped total must still be visible so the numbers reconcile
  assert_output --partial "agent_protocol_violations — 1 flagged"
  # The split must say it could not be computed...
  assert_output --partial "roster split unavailable"
  assert_output --partial "showing ungrouped total only"
  # ...and must NEVER render as a green/zero roster bucket
  refute_output --partial "roster agents: 0 flagged"
}

# ── Test 7: redaction failures — WARN path ──────────────────────────────────
@test "redaction failures: WARN when [REDACTION_FAILED] row exists in dispatch_decisions" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Minimal fixture uses simplified dispatch_decisions schema; add prompt_snippet
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE dispatch_decisions ADD COLUMN prompt_snippet TEXT;" 2>/dev/null || true
  # incidents needs its redaction-check columns even with 0 rows, or the
  # per-row query errors out (see the "query error" test below)
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN problem_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN fix_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN resolution_status TEXT;" 2>/dev/null || true

  # Plant a [REDACTION_FAILED] marker row
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO dispatch_decisions (prompt_snippet) VALUES ('[REDACTION_FAILED]');"

  _run_doctor

  assert_output --partial "redaction failures recorded"
  assert_output --partial "cast-redact fell back to marker"
  assert_output --partial "dispatch_decisions: 1"
  assert_output --partial "incidents unresolved: 0"
}

@test "redaction failures: WARN when [REDACTION_FAILED] incident has an unresolved (open) status" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Minimal fixture uses simplified incidents schema; add redacted-text + resolution columns
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN problem_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN fix_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN resolution_status TEXT;" 2>/dev/null || true

  # Plant a [REDACTION_FAILED] marker in problem_summary, explicitly unresolved
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO incidents (problem_summary, resolution_status) VALUES ('[REDACTION_FAILED]', 'open');"

  _run_doctor

  assert_output --partial "redaction failures recorded"
  assert_output --partial "cast-redact fell back to marker"
  assert_output --partial "incidents unresolved: 1"
}

@test "redaction failures: NULL resolution_status counts as unresolved (WARN), never assumed triaged" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN problem_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN fix_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN resolution_status TEXT;" 2>/dev/null || true

  # Plant a marker row and leave resolution_status NULL (never set)
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO incidents (problem_summary) VALUES ('[REDACTION_FAILED]');"

  _run_doctor

  assert_output --partial "redaction failures recorded"
  assert_output --partial "incidents unresolved: 1"
  refute_output --partial "redaction failures triaged"
}

# ── Test 7f: redaction failures — triaged incidents get a visible, non-WARN line ──
@test "redaction failures: triaged (fixed/wont-fix) incidents do NOT warn but ARE reported" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN problem_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN fix_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN resolution_status TEXT;" 2>/dev/null || true

  # Two marker rows, both triaged — one fixed, one wont-fix. Neither should
  # leave a WARN with no operator path to clear it short of deleting rows.
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO incidents (problem_summary, resolution_status) VALUES ('[REDACTION_FAILED]', 'fixed');
INSERT INTO incidents (fix_summary, resolution_status) VALUES ('[REDACTION_FAILED]', 'wont-fix');
SQL

  _run_doctor

  # Must NOT render as a permanent WARN
  refute_output --partial "redaction failures recorded"
  # Must NOT go silent either — the record should read "this happened, it was triaged"
  assert_output --partial "redaction failures triaged"
  assert_output --partial "2 incident marker row(s) resolved"
}

# ── Test 7g: redaction failures — incidents query error must not render false green ──
@test "redaction failures: incidents query error surfaces as unavailable, not a false OK/green" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Deliberately do NOT add problem_summary/fix_summary/resolution_status —
  # the redaction incidents query will fail with 'no such column'.

  _run_doctor

  # Must not silently render as healthy (no WARN, no OK-triaged line built off a false 0)
  refute_output --partial "redaction failures recorded"
  refute_output --partial "redaction failures triaged"
  # Must surface the query failure explicitly instead of going silent
  assert_output --partial "unable to verify triage status"
}

# ── Test 8: redaction failures — quiet pass ──────────────────────────────────
@test "redaction failures: silent when no [REDACTION_FAILED] rows exist" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Add prompt_snippet column (minimal fixture omits it)
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE dispatch_decisions ADD COLUMN prompt_snippet TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN problem_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN fix_summary TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE incidents ADD COLUMN resolution_status TEXT;" 2>/dev/null || true

  # Plant a normal (non-marker) row
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO dispatch_decisions (prompt_snippet) VALUES ('normal prompt snippet');"

  _run_doctor

  refute_output --partial "redaction failures recorded"
  refute_output --partial "cast-redact fell back to marker"
  refute_output --partial "redaction failures triaged"
  refute_output --partial "unable to verify triage status"
}

# ── Test 5: silent truncations (maxTurns) — WARN path ───────────────────────
@test "silent truncations: WARN when stuck-running row older than 2h exists" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # The minimal DDL uses agent_name; add the production column names idempotently
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN agent TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN abandoned_at TEXT;" 2>/dev/null || true

  # Insert a row stuck in running state for 3h (pre-reaper, not yet abandoned)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (agent, started_at, status)
VALUES ('test-writer', datetime('now', '-3 hours'), 'running');
SQL

  _run_doctor

  assert_output --partial "silent truncations (maxTurns) — 1 suspected truncation(s)"
  assert_output --partial "test-writer"
  assert_output --partial "likely maxTurns cap hit"
}

# ── Test 6: silent truncations (maxTurns) — OK path ─────────────────────────
@test "silent truncations: OK when no qualifying rows exist" {
  _create_minimal_core_tables "$CAST_DB_PATH"
  _create_honesty_tables "$CAST_DB_PATH"

  # Add production column names the minimal DDL omits (idempotent)
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN agent TEXT;" 2>/dev/null || true
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs ADD COLUMN abandoned_at TEXT;" 2>/dev/null || true

  # Insert a recent running row (only 30 minutes old — within the 2h threshold)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (agent, started_at, status)
VALUES ('code-writer', datetime('now', '-30 minutes'), 'running');
SQL

  _run_doctor

  assert_output --partial "silent truncations (maxTurns) — none in last 7d"
  refute_output --partial "silent truncations (maxTurns) — 1 suspected truncation"
}

# ── Test 9: cast status with nonexistent cast.db ──────────────────────────────
@test "cast status: nonexistent cast.db outputs 'cast.db not found' in Spend line" {
  # CAST_DB_PATH set in setup() but we intentionally do NOT create the db file
  run env CAST_DB_PATH="$BATS_TEST_TMPDIR/nope.db" bash "$CAST_BIN" status

  assert_success
  assert_output --partial "cast.db not found"
}

# ── Test 10: cast status with unreadable cast.db ─────────────────────────────
@test "cast status: chmod 000 cast.db outputs 'present but unreadable' in Spend line" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "chmod-000 unreadable simulation requires non-root"
  fi

  # Create and then make unreadable
  _create_minimal_core_tables "$CAST_DB_PATH"
  chmod 000 "$CAST_DB_PATH"

  run env CAST_DB_PATH="$CAST_DB_PATH" bash "$CAST_BIN" status

  assert_success
  assert_output --partial "present but unreadable"
}

# ── Test 11: cast memory list with missing cast.db ────────────────────────────
@test "cast memory list: missing cast.db fails with 'cast.db not found' and init hint" {
  # CAST_DB_PATH intentionally not created
  run env CAST_DB_PATH="$BATS_TEST_TMPDIR/nope.db" bash "$CAST_BIN" memory list

  assert_failure
  assert_output --partial "cast.db not found"
  assert_output --partial "cast-db-init.sh"
}

# ── Test 12: cast memory list with unreadable cast.db ─────────────────────────
@test "cast memory list: chmod 000 cast.db fails with 'present but unreadable' hint" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "chmod-000 unreadable simulation requires non-root"
  fi

  # Create tables then make unreadable
  _create_minimal_core_tables "$CAST_DB_PATH"
  chmod 000 "$CAST_DB_PATH"

  run env CAST_DB_PATH="$CAST_DB_PATH" bash "$CAST_BIN" memory list

  assert_failure
  assert_output --partial "present but unreadable"
  assert_output --partial "allowRead"
}

# ── Test 13: cast-validate.sh FTS5 honesty - missing cast.db ──────────────────
@test "cast-validate.sh FTS5: missing cast.db outputs 'cast.db not found'" {
  # HOME points to temp dir with no .claude subdirectory
  run env HOME="$BATS_TEST_TMPDIR/home" bash "$REPO_DIR/scripts/cast-validate.sh" 2>&1

  # Do NOT assert overall exit code; other checks may warn/fail
  # Only check for the FTS5 substring
  assert_output --partial "FTS5: cast.db not found"
}

# ── Test 14: cast-validate.sh FTS5 honesty - unreadable cast.db ───────────────
@test "cast-validate.sh FTS5: chmod 000 cast.db outputs 'present but unreadable'" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "chmod-000 unreadable simulation requires non-root"
  fi

  # Create .claude dir and unreadable cast.db
  local test_home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$test_home/.claude"
  local test_db="$test_home/.claude/cast.db"

  # Create a minimal sqlite3 db then make unreadable
  sqlite3 "$test_db" "CREATE TABLE t (id INT);" 2>/dev/null
  chmod 000 "$test_db"

  run env HOME="$test_home" bash "$REPO_DIR/scripts/cast-validate.sh" 2>&1

  # Do NOT assert overall exit code
  assert_output --partial "FTS5: cast.db present but unreadable"
}
