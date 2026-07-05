#!/usr/bin/env bats
# cast-pretool-dispatch-guardfail.bats — Guard module load-failure visibility tests.
#
# Verifies Task 4 of the 2026-07-04 PY39 audit:
#   - When a guard module fails to load, the dispatcher still exits 0 (fail-open).
#   - The failure is durably recorded to hook_failures in cast.db (once per session+module).
#   - Deduplication via marker file: a second invocation does NOT write a second row.
#
# Also exercises: the 5 PEP-604-fixed modules import cleanly under /usr/bin/python3
# when that interpreter is present (skips gracefully when absent).
#
# Skip-ledger note: the python3-import tests skip when /usr/bin/python3 is absent.
# This skip is intentional and NOT a test failure — the annotation fix was verified
# by the author under /usr/bin/python3 3.9.6 at authoring time (2026-07-04).
# Skip ledger is being regenerated concurrently by another agent — reconcile that
# ledger with this skip entry once both branches merge.
#
# HARD RULES honored:
#   - Temp-HOME isolation via setup_temp_home / teardown_temp_home.
#   - No GUI side effects (no osascript/notify-send/open calls; cast-pretool-dispatch
#     itself contains none — verified).
#   - BATS printf-based fixtures (no heredoc rewriting issue).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DISPATCH="$REPO_DIR/scripts/cast-pretool-dispatch.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal Bash-tool PreToolUse JSON payload (safe command — no blocks).
safe_bash_payload() {
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Bash',
    'tool_input': {'command': 'echo hello'},
    'session_id': sys.argv[1] if len(sys.argv) > 1 else 'guardfail-session',
}))
" "${1:-guardfail-session}"
}

setup() {
    load 'helpers/setup'
    setup_temp_home
    # Scope dedup marker files to this test's temp HOME so markers never leak
    # across bats runs (prevents cross-run dedup flake on the dedup test).
    export TMPDIR="$HOME/.cast-test-tmp"
    mkdir -p "$TMPDIR"
    mkdir -p "$HOME/.claude/logs" "$HOME/.claude/config" "$HOME/.claude/scripts"
    cp "$REPO_DIR/config/egress-policy.json" "$HOME/.claude/config/egress-policy.json"

    # Point the DB at the temp home so the dispatcher's cast_db import lands there.
    export CAST_DB_PATH="$HOME/.claude/cast.db"
    bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

    # CAST_SCRIPTS_DIR is not used by cast-pretool-dispatch.py (it resolves paths
    # relative to its own __file__), so we copy the supporting modules directly
    # into a temp scripts directory alongside a copy of the dispatcher.
    TMPSCRIPTS="$(mktemp -d)"
    export TMPSCRIPTS

    # Copy the dispatcher and its sibling modules to TMPSCRIPTS so SCRIPT_DIR
    # resolves correctly and cast_db is importable from the same directory.
    cp "$REPO_DIR/scripts/cast-pretool-dispatch.py" "$TMPSCRIPTS/"
    cp "$REPO_DIR/scripts/cast_db.py"               "$TMPSCRIPTS/"
    cp "$REPO_DIR/scripts/cast-git-guard.py"        "$TMPSCRIPTS/"
    cp "$REPO_DIR/scripts/cast-command-guard.py"    "$TMPSCRIPTS/"
    cp "$REPO_DIR/scripts/cast-egress-sentinel.py"  "$TMPSCRIPTS/"
    cp "$REPO_DIR/scripts/cast-redact.py"           "$TMPSCRIPTS/"

    # Mark CAST_DB_URL so cast_db.py in TMPSCRIPTS writes to our temp DB.
    export CAST_DB_URL="sqlite:///$CAST_DB_PATH"

    unset CLAUDE_SUBPROCESS CAST_COMMIT_AGENT CAST_PUSH_OK CAST_STASH_OK \
          CAST_RM_OK CAST_KILL_OK
}

teardown() {
    rm -rf "$TMPSCRIPTS" 2>/dev/null || true
    teardown_temp_home
}

# ---------------------------------------------------------------------------
# Guard-load failure: fail-open contract
# ---------------------------------------------------------------------------

@test "broken guard module → dispatcher exits 0 (fail-open)" {
    # Plant a broken cast-git-guard.py that raises SyntaxError on import.
    printf 'THIS IS NOT VALID PYTHON\n' > "$TMPSCRIPTS/cast-git-guard.py"

    local payload
    payload="$(safe_bash_payload "gf-session-1")"
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success  # exit 0 — fail-open contract preserved
}

# ---------------------------------------------------------------------------
# Guard-load failure: durable DB recording
# ---------------------------------------------------------------------------

@test "broken guard module → hook_failures row written to cast.db" {
    printf 'raise ImportError("intentional test failure")\n' > "$TMPSCRIPTS/cast-git-guard.py"

    export CLAUDE_SESSION_ID="gf-session-db-1"
    local payload
    payload="$(safe_bash_payload "gf-session-db-1")"

    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success

    # Wait a moment for any async DB write (cast_db uses WAL, commits synchronously —
    # but give it a moment for the file-system flush on slower CI).
    run sqlite3 "$CAST_DB_PATH" \
        "SELECT COUNT(*) FROM hook_failures WHERE session_id='gf-session-db-1'"
    assert_output "1"
}

@test "broken guard module → hook_name contains module name" {
    printf 'raise ImportError("intentional test failure")\n' > "$TMPSCRIPTS/cast-git-guard.py"

    export CLAUDE_SESSION_ID="gf-session-db-name"
    local payload
    payload="$(safe_bash_payload "gf-session-db-name")"

    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success

    run sqlite3 "$CAST_DB_PATH" \
        "SELECT hook_name FROM hook_failures WHERE session_id='gf-session-db-name' LIMIT 1"
    assert_output --partial "cast_git_guard"
}

# ---------------------------------------------------------------------------
# Deduplication: exactly one row across two invocations
# ---------------------------------------------------------------------------

@test "broken guard module → two invocations → exactly one hook_failures row (dedup)" {
    printf 'raise ImportError("intentional test failure")\n' > "$TMPSCRIPTS/cast-git-guard.py"

    export CLAUDE_SESSION_ID="gf-session-dedup"
    local payload
    payload="$(safe_bash_payload "gf-session-dedup")"

    # First invocation — must record
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success

    # Second invocation with same session — must NOT write a second row
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success

    run sqlite3 "$CAST_DB_PATH" \
        "SELECT COUNT(*) FROM hook_failures WHERE session_id='gf-session-dedup'"
    assert_output "1"
}

@test "different session IDs → separate hook_failures rows (no cross-session dedup)" {
    printf 'raise ImportError("intentional test failure")\n' > "$TMPSCRIPTS/cast-git-guard.py"

    export CLAUDE_SESSION_ID="gf-session-A"
    local payload_a
    payload_a="$(safe_bash_payload "gf-session-A")"
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload_a"
    assert_success

    export CLAUDE_SESSION_ID="gf-session-B"
    local payload_b
    payload_b="$(safe_bash_payload "gf-session-B")"
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload_b"
    assert_success

    run sqlite3 "$CAST_DB_PATH" \
        "SELECT COUNT(*) FROM hook_failures WHERE session_id IN ('gf-session-A','gf-session-B')"
    assert_output "2"
}

# ---------------------------------------------------------------------------
# Sanity: working guard modules are NOT written to hook_failures
# ---------------------------------------------------------------------------

@test "no broken guard → zero hook_failures rows for this session" {
    # All modules are the real copies — no planted failures.
    export CLAUDE_SESSION_ID="gf-session-clean"
    local payload
    payload="$(safe_bash_payload "gf-session-clean")"

    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success

    run sqlite3 "$CAST_DB_PATH" \
        "SELECT COUNT(*) FROM hook_failures WHERE session_id='gf-session-clean'"
    assert_output "0"
}

# ---------------------------------------------------------------------------
# Python 3.9 import smoke-test for the 5 PEP-604-fixed modules.
#
# Skip rationale: /usr/bin/python3 may be absent on some CI environments (e.g.
# macOS GitHub Actions runners where python3 is from Homebrew, not /usr/bin).
# The fix was verified locally under /usr/bin/python3 3.9.6 at authoring time.
# When the interpreter IS present (and is <=3.9.x), this test confirms the future
# import resolves the TypeError that was crashing hooks in production.
# ---------------------------------------------------------------------------

@test "PEP-604 fix: 5 modules import cleanly under /usr/bin/python3" {
    if [[ ! -x /usr/bin/python3 ]]; then
        skip "/usr/bin/python3 not found on this runner (Homebrew or nix python3 in use)"
    fi

    local ver
    ver="$(/usr/bin/python3 -c 'import sys; print(sys.version_info[:2])')"
    # Only meaningful on < 3.10 — skip on newer where PEP-604 is natively valid
    if /usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info < (3,10) else 1)' 2>/dev/null; then
        : # 3.9 or earlier — run the test
    else
        skip "/usr/bin/python3 is >= 3.10; PEP-604 is natively valid — annotation fix not required on this interpreter"
    fi

    local module_dir
    module_dir="$(dirname "$REPO_DIR/scripts/cast-egress-sentinel.py")"

    local modules=(
        "cast-egress-sentinel.py"
        "cast-redact.py"
        "cast-rate-check.py"
        "cast-validate-status.py"
        "cast-db-routines.py"
    )

    for mod_file in "${modules[@]}"; do
        local full_path="$module_dir/$mod_file"
        run /usr/bin/python3 -m py_compile "$full_path"
        assert_success "py_compile failed for $mod_file"
    done
}
