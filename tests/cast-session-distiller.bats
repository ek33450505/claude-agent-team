#!/usr/bin/env bats
# cast-session-distiller.bats — Tests for cast-session-distiller.py
#
# Coverage:
#   1. --dry-run outputs valid JSON array
#   2. "don't mock the database" → feedback type, importance >= 0.85
#   3. "always run the linter" → feedback type, importance >= 0.75
#   4. "we decided to use React" → project type, importance >= 0.70
#   5. "the config lives in /etc/foo" → reference type, importance >= 0.65
#   6. Duplicate detection: insert once, re-run skips (0 inserted)
#   7. --min-importance 0.9 filters candidates below threshold
#   8. Empty input → empty JSON array [], exit 0

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DISTILLER="$REPO_DIR/scripts/cast-session-distiller.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — $BATS_TMPDIR scoped, never touch ~/.claude/cast.db
# ---------------------------------------------------------------------------

setup() {
    TEST_DB="$BATS_TMPDIR/test-distiller-$$.db"
    export CAST_DB_PATH="$TEST_DB"

    # Create agent_memories with full schema including valid_from/valid_to
    python3 - <<'PYEOF'
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
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
        valid_from  TEXT    DEFAULT NULL,
        valid_to    TEXT    DEFAULT NULL,
        created_at  TEXT    DEFAULT (datetime('now')),
        updated_at  TEXT    DEFAULT (datetime('now'))
    );
""")
conn.commit()
conn.close()
PYEOF
}

teardown() {
    rm -f "$TEST_DB" "${TEST_DB}-wal" "${TEST_DB}-shm"
}

# ---------------------------------------------------------------------------
# Helper: run distiller with a single-line transcript via stdin
# ---------------------------------------------------------------------------

distill() {
    # $1 = transcript text, rest = extra args passed to distiller
    local text="$1"; shift
    echo "$text" | python3 "$DISTILLER" "$@"
}

distill_dry() {
    local text="$1"; shift
    echo "$text" | python3 "$DISTILLER" --dry-run "$@"
}

# ---------------------------------------------------------------------------
# 1. --dry-run produces valid JSON array
# ---------------------------------------------------------------------------

@test "distiller --dry-run: exits 0" {
    run distill_dry "don't mock the database — we were burned by it last quarter."
    assert_success
}

@test "distiller --dry-run: output is a valid JSON array" {
    run distill_dry "don't mock the database — we were burned by it last quarter."
    assert_success
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list)"
}

@test "distiller --dry-run: does NOT write to the database" {
    distill_dry "don't mock the database — we were burned by it last quarter." >/dev/null
    count=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(conn.execute('SELECT COUNT(*) FROM agent_memories').fetchone()[0])
conn.close()
")
    [ "$count" -eq "0" ]
}

# ---------------------------------------------------------------------------
# 2. "don't mock the database" → feedback, importance >= 0.85
# ---------------------------------------------------------------------------

@test "distiller: \"don't mock the database\" extracts feedback type" {
    result=$(distill_dry "don't mock the database — we were burned by mocking last quarter.")
    type=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['type'] if items else 'none')
")
    [ "$type" = "feedback" ]
}

@test "distiller: \"don't mock the database\" has importance >= 0.85" {
    result=$(distill_dry "don't mock the database — we were burned by mocking last quarter.")
    importance=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['importance'] if items else 0)
")
    python3 -c "assert float('$importance') >= 0.85, f'importance {float(\"$importance\")} < 0.85'"
}

# ---------------------------------------------------------------------------
# 3. "always run the linter" → feedback, importance >= 0.75
# ---------------------------------------------------------------------------

@test "distiller: \"always run the linter\" extracts feedback type" {
    result=$(distill_dry "always run the linter before committing any code changes.")
    type=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['type'] if items else 'none')
")
    [ "$type" = "feedback" ]
}

@test "distiller: \"always run the linter\" has importance >= 0.75" {
    result=$(distill_dry "always run the linter before committing any code changes.")
    importance=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['importance'] if items else 0)
")
    python3 -c "assert float('$importance') >= 0.75, f'importance {float(\"$importance\")} < 0.75'"
}

# ---------------------------------------------------------------------------
# 4. "we decided to use React" → project, importance >= 0.70
# ---------------------------------------------------------------------------

@test "distiller: \"we decided to use React\" extracts project type" {
    result=$(distill_dry "we decided to use React for the new dashboard UI.")
    type=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['type'] if items else 'none')
")
    [ "$type" = "project" ]
}

@test "distiller: \"we decided to use React\" has importance >= 0.70" {
    result=$(distill_dry "we decided to use React for the new dashboard UI.")
    importance=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['importance'] if items else 0)
")
    python3 -c "assert float('$importance') >= 0.70, f'importance {float(\"$importance\")} < 0.70'"
}

# ---------------------------------------------------------------------------
# 5. "the config lives in /etc/foo" → reference, importance >= 0.65
# ---------------------------------------------------------------------------

@test "distiller: \"the config lives in /etc/foo\" extracts reference type" {
    result=$(distill_dry "the config lives in /etc/foo on the production server.")
    type=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['type'] if items else 'none')
")
    [ "$type" = "reference" ]
}

@test "distiller: \"the config lives in /etc/foo\" has importance >= 0.65" {
    result=$(distill_dry "the config lives in /etc/foo on the production server.")
    importance=$(echo "$result" | python3 -c "
import json,sys
items = json.load(sys.stdin)
print(items[0]['importance'] if items else 0)
")
    python3 -c "assert float('$importance') >= 0.65, f'importance {float(\"$importance\")} < 0.65'"
}

# ---------------------------------------------------------------------------
# 6. Duplicate detection: second run skips already-inserted memories
# ---------------------------------------------------------------------------

@test "distiller duplicate detection: first run inserts the memory" {
    echo "don't mock the database — integration tests must use real DB." | \
        python3 "$DISTILLER" 2>&1
    count=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(conn.execute(\"SELECT COUNT(*) FROM agent_memories WHERE agent='shared'\").fetchone()[0])
conn.close()
")
    [ "$count" -ge "1" ]
}

@test "distiller duplicate detection: second run with same input skips (0 inserted)" {
    local transcript="don't mock the database — integration tests must use real DB."
    echo "$transcript" | python3 "$DISTILLER" >/dev/null 2>&1

    # Capture stderr of second run — distiller prints insert/skip counts there
    stderr_out=$(echo "$transcript" | python3 "$DISTILLER" 2>&1 >/dev/null)
    echo "$stderr_out" | grep -q "0 inserted"
}

@test "distiller duplicate detection: row count stays the same after second run" {
    local transcript="don't mock the database — integration tests must use real DB."
    echo "$transcript" | python3 "$DISTILLER" >/dev/null 2>&1
    count_after_first=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(conn.execute('SELECT COUNT(*) FROM agent_memories').fetchone()[0])
conn.close()
")
    echo "$transcript" | python3 "$DISTILLER" >/dev/null 2>&1
    count_after_second=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(conn.execute('SELECT COUNT(*) FROM agent_memories').fetchone()[0])
conn.close()
")
    [ "$count_after_first" -eq "$count_after_second" ]
}

# ---------------------------------------------------------------------------
# 7. --min-importance filters out candidates below the threshold
# ---------------------------------------------------------------------------

@test "distiller --min-importance 0.9: dry-run returns empty array for 0.85-importance input" {
    # "don't mock" patterns score 0.85, below the 0.9 threshold
    result=$(distill_dry "don't mock the database." --min-importance 0.9)
    count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    [ "$count" -eq "0" ]
}

@test "distiller --min-importance 0.9: dry-run still returns empty array, exits 0" {
    run distill_dry "always run the linter before commit." --min-importance 0.9
    assert_success
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list)"
}

@test "distiller --min-importance 0.6 (default): includes 0.75-importance candidates" {
    # "always" pattern fires at 0.75, which is above the default 0.6 threshold
    result=$(distill_dry "always run the linter before committing changes.")
    count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    [ "$count" -ge "1" ]
}

# ---------------------------------------------------------------------------
# 8. Empty input → empty JSON array [], exit 0
# ---------------------------------------------------------------------------

@test "distiller empty input: exits 0" {
    run bash -c "echo '' | python3 '$DISTILLER' --dry-run"
    assert_success
}

@test "distiller empty input: outputs [] JSON array in dry-run mode" {
    result=$(echo "" | python3 "$DISTILLER" --dry-run)
    [ "$result" = "[]" ]
}

@test "distiller whitespace-only input: exits 0" {
    run bash -c "printf '   \n   ' | python3 '$DISTILLER' --dry-run"
    assert_success
}

@test "distiller whitespace-only input: outputs []" {
    result=$(printf '   \n   ' | python3 "$DISTILLER" --dry-run)
    [ "$result" = "[]" ]
}

# ---------------------------------------------------------------------------
# Additional: inserted rows have correct fields stored in DB
# ---------------------------------------------------------------------------

@test "distiller: inserted row has agent='shared'" {
    echo "don't mock the database — we were burned by it." | \
        python3 "$DISTILLER" >/dev/null 2>&1
    agent=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
row = conn.execute('SELECT agent FROM agent_memories LIMIT 1').fetchone()
print(row[0] if row else 'none')
conn.close()
")
    [ "$agent" = "shared" ]
}

@test "distiller: inserted row has valid_from set (temporal migration compatible)" {
    echo "don't mock the database — we were burned by it." | \
        python3 "$DISTILLER" >/dev/null 2>&1
    valid_from=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
row = conn.execute('SELECT valid_from FROM agent_memories LIMIT 1').fetchone()
print('set' if row and row[0] is not None else 'null')
conn.close()
")
    [ "$valid_from" = "set" ]
}

@test "distiller: inserted row has valid_to = NULL (not invalidated)" {
    echo "don't mock the database — we were burned by it." | \
        python3 "$DISTILLER" >/dev/null 2>&1
    valid_to=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
row = conn.execute('SELECT valid_to FROM agent_memories LIMIT 1').fetchone()
print('null' if row and row[0] is None else 'set')
conn.close()
")
    [ "$valid_to" = "null" ]
}
