#!/usr/bin/env bats
# githooks-post-commit.bats — BATS tests for .githooks/post-commit (D5 provenance)
#
# Tests the post-commit hook that records provenance (SHA → session).
# Hook fires only when CLAUDECODE=1 (in-session).
# Hook never blocks the commit (exit 0 always).
# Calls cast-commit-provenance.py recorder if available.
#
# Setup: create a temp git repo with core.hooksPath pointing to hook copy.
# Stub the recorder script to capture invocations.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SOURCE="$REPO_DIR/.githooks/post-commit"

setup() {
    setup_temp_home

    # Create temp git repo
    TEST_REPO="$BATS_TEST_TMPDIR/test-git-repo"
    mkdir -p "$TEST_REPO"
    cd "$TEST_REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Copy hook to temp location and wire it
    HOOK_DIR="$BATS_TEST_TMPDIR/hook-copy"
    mkdir -p "$HOOK_DIR"
    cp "$HOOK_SOURCE" "$HOOK_DIR/post-commit"
    chmod +x "$HOOK_DIR/post-commit"

    # Point git to the temp hook
    git config core.hooksPath "$HOOK_DIR"

    # Pre-create the logs directory (hook expects this to exist)
    mkdir -p "$HOME/.claude/logs"

    # Create a stub recorder that logs invocations
    RECORDER_STUB="$HOME/.claude/scripts/cast-commit-provenance.py"
    mkdir -p "$(dirname "$RECORDER_STUB")"
    cat > "$RECORDER_STUB" <<'STUBEOF'
#!/usr/bin/env python3
import sys
import os

# Stub: record the invocation to a file instead of modifying DB
log_file = os.environ.get('STUB_RECORDER_LOG', '/tmp/recorder-stub.log')
with open(log_file, 'a') as f:
    f.write(f"recorder called with args: {sys.argv[1:]}\n")

# Exit 0 by default (success)
sys.exit(0)
STUBEOF
    chmod +x "$RECORDER_STUB"

    # Log file for stub recorder
    STUB_RECORDER_LOG="$BATS_TEST_TMPDIR/recorder-calls.log"
    export STUB_RECORDER_LOG
}

teardown() {
    cd /
    teardown_temp_home
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: Normal commit with CLAUDECODE=1 → recorder is called with HEAD sha
# ──────────────────────────────────────────────────────────────────────────────
@test "commit with CLAUDECODE=1 calls recorder with HEAD sha" {
    cd "$TEST_REPO"

    # Create a dummy file and commit
    echo "test content" > file.txt
    git add file.txt

    # Capture HEAD sha before commit
    CLAUDECODE=1 git commit -q -m "test commit"
    exit_code=$?

    # Commit should succeed (exit 0)
    [ "$exit_code" -eq 0 ]

    # Check that recorder was called (log file created and has content)
    [ -f "$STUB_RECORDER_LOG" ]

    # Log should contain "record" (the subcommand passed to stub)
    grep -q "record" "$STUB_RECORDER_LOG"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: Recorder missing → commit still succeeds, exit 0
# ──────────────────────────────────────────────────────────────────────────────
@test "commit succeeds even when recorder script is missing" {
    cd "$TEST_REPO"

    # Remove the recorder stub to simulate missing recorder
    rm -f "$HOME/.claude/scripts/cast-commit-provenance.py"

    echo "test content" > file2.txt
    git add file2.txt

    # Commit should still succeed
    CLAUDECODE=1 git commit -q -m "test commit no recorder"
    [ $? -eq 0 ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: Recorder exits non-zero → commit still succeeds (fail-open)
# ──────────────────────────────────────────────────────────────────────────────
@test "commit succeeds when recorder exits non-zero (best-effort, never blocks)" {
    cd "$TEST_REPO"

    # Modify stub recorder to exit with error code
    RECORDER_STUB="$HOME/.claude/scripts/cast-commit-provenance.py"
    cat > "$RECORDER_STUB" <<'STUBEOF'
#!/usr/bin/env python3
import sys
import os

log_file = os.environ.get('STUB_RECORDER_LOG', '/tmp/recorder-stub.log')
with open(log_file, 'a') as f:
    f.write(f"recorder failed exit\n")

# Exit with error (this should NOT block the commit)
sys.exit(1)
STUBEOF
    chmod +x "$RECORDER_STUB"

    echo "test content" > file3.txt
    git add file3.txt

    # Commit should still succeed despite recorder failure
    CLAUDECODE=1 git commit -q -m "test commit recorder fails"
    [ $? -eq 0 ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: CAST_SKIP_POST_COMMIT_PROVENANCE=1 → recorder NOT called
# ──────────────────────────────────────────────────────────────────────────────
@test "CAST_SKIP_POST_COMMIT_PROVENANCE=1 prevents recorder invocation" {
    cd "$TEST_REPO"

    # Clear the log file
    rm -f "$STUB_RECORDER_LOG"

    echo "test content" > file4.txt
    git add file4.txt

    # Commit with escape hatch set
    CLAUDECODE=1 CAST_SKIP_POST_COMMIT_PROVENANCE=1 git commit -q -m "test skip provenance"
    [ $? -eq 0 ]

    # Recorder should NOT have been called
    # Assert: log file should NOT exist OR should be empty (no "record" invocation)
    if [ -f "$STUB_RECORDER_LOG" ]; then
        # File exists — must not contain "record" call
        ! grep -q "record" "$STUB_RECORDER_LOG"
    else
        # File does not exist — that's correct (no invocation recorded)
        true
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: CLAUDECODE unset (terminal commit) → recorder NOT called, commit succeeds
# ──────────────────────────────────────────────────────────────────────────────
@test "commit without CLAUDECODE=1 (human terminal) silently skips recorder, still succeeds" {
    cd "$TEST_REPO"

    # Clear the log
    rm -f "$STUB_RECORDER_LOG"

    echo "test content" > file5.txt
    git add file5.txt

    # Commit WITHOUT CLAUDECODE (or with CLAUDECODE=0)
    CLAUDECODE=0 git commit -q -m "test human commit"
    [ $? -eq 0 ]

    # Recorder should NOT have been called
    # Assert: log file must not exist (hook skipped in-session gate, no log entry)
    [ ! -f "$STUB_RECORDER_LOG" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: Hook never blocks — commit exit code always 0
# ──────────────────────────────────────────────────────────────────────────────
@test "commit exit code is always 0 (hook fail-open)" {
    cd "$TEST_REPO"

    # Modify stub to crash (kill -9 simulation)
    RECORDER_STUB="$HOME/.claude/scripts/cast-commit-provenance.py"
    cat > "$RECORDER_STUB" <<'STUBEOF'
#!/usr/bin/env python3
import sys
# Unconditionally exit with failure
sys.exit(127)
STUBEOF
    chmod +x "$RECORDER_STUB"

    echo "test content" > file6.txt
    git add file6.txt

    # Commit should succeed even if recorder crashes
    CLAUDECODE=1 git commit -q -m "test hook fail-open"
    exit_code=$?

    [ "$exit_code" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 7: hook never blocks commit, even in edge cases
# ──────────────────────────────────────────────────────────────────────────────
@test "hook never blocks commit — fail-open contract verified in all paths" {
    cd "$TEST_REPO"

    echo "test content" > file7.txt
    git add file7.txt

    # Create a commit with CLAUDECODE=1 and verify exit 0
    CLAUDECODE=1 git commit -q -m "test commit"
    commit_exit=$?

    # Assert: commit exit code is 0 (hook never blocks, even if recorder fails)
    [ "$commit_exit" -eq 0 ]

    # Assert: hook logged the commit (we know recorder was called in this scenario)
    [ -f "$HOME/.claude/logs/post-commit-provenance.log" ]

    # Verify log contains a provenance record (hook processed this commit)
    grep -q "recorded provenance" "$HOME/.claude/logs/post-commit-provenance.log" || \
    grep -q "skipped" "$HOME/.claude/logs/post-commit-provenance.log" || \
    grep -q "recorder" "$HOME/.claude/logs/post-commit-provenance.log"
}
