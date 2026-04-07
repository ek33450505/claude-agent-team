#!/usr/bin/env bats
# cast-memory-temporal.bats — Tests for temporal validity features
#
# Coverage:
#   1. cast-memory-migrate-temporal.py is idempotent (safe to run twice)
#   2. After migration, valid_from and valid_to columns exist
#   3. Backfill sets valid_from = created_at for existing rows
#   4. cast-memory-router.py --invalidate <id> sets valid_to on target row
#   5. Default retrieve mode hides rows where valid_to IS NOT NULL
#   6. --history flag in retrieve mode returns invalidated rows

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATE_SCRIPT="$REPO_DIR/scripts/cast-memory-migrate-temporal.py"
ROUTER_SCRIPT="$REPO_DIR/scripts/cast-memory-router.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — use $BATS_TMPDIR, never touch ~/.claude/cast.db
# ---------------------------------------------------------------------------

setup() {
    TEST_DB="$BATS_TMPDIR/test-temporal-$$.db"
    export CAST_DB_PATH="$TEST_DB"

    # Create agent_memories table with full schema including FTS5
    # We use python3's sqlite3 module so FTS5 availability matches the scripts
    python3 - <<'PYEOF'
import os, sqlite3
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)

# Main table — created_at pre-populated to verify backfill uses it
conn.executescript("""
    CREATE TABLE IF NOT EXISTS agent_memories (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        agent       TEXT    NOT NULL,
        project     TEXT,
        type        TEXT    NOT NULL DEFAULT 'project',
        name        TEXT    NOT NULL,
        description TEXT,
        content     TEXT,
        importance  FLOAT   DEFAULT 0.5,
        decay_rate  FLOAT   DEFAULT 0.995,
        created_at  TEXT    DEFAULT (datetime('now')),
        updated_at  TEXT    DEFAULT (datetime('now'))
    );

    INSERT INTO agent_memories (agent, type, name, description, content, created_at)
    VALUES ('shared', 'feedback', 'no-mock-db',
            'Do not mock the database in tests',
            'Integration tests must hit a real database.',
            '2026-01-15T10:00:00');

    INSERT INTO agent_memories (agent, type, name, description, content, created_at)
    VALUES ('code-writer', 'project', 'react-decision',
            'We decided to use React for the dashboard',
            'React 19 + Vite 6 chosen for the CAST observability UI.',
            '2026-02-01T08:30:00');

    CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts
        USING fts5(name, description, content, content=agent_memories, content_rowid=id);

    INSERT INTO agent_memories_fts(rowid, name, description, content)
        SELECT id, name, description, content FROM agent_memories;
""")
conn.commit()
conn.close()
PYEOF
}

teardown() {
    rm -f "$TEST_DB" "${TEST_DB}-wal" "${TEST_DB}-shm"
}

# ---------------------------------------------------------------------------
# Migration idempotency and column creation
# ---------------------------------------------------------------------------

@test "cast-memory-migrate-temporal: exits 0 on first run" {
    run python3 "$MIGRATE_SCRIPT"
    assert_success
}

@test "cast-memory-migrate-temporal: reports columns added on first run" {
    run python3 "$MIGRATE_SCRIPT"
    assert_success
    assert_output --partial "Added column: valid_from"
    assert_output --partial "Added column: valid_to"
}

@test "cast-memory-migrate-temporal: is idempotent — exits 0 on second run" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    run python3 "$MIGRATE_SCRIPT"
    assert_success
}

@test "cast-memory-migrate-temporal: second run reports already applied" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    run python3 "$MIGRATE_SCRIPT"
    assert_output --partial "already applied"
}

@test "cast-memory-migrate-temporal: valid_from column exists after migration" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    result=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
cols = {row[1] for row in conn.execute('PRAGMA table_info(agent_memories)')}
print('yes' if 'valid_from' in cols else 'no')
conn.close()
")
    [ "$result" = "yes" ]
}

@test "cast-memory-migrate-temporal: valid_to column exists after migration" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    result=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
cols = {row[1] for row in conn.execute('PRAGMA table_info(agent_memories)')}
print('yes' if 'valid_to' in cols else 'no')
conn.close()
")
    [ "$result" = "yes" ]
}

# ---------------------------------------------------------------------------
# Backfill: valid_from must equal the row's created_at
# ---------------------------------------------------------------------------

@test "cast-memory-migrate-temporal: backfill sets valid_from = created_at for existing rows" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    mismatch=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
# Rows where valid_from was backfilled should match created_at exactly
bad = conn.execute(
    \"SELECT COUNT(*) FROM agent_memories WHERE valid_from != created_at\"
).fetchone()[0]
print(bad)
conn.close()
")
    [ "$mismatch" -eq "0" ]
}

@test "cast-memory-migrate-temporal: backfill covers all pre-existing rows" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    null_count=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
c = conn.execute('SELECT COUNT(*) FROM agent_memories WHERE valid_from IS NULL').fetchone()[0]
print(c)
conn.close()
")
    [ "$null_count" -eq "0" ]
}

# ---------------------------------------------------------------------------
# Invalidate: --invalidate <id> sets valid_to on the target row
# ---------------------------------------------------------------------------

@test "cast-memory-router --invalidate: exits 0" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    run python3 "$ROUTER_SCRIPT" --invalidate 1
    assert_success
}

@test "cast-memory-router --invalidate: outputs JSON with invalidated key" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    run python3 "$ROUTER_SCRIPT" --invalidate 1
    assert_success
    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'invalidated' in d, 'missing invalidated key'
assert d['invalidated'] == 1, f'expected 1, got {d[\"invalidated\"]}'
"
}

@test "cast-memory-router --invalidate: sets valid_to IS NOT NULL on target row" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    python3 "$ROUTER_SCRIPT" --invalidate 1 >/dev/null 2>&1
    result=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
row = conn.execute('SELECT valid_to FROM agent_memories WHERE id = 1').fetchone()
print('set' if row and row[0] is not None else 'null')
conn.close()
")
    [ "$result" = "set" ]
}

@test "cast-memory-router --invalidate: leaves other rows untouched (valid_to still NULL)" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    python3 "$ROUTER_SCRIPT" --invalidate 1 >/dev/null 2>&1
    result=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
row = conn.execute('SELECT valid_to FROM agent_memories WHERE id = 2').fetchone()
print('null' if row and row[0] is None else 'set')
conn.close()
")
    [ "$result" = "null" ]
}

# ---------------------------------------------------------------------------
# Default retrieve mode hides invalidated rows
# ---------------------------------------------------------------------------

@test "cast-memory-router retrieve: hides rows with valid_to IS NOT NULL by default" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    # Invalidate row 1 (no-mock-db)
    python3 "$ROUTER_SCRIPT" --invalidate 1 >/dev/null 2>&1

    output=$(python3 "$ROUTER_SCRIPT" \
        --mode retrieve \
        --agent shared \
        --prompt "do not mock the database integration tests" \
        --top-n 10)

    # Parse result — no-mock-db should not appear
    found=$(echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
names = [r.get('name','') for r in rows]
print('yes' if 'no-mock-db' in names else 'no')
")
    [ "$found" = "no" ]
}

@test "cast-memory-router retrieve: non-invalidated rows still returned by default" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    # Invalidate only row 1; row 2 (react-decision) stays active
    python3 "$ROUTER_SCRIPT" --invalidate 1 >/dev/null 2>&1

    output=$(python3 "$ROUTER_SCRIPT" \
        --mode retrieve \
        --agent code-writer \
        --prompt "we decided to use React for the dashboard" \
        --top-n 10)

    found=$(echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
names = [r.get('name','') for r in rows]
print('yes' if 'react-decision' in names else 'no')
")
    [ "$found" = "yes" ]
}

# ---------------------------------------------------------------------------
# --history flag returns invalidated rows
# ---------------------------------------------------------------------------

@test "cast-memory-router retrieve --history: returns invalidated rows" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    python3 "$ROUTER_SCRIPT" --invalidate 1 >/dev/null 2>&1

    output=$(python3 "$ROUTER_SCRIPT" \
        --mode retrieve \
        --agent shared \
        --prompt "do not mock the database integration tests" \
        --history \
        --top-n 10)

    found=$(echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
names = [r.get('name','') for r in rows]
print('yes' if 'no-mock-db' in names else 'no')
")
    [ "$found" = "yes" ]
}

@test "cast-memory-router retrieve --history: returns valid JSON array" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    python3 "$ROUTER_SCRIPT" --invalidate 1 >/dev/null 2>&1

    run python3 "$ROUTER_SCRIPT" \
        --mode retrieve \
        --agent shared \
        --prompt "database mock integration" \
        --history \
        --top-n 5
    assert_success
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list)"
}

@test "cast-memory-router retrieve --history: returns more results than default (invalidated + active)" {
    python3 "$MIGRATE_SCRIPT" >/dev/null 2>&1
    # Invalidate row 1 so we have 1 invalidated + 1 active
    python3 "$ROUTER_SCRIPT" --invalidate 1 >/dev/null 2>&1

    default_count=$(python3 "$ROUTER_SCRIPT" \
        --mode retrieve --agent shared \
        --prompt "database react" --top-n 10 | \
        python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

    history_count=$(python3 "$ROUTER_SCRIPT" \
        --mode retrieve --agent shared \
        --prompt "database react" --history --top-n 10 | \
        python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

    [ "$history_count" -gt "$default_count" ]
}
