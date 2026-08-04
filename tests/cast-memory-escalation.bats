#!/usr/bin/env bats
# Tests for scripts/cast-memory-escalation.sh
# Covers: no-sqlite3 guard, missing agent_runs table guard, 0-rules output,
# happy-path rule generation + auto-rules.md write, idempotent re-run, and
# --project filtering. Black-box subprocess tests — the source script is
# copied (unmodified) into a temp scripts dir alongside a stub
# cast-memory-write.sh, since the script invokes its sibling via
# "$(dirname "$0")/cast-memory-write.sh" and a missing sibling would fail
# silently (the call is wrapped in `2>/dev/null || true`).
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ESCALATION_SRC="$REPO_DIR/scripts/cast-memory-escalation.sh"
DB_INIT_SRC="$REPO_DIR/scripts/cast-db-init.sh"

setup() {
	load 'helpers/setup'
	setup_temp_home # sets HOME to a temp dir; exports ORIG_HOME

	mkdir -p "$HOME/s"
	cp "$ESCALATION_SRC" "$HOME/s/cast-memory-escalation.sh"
	chmod +x "$HOME/s/cast-memory-escalation.sh"

	# Stub sibling dependency: logs its args, always exits 0.
	cat >"$HOME/s/cast-memory-write.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$HOME/memory-write.log"
exit 0
EOF
	chmod +x "$HOME/s/cast-memory-write.sh"

	mkdir -p "$HOME/emptybin"

	export SCRIPT="$HOME/s/cast-memory-escalation.sh"
	export TEST_DB="$HOME/.claude/cast.db"
	mkdir -p "$(dirname "$TEST_DB")"
}

teardown() {
	teardown_temp_home
}

# --- Fixture helpers ---

_insert_session() {
	# args: session_id project
	python3 - "$1" "$2" "$TEST_DB" <<'PYEOF'
import sqlite3, sys
session_id, project, db_path = sys.argv[1:4]
conn = sqlite3.connect(db_path, timeout=5)
conn.execute(
    "INSERT INTO sessions (id, project, started_at, status) VALUES (?, ?, datetime('now'), 'active')",
    (session_id, project)
)
conn.commit()
conn.close()
PYEOF
}

_insert_review_run() {
	# args: session_id response_text
	python3 - "$1" "$2" "$TEST_DB" <<'PYEOF'
import sqlite3, sys
session_id, response, db_path = sys.argv[1:4]
conn = sqlite3.connect(db_path, timeout=5)
conn.execute(
    "INSERT INTO agent_runs (session_id, agent, status, response, started_at, ended_at) "
    "VALUES (?, 'code-reviewer', 'DONE', ?, datetime('now'), datetime('now'))",
    (session_id, response)
)
conn.commit()
conn.close()
PYEOF
}

# --- Sanity-check guards ---

@test "escalation: exits 0 when sqlite3 is absent from PATH" {
	run env PATH="$HOME/emptybin" /bin/bash "$SCRIPT" --db "$TEST_DB"
	assert_success
}

@test "escalation: exits 0 when the DB has no agent_runs table" {
	sqlite3 "$TEST_DB" "CREATE TABLE placeholder(id INTEGER);"
	run bash "$SCRIPT" --db "$TEST_DB"
	assert_success
}

# --- Detection output ---

@test "escalation: prints '0 auto-rules generated' when no keyword recurs 3+ times" {
	bash "$DB_INIT_SRC" --db "$TEST_DB" >/dev/null 2>&1
	_insert_session "sess-1" "demoproj"
	_insert_review_run "sess-1" "This has hardcoded value once"

	run bash "$SCRIPT" --db "$TEST_DB"
	assert_success
	assert_output --partial "0 auto-rules generated"
}

@test "escalation: happy path generates 1 auto-rule and writes auto-rules.md" {
	bash "$DB_INIT_SRC" --db "$TEST_DB" >/dev/null 2>&1
	_insert_session "sess-1" "demoproj"
	_insert_review_run "sess-1" "Found hardcoded credentials in config.py"
	_insert_review_run "sess-1" "This value is hardcoded again here"
	_insert_review_run "sess-1" "Please remove the hardcoded secret"

	run bash "$SCRIPT" --db "$TEST_DB"
	assert_success
	assert_output --partial "1 auto-rules generated"

	local rules_file="$HOME/.claude/agent-memory-local/demoproj/auto-rules.md"
	[ -f "$rules_file" ]
	grep -q "recurring concern 'hardcoded' in demoproj" "$rules_file"
}

@test "escalation: running twice does not duplicate the rule name in auto-rules.md" {
	bash "$DB_INIT_SRC" --db "$TEST_DB" >/dev/null 2>&1
	_insert_session "sess-1" "demoproj"
	_insert_review_run "sess-1" "hardcoded value one"
	_insert_review_run "sess-1" "hardcoded value two"
	_insert_review_run "sess-1" "hardcoded value three"

	run bash "$SCRIPT" --db "$TEST_DB"
	assert_success
	run bash "$SCRIPT" --db "$TEST_DB"
	assert_success

	local rules_file="$HOME/.claude/agent-memory-local/demoproj/auto-rules.md"
	local count
	count="$(grep -c "recurring concern 'hardcoded' in demoproj" "$rules_file")"
	[ "$count" -eq 1 ]
}

@test "escalation: --project filter narrows detection to the given project" {
	bash "$DB_INIT_SRC" --db "$TEST_DB" >/dev/null 2>&1
	_insert_session "sess-a" "proj-a"
	_insert_session "sess-b" "proj-b"
	_insert_review_run "sess-a" "hardcoded one"
	_insert_review_run "sess-a" "hardcoded two"
	_insert_review_run "sess-a" "hardcoded three"
	_insert_review_run "sess-b" "dead code one"
	_insert_review_run "sess-b" "dead code two"
	_insert_review_run "sess-b" "dead code three"

	run bash "$SCRIPT" --db "$TEST_DB" --project proj-a
	assert_success
	assert_output --partial "1 auto-rules generated for project proj-a"

	[ -f "$HOME/.claude/agent-memory-local/proj-a/auto-rules.md" ]
	[ ! -f "$HOME/.claude/agent-memory-local/proj-b/auto-rules.md" ]
}
