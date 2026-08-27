#!/usr/bin/env bats
# SEC-2 residual: record subagent lineage (spawn_depth, parent_agent_id).
#
# The item carried an explicit instruction NOT to add these columns on faith,
# because the standing evidence was that hook payloads carry no agent identity,
# and an always-NULL column is the write-only-table defect J-6 deleted
# cast-board.sh for. The premise was tested and is false: the PAYLOAD carries no
# parentage, but Claude Code writes an agent-<id>.meta.json sidecar beside every
# subagent transcript that does. Measured across 3,063 live sidecars 2026-08-27:
# spawnDepth on 3,063 (100%), parentAgentId on 188 — every agent at depth >= 2 —
# and all 188 resolve to a real sibling agent file.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/scripts/cast_subagent_stop.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_HOOK_DIR="$REPO_DIR/scripts"
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  SID="sess-lineage"
  SUBS="$HOME/.claude/projects/-probe/$SID/subagents"
  mkdir -p "$SUBS"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO sessions (id,project,project_root,started_at,status)
    VALUES ('$SID','probe','/probe','2026-08-27T18:00:00Z','active');"
}

teardown() { teardown_temp_home; }

# Seed one agent: $1=agent_id $2=agent type $3=meta json body (or '' for no sidecar)
_seed_agent() {
  local aid="$1" atype="$2" meta="$3"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}\n' \
    > "$SUBS/agent-${aid}.jsonl"
  [ -n "$meta" ] && printf '%s\n' "$meta" > "$SUBS/agent-${aid}.meta.json"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (session_id,agent,agent_id,started_at,status)
    VALUES ('$SID','${atype}','${aid}','2026-08-27T18:00:01Z','running');"
}

_fire() {
  local aid="$1" atype="$2"
  # NOTE the doubled backslashes: printf must emit the two-character JSON escape
  # \n, not a real newline. A literal newline inside a JSON string is invalid, so
  # the hook's parse fails and it returns 0 having done nothing — which looks
  # exactly like a passing test if the assertion only checks for NULLs.
  CAST_STOP_INPUT="$(printf '{"session_id":"%s","agent_type":"%s","agent_id":"%s","cwd":"/probe","last_assistant_message":"## Handoff\\nfiles_changed: a.py\\nstatus: DONE\\nblockers: none\\n"}' "$SID" "$atype" "$aid")" \
    python3 "$HOOK" >/dev/null 2>&1
}

@test "SEC-2: spawn_depth and parent_agent_id are recorded from the meta sidecar" {
  _seed_agent aaa1 code-reviewer '{"agentType":"code-reviewer","spawnDepth":2,"parentAgentId":"aparent01"}'
  _fire aaa1 code-reviewer
  run sqlite3 "$CAST_DB_PATH" "SELECT spawn_depth || '|' || COALESCE(parent_agent_id,'') FROM agent_runs WHERE agent_id='aaa1';"
  assert_output "2|aparent01"
}

@test "SEC-2: depth 1 records the depth with a NULL parent" {
  # At depth 1 the parent IS the main session, which agent_runs.session_id
  # already holds — so NULL here is correct, not missing data.
  _seed_agent aaa2 commit '{"agentType":"commit","spawnDepth":1}'
  _fire aaa2 commit
  run sqlite3 "$CAST_DB_PATH" "SELECT COALESCE(spawn_depth,-1) || '|' || COALESCE(parent_agent_id,'NULL') FROM agent_runs WHERE agent_id='aaa2';"
  assert_output "1|NULL"
}

@test "SEC-2: a missing sidecar leaves NULL and does not break the hook" {
  _seed_agent aaa3 docs ''
  _fire aaa3 docs
  run sqlite3 "$CAST_DB_PATH" "SELECT status || '|' || COALESCE(spawn_depth,'NULL') FROM agent_runs WHERE agent_id='aaa3';"
  assert_output "DONE|NULL"
}

@test "SEC-2: a corrupt sidecar leaves NULL and still closes the row" {
  # Lineage capture must never change whether the hook completes.
  _seed_agent aaa4 docs 'this is not json {{{'
  _fire aaa4 docs
  run sqlite3 "$CAST_DB_PATH" "SELECT status || '|' || COALESCE(spawn_depth,'NULL') FROM agent_runs WHERE agent_id='aaa4';"
  assert_output "DONE|NULL"
}

@test "SEC-2: a non-numeric spawnDepth is rejected rather than stored" {
  _seed_agent aaa5 docs '{"agentType":"docs","spawnDepth":"deep","parentAgentId":""}'
  _fire aaa5 docs
  # Assert status too. On NULL alone this test cannot distinguish "rejected the
  # bad value" from "the hook never ran" — and it passed vacuously exactly that
  # way while the other five failed, because the payload was malformed.
  run sqlite3 "$CAST_DB_PATH" "SELECT status || '|' || COALESCE(spawn_depth,'NULL') || '|' || COALESCE(parent_agent_id,'NULL') FROM agent_runs WHERE agent_id='aaa5';"
  assert_output "DONE|NULL|NULL"
}

@test "SEC-2: the row is still enriched normally alongside lineage" {
  # Guards the parameter binding: three UPDATE variants each gained two
  # placeholders, and a count mismatch would raise into the hook's own except
  # and silently leave the row 'running' — which is exactly what the first
  # attempt at this change did on the third variant.
  _seed_agent aaa6 code-reviewer '{"agentType":"code-reviewer","spawnDepth":2,"parentAgentId":"aparent02"}'
  _fire aaa6 code-reviewer
  run sqlite3 "$CAST_DB_PATH" "SELECT status FROM agent_runs WHERE agent_id='aaa6';"
  assert_output "DONE"
}

@test "SEC-2: a cast.db without the lineage columns still records, and self-heals them" {
  # Found by CI, not by me. The enrichment UPDATE is wrapped in try/except with a
  # retry, so an unconditional "SET ..., spawn_depth=?" against a DB that has not
  # had migration 036 applied raises "no such column" on every attempt, the row
  # stays 'running', and enrichment stops recording ENTIRELY and silently — for
  # cost, tokens, tool_uses and response, not just lineage. That is a live risk
  # for any cast.db that has not been reinstalled, and it is precisely the defect
  # class this release exists to remove.
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs DROP COLUMN spawn_depth;"
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs DROP COLUMN parent_agent_id;"
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM pragma_table_info('agent_runs') WHERE name IN ('spawn_depth','parent_agent_id');"
  assert_output "0"

  _seed_agent aaa7 code-reviewer '{"agentType":"code-reviewer","spawnDepth":2,"parentAgentId":"aparent07"}'
  _fire aaa7 code-reviewer

  # The row must close — that is the part that must never depend on a migration.
  run sqlite3 "$CAST_DB_PATH" "SELECT status FROM agent_runs WHERE agent_id='aaa7';"
  assert_output "DONE"

  # And the hook's own self-healing ALTER should have restored the columns and
  # written the lineage, rather than merely degrading past them.
  run sqlite3 "$CAST_DB_PATH" "SELECT COALESCE(spawn_depth,-1) || '|' || COALESCE(parent_agent_id,'NULL') FROM agent_runs WHERE agent_id='aaa7';"
  assert_output "2|aparent07"
}
