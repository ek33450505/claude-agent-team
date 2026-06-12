#!/usr/bin/env bats
# cast-db-allowlist.bats — Tests for cast_db.py allowlist + bool return contracts
#
# Coverage:
#   1. CAST_DB_PATH under mktemp -d (macOS /var/folders path) is ACCEPTED and row persists
#   2. CAST_DB_PATH outside allowlist (/etc/...) → db_write returns False, nothing written
#   3. db_write returns truthy on success, falsy on disallowed path

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_DB_PY="$REPO_DIR/scripts/cast_db.py"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude/logs"

  # Create a temp dir via mktemp (may resolve to /var/folders/... on macOS)
  export TEST_TMPDIR="$(mktemp -d)"
  export TEST_DB="$TEST_TMPDIR/cast-allowlist-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Initialize schema so INSERT can succeed
  bash "$DB_INIT_SH" --db "$TEST_DB" >/dev/null 2>&1 || true
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  teardown_temp_home
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# 1. Regression: CAST_DB_PATH under mktemp -d is accepted and row persists
# ---------------------------------------------------------------------------

@test "allowlist: CAST_DB_PATH under mktemp -d is accepted and row persists" {
  # This is the regression test for the macOS /var/folders bug:
  # mktemp -d on macOS returns /var/folders/... which is NOT in the old static allowlist.
  run python3 - <<PYEOF
import sys, os
sys.path.insert(0, '$REPO_DIR/scripts')
os.environ['CAST_DB_PATH'] = '$TEST_DB'
from cast_db import db_write
result = db_write('agent_memories', {
    'agent': 'test-agent',
    'type': 'feedback',
    'name': 'allowlist-regression-test',
    'description': 'regression test for mktemp path',
    'content': 'allowlist regression content',
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
})
print('ok' if result else 'fail')
PYEOF
  assert_success
  assert_output "ok"

  # Verify the row was actually written
  local count
  count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_memories WHERE name='allowlist-regression-test';" 2>/dev/null)"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 2. Security: path outside allowlist is rejected, nothing written
# ---------------------------------------------------------------------------

@test "allowlist: CAST_DB_PATH outside allowlist returns False, nothing written" {
  # /etc/cast-evil.db must NOT be accepted
  run python3 - <<PYEOF
import sys, os
sys.path.insert(0, '$REPO_DIR/scripts')
os.environ['CAST_DB_PATH'] = '/etc/cast-evil.db'
from cast_db import db_write
try:
    result = db_write('agent_memories', {
        'agent': 'attacker',
        'type': 'feedback',
        'name': 'evil',
        'description': 'evil',
        'content': 'evil content',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
    })
    print('false' if not result else 'true')
except ValueError:
    print('false')
except Exception as e:
    print('false')
PYEOF
  assert_success
  assert_output "false"

  # Confirm the file was not created at /etc
  [ ! -f "/etc/cast-evil.db" ]
}

# ---------------------------------------------------------------------------
# 3. Return contract: db_write truthy on success, falsy on disallowed path
# ---------------------------------------------------------------------------

@test "allowlist: managed_agent_invocations is in ALLOWED_TABLES and db_write succeeds" {
  # Regression: managed_agent_invocations was written by cast-managed-agent.sh but not
  # in ALLOWED_TABLES, so writes silently no-op'd. Verify it is now allowlisted and
  # a db_write to a temp schema-initialized DB succeeds.
  run python3 - <<PYEOF
import sys, os
sys.path.insert(0, '$REPO_DIR/scripts')
os.environ['CAST_DB_PATH'] = '$TEST_DB'
from cast_db import ALLOWED_TABLES, db_write
if 'managed_agent_invocations' not in ALLOWED_TABLES:
    print('FAIL: not in ALLOWED_TABLES')
    sys.exit(1)
result = db_write('managed_agent_invocations', {
    'id': 'test-mai-1',
    'agent_name': 'test-agent',
    'ts': '2026-01-01T00:00:00Z',
})
print('ok' if result else 'fail')
PYEOF
  assert_success
  assert_output "ok"
}

@test "allowlist: db_write returns truthy on success, falsy on disallowed path" {
  run python3 - <<PYEOF
import sys, os
sys.path.insert(0, '$REPO_DIR/scripts')

# Success case
os.environ['CAST_DB_PATH'] = '$TEST_DB'
from cast_db import db_write
ok = db_write('agent_memories', {
    'agent': 'test-agent',
    'type': 'feedback',
    'name': 'return-contract-test',
    'description': 'return contract test',
    'content': 'return contract content unique xyz789',
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
})
if not ok:
    print('FAIL: success case returned falsy')
    sys.exit(1)

# Failure case — disallowed path
import importlib
os.environ['CAST_DB_PATH'] = '/etc/cast-evil.db'
import cast_db
importlib.reload(cast_db)
try:
    fail = cast_db.db_write('agent_memories', {
        'agent': 'test-agent',
        'type': 'feedback',
        'name': 'should-fail',
        'description': 'should fail',
        'content': 'should not persist',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
    })
    if fail:
        print('FAIL: disallowed path returned truthy')
        sys.exit(1)
except Exception:
    pass  # ValueError is also acceptable

print('ok')
PYEOF
  assert_success
  assert_output "ok"
}
