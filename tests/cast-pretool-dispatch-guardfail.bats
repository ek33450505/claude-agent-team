#!/usr/bin/env bats
# cast-pretool-dispatch-guardfail.bats — Guard module load-failure visibility tests.
#
# Verifies Task 4 of the 2026-07-04 PY39 audit:
#   - When a guard module fails to load, the dispatcher still exits 0 (fail-open) for a
#     safe command. EXCEPTION (2026-10-06): the git guard module fails CLOSED for
#     Write/Edit and for a coarse list of irreversible git Bash verbs (see the section
#     further down).
#   - The failure is durably recorded to hook_failures in cast.db (once per session+module).
#   - Deduplication via the hook_failures row itself: a second invocation does NOT write a second row.
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
    # Dedup is on the hook_failures table itself (no marker file anywhere), so the temp
    # CAST_DB_PATH alone scopes it (no cross-run dedup flake). Simulate the sandbox that
    # once made gettempdir() fall back to the cwd: TMPDIR/TEMP/TMP unset and a scratch
    # cwd; the dedup test asserts no cast-pretool-guard* file appears in it, in HOME, or
    # in /tmp.
    unset TMPDIR TEMP TMP
    PROBE_CWD="$HOME/cwd-probe"
    export PROBE_CWD
    mkdir -p "$PROBE_CWD"
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
          CAST_RM_OK CAST_KILL_OK CAST_POLICY_OVERRIDE CAST_RESET_OK \
          CAST_CLEAN_OK CAST_CHECKOUT_OK CAST_RESTORE_OK CAST_BRANCH_OK
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
    cd "$PROBE_CWD"
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success

    # Second invocation with same session — must NOT write a second row
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$payload"
    assert_success

    run sqlite3 "$CAST_DB_PATH" \
        "SELECT COUNT(*) FROM hook_failures WHERE session_id='gf-session-dedup'"
    assert_output "1"

    # Deduped by the DB row alone: no marker file in the cwd, anywhere under HOME, or
    # in the system tmp dir.
    run ls -A "$PROBE_CWD"
    assert_output ""
    run find "$HOME" -name 'cast-pretool-guard*'
    assert_output ""
    run compgen -G "/tmp/cast-pretool-guard-gf-session-dedup-*"
    assert_failure
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
# Guard-load failure is FAIL-CLOSED for the irreversible surfaces (Ed decision,
# 2026-10-06). Write/Edit: blocked unless CAST_POLICY_OVERRIDE=1. Bash: a coarse
# list of irreversible git verbs is blocked in degraded mode (each honouring its
# normal hatch); everything else stays allowed so the install can be repaired.
# The safe-Bash fail-open tests above stay green: a non-git command still runs.
# ---------------------------------------------------------------------------

break_git_guard() {
    printf 'raise ImportError("intentional test failure")\n' > "$TMPSCRIPTS/cast-git-guard.py"
}

# tool_payload <tool> <tool_input key> <value> -> PreToolUse JSON via json.dumps.
tool_payload() {
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': sys.argv[1],
    'tool_input': {sys.argv[2]: sys.argv[3]},
    'session_id': 'gf-degraded',
}))
" "$1" "$2" "$3"
}

run_dispatch() {
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" <<< "$1"
}

# bash_exit <expected exit code> <command>: dispatch a Bash payload, diagnose a mismatch.
bash_exit() {
    local expected="$1" cmd="$2"
    run_dispatch "$(tool_payload Bash command "$cmd")"
    if [ "$status" -ne "$expected" ]; then
        echo "command [$cmd] exited $status, wanted $expected: $output" >&2
        return 1
    fi
}

@test "control: healthy guard allows the Write payload the broken-guard tests block" {
    run_dispatch "$(tool_payload Write file_path "$HOME/work/notes.txt")"
    assert_success
}

@test "broken guard + Write → blocked (exit 2), names the load failure and the override" {
    break_git_guard
    run_dispatch "$(tool_payload Write file_path "$HOME/work/notes.txt")"
    assert_failure 2
    assert_output --partial "failed to load"
    assert_output --partial "CAST_POLICY_OVERRIDE"
    assert_output --partial "cast-git-guard.py"
}

@test "broken guard + Edit → blocked (exit 2), names the load failure and the override" {
    break_git_guard
    run_dispatch "$(tool_payload Edit file_path "$HOME/work/notes.txt")"
    assert_failure 2
    assert_output --partial "failed to load"
    assert_output --partial "CAST_POLICY_OVERRIDE"
}

@test "broken guard + Write block reason carries no path and no exception text" {
    break_git_guard
    run_dispatch "$(tool_payload Write file_path "$HOME/work/secret-notes.txt")"
    assert_failure 2
    refute_output --partial "secret-notes"
    refute_output --partial "intentional test failure"
}

@test "broken guard + Write + CAST_POLICY_OVERRIDE=1 → allowed, content-free audit line logged" {
    break_git_guard
    export CAST_POLICY_OVERRIDE=1
    run_dispatch "$(tool_payload Write file_path "$HOME/work/secret-notes.txt")"
    assert_success
    run grep -c "override used while guard unavailable" "$HOME/.claude/logs/hook-errors.log"
    assert_output "1"
    run grep -c "secret-notes" "$HOME/.claude/logs/hook-errors.log"
    assert_output "0"
}

@test "broken guard + Write under CLAUDE_SUBPROCESS=1 → still skipped (exit 0)" {
    break_git_guard
    export CLAUDE_SUBPROCESS=1
    run_dispatch "$(tool_payload Write file_path "$HOME/work/notes.txt")"
    assert_success
}

@test "broken guard + Bash → irreversible git verbs blocked in degraded mode" {
    break_git_guard
    local g="git" c
    for c in \
        "$g commit -m x" \
        "$g -C /tmp push" \
        "$g -c k=v push" \
        "/usr/bin/$g commit -m x" \
        "command $g push" \
        "env X=1 $g commit -m x" \
        "echo hi && $g reset --hard" \
        "echo hi ; $g reset --soft HEAD~1" \
        "($g commit -m x)" \
        "echo \$($g push)" \
        "echo \`$g stash\`" \
        "bash -c '$g push'" \
        "\"$g\" commit -m x" \
        "$g \\
commit -m x" \
        "$g clean -fd" \
        "$g stash" \
        "$g checkout main" \
        "$g restore f.txt" \
        "$g branch -D foo" \
        "$g branch --delete --force foo" \
        "$g branch --del --for foo" \
        "$g branch -df foo" \
        "$g branch -fd foo" \
        "$g branch -d -f foo"; do
        bash_exit 2 "$c"
    done
}

@test "broken guard + Bash block message names the verb, the hatch and the repair" {
    break_git_guard
    bash_exit 2 "git commit -m x"
    assert_output --partial "git guard module failed to load"
    assert_output --partial "git commit is blocked in degraded mode"
    assert_output --partial "CAST_COMMIT_AGENT=1"
    assert_output --partial "bash install.sh"
    bash_exit 2 "git -C /tmp push"
    assert_output --partial "git push is blocked"
    assert_output --partial "CAST_PUSH_OK=1"
}

@test "broken guard + Bash → each verb's own hatch token allows it" {
    break_git_guard
    bash_exit 0 "CAST_COMMIT_AGENT=1 git commit -m x"
    bash_exit 0 "CAST_PUSH_OK=1 git push"
    bash_exit 0 "CAST_RESET_OK=1 git reset --hard"
    bash_exit 0 "CAST_CLEAN_OK=1 git clean -fd"
    bash_exit 0 "CAST_STASH_OK=1 git stash"
    bash_exit 0 "CAST_CHECKOUT_OK=1 git checkout main"
    bash_exit 0 "CAST_RESTORE_OK=1 git restore f.txt"
    bash_exit 0 "CAST_BRANCH_OK=1 git branch -D foo"
}

@test "broken guard + Bash → a hatch for one verb does not allow another" {
    break_git_guard
    bash_exit 2 "CAST_COMMIT_AGENT=1 git commit -m x && git push"
    bash_exit 2 "CAST_PUSH_OK=1 git reset --hard"
}

@test "broken guard + Bash → everything else is allowed so install.sh can repair" {
    break_git_guard
    local c
    for c in \
        "git status" \
        "git rebase main" \
        "git merge feature" \
        "git branch -d foo" \
        "git branch --list" \
        "git log --oneline | head -5" \
        "git diff HEAD~1" \
        "git add -A" \
        "ls -la" \
        "cd r && git status && bash install.sh" \
        "bash install.sh"; do
        bash_exit 0 "$c"
    done
}

@test "broken guard + Bash under CLAUDE_SUBPROCESS=1 → degraded block applies in EVERY context" {
    break_git_guard
    export CLAUDE_SUBPROCESS=1
    bash_exit 2 "git push"
    bash_exit 0 "git status"
}

@test "broken guard + 200 KB Bash command → linear: scanned to the end, well under 2 s" {
    break_git_guard
    # The 200 KB prefix is ~28k segments; only the LAST one decides the verdict, so a pass
    # proves the whole command was scanned (not truncated) and quickly (no quadratic regex).
    run python3 -c '
import json, subprocess, sys, time
for tail, want in (("git status", 0), ("git push", 2)):
    cmd = "echo a;" * 28600 + tail
    assert len(cmd) >= 200000
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "gf-big"})
    t0 = time.monotonic()
    p = subprocess.run([sys.executable, sys.argv[1]], input=payload.encode(), capture_output=True)
    elapsed = time.monotonic() - t0
    print(tail, p.returncode, round(elapsed, 2))
    if p.returncode != want or elapsed >= 2.0:
        sys.exit(1)
' "$TMPSCRIPTS/cast-pretool-dispatch.py"
    assert_success
}

# A guard module that LOADS but whose evaluate() RAISES did not run either: Bash falls
# back to the same coarse degraded-mode block (class-only logging), not a blanket allow.
break_git_guard_evaluate() {
    printf 'def evaluate(*a, **k):\n    raise RuntimeError("intentional evaluate failure")\n' \
        > "$TMPSCRIPTS/cast-git-guard.py"
}

@test "guard loads but evaluate() raises + Bash → git push blocked (2), git status allowed (0)" {
    break_git_guard_evaluate
    bash_exit 2 "git push"
    assert_output --partial "git guard module failed while checking this command"
    assert_output --partial "git push is blocked in degraded mode"
    assert_output --partial "CAST_PUSH_OK=1"
    refute_output --partial "intentional evaluate failure"
    bash_exit 0 "git status"
    bash_exit 0 "CAST_PUSH_OK=1 git push"
}

@test "guard loads but evaluate() raises + Bash → logs the exception CLASS only" {
    break_git_guard_evaluate
    bash_exit 2 "git push"
    run grep -c "evaluate() raised RuntimeError" "$HOME/.claude/logs/hook-errors.log"
    assert_output "1"
    run grep -c "intentional evaluate failure" "$HOME/.claude/logs/hook-errors.log"
    assert_output "0"
}

# A guard that LOADS but whose evaluate() runs far past the hook budget (a super-linear scan:
# ~100 KB of repeated `git ` tokens took ~15 s before the 2026-10-06 regex fix). The hook
# timeout is 5 s and a hook TIMEOUT is a non-blocking error -- an ALLOW -- so the dispatcher
# runs evaluate() under a SIGALRM watchdog (_GIT_GUARD_BUDGET_SECS = 2 s) and, on expiry, falls
# back to the degraded git block: fail CLOSED.
break_git_guard_slow() {
    printf 'import time\ndef evaluate(*a, **k):\n    time.sleep(10)\n    return 0, ""\n' \
        > "$TMPSCRIPTS/cast-git-guard.py"
}

# slow_guard_dispatch <python> <command> <want exit> <stderr substring> [max seconds, default 4]: dispatch one Bash
# payload through the slow guard. Passes only if the exit code matches, stderr contains the
# substring, and the hook returned in < 4 s (budget 2 s + startup, well inside the 5 s hook
# timeout; 4.5 s where the 3.5 s total Bash-guard budget applies). The run is bounded at 8 s and subprocess.run reaps the child on timeout, so a
# missing watchdog FAILS the test (the guard sleeps 10 s) instead of hanging it, and nothing
# is left behind holding bats' fds 3/4.
slow_guard_dispatch() {
    python3 -c '
import json, subprocess, sys, time
py, script, cmd, want, needle = sys.argv[1:6]
maxsec = float(sys.argv[6])
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "gf-slow"})
t0 = time.monotonic()
try:
    p = subprocess.run([py, script], input=payload.encode(), capture_output=True, timeout=8)
except subprocess.TimeoutExpired:
    print("TIMEOUT (> 8 s): no watchdog -- the slow guard ran to completion")
    sys.exit(1)
elapsed = time.monotonic() - t0
err = p.stderr.decode()
print(py, repr(cmd), "exit", p.returncode, "in", round(elapsed, 2), "s")
if p.returncode != int(want) or needle not in err or elapsed >= maxsec:
    print("wanted exit", want, "with", repr(needle), "in <", maxsec, "s; stderr:", err[:300])
    sys.exit(1)
' "$1" "$TMPSCRIPTS/cast-pretool-dispatch.py" "$2" "$3" "$4" "${5:-4.0}"
}

# Run under the default python3 and, when present, /usr/bin/python3 (3.9 on macOS): SIGALRM
# must interrupt the slow path on both. No skip: an absent system python is simply not
# exercised (a new skip call site would also need a skip-ledger entry).
@test "slow guard + Bash → git push blocked (2) within 4 s, naming the timeout" {
    break_git_guard_slow
    run slow_guard_dispatch python3 "git push origin main" 2 "could not finish checking this command within 2s"
    assert_success
    if [[ -x /usr/bin/python3 ]]; then
        run slow_guard_dispatch /usr/bin/python3 "git push origin main" 2 "could not finish checking this command within 2s"
        assert_success
    fi
}

# Security round 1 (H1): on a TIMEOUT the guard decided nothing, so EVERY command that names git
# is blocked -- not only the 8 verbs of the load-failure degraded table. A command that never
# names git stays allowed by the git guard.
@test "slow guard + Bash → ANY git-naming command is blocked (2), including verbs the degraded table lacks" {
    break_git_guard_slow
    local g="git" c
    for c in "$g status" "$g filter-branch --index-filter x" "$g update-ref -d refs/heads/x" \
             "$g reflog expire --expire=now --all" "$g gc --prune=now" \
             "$g worktree remove --force w" "$g switch -f main" "$g -c gc.pruneExpire=now gc" \
             "GIT push" "\$'$g' push" "g\\it push" "/usr/bin/$g push" "x;$g push" \
             $'g\\\nit push' $'g\\\r\nit push' $'G\\\nIT push' "g\$''it push"; do
        run slow_guard_dispatch python3 "$c" 2 "could not finish checking this command within 2s"
        if [ "$status" -ne 0 ]; then
            echo "command [$c]: $output" >&2
            return 1
        fi
    done
}

@test "slow guard + Bash → a command that never names git is still allowed (0) within 4 s" {
    break_git_guard_slow
    run slow_guard_dispatch python3 "echo hello" 0 ""
    assert_success
    if [[ -x /usr/bin/python3 ]]; then
        run slow_guard_dispatch /usr/bin/python3 "echo hello" 0 ""
        assert_success
    fi
}

# Security round 1 (M2): no hatch, in any position, unblocks a command whose scan timed out.
@test "slow guard + Bash → hatches are IGNORED on a timeout (anywhere in the command)" {
    break_git_guard_slow
    local g="git" c
    for c in "CAST_PUSH_OK=1 $g push origin main" "echo CAST_PUSH_OK=1; $g push origin main" \
             "$g push origin main # CAST_PUSH_OK=1" "CAST_COMMIT_AGENT=1 $g commit -m x"; do
        run slow_guard_dispatch python3 "$c" 2 "could not finish checking this command within 2s"
        if [ "$status" -ne 0 ]; then
            echo "command [$c]: $output" >&2
            return 1
        fi
    done
}

@test "slow guard + Bash → the timeout is logged with the budget, never the command" {
    break_git_guard_slow
    run slow_guard_dispatch python3 "git push origin SENTINEL-branch-7f3a" 2 "could not finish checking this command"
    assert_success
    run grep -c "Bash git guard timed out after 2s; blocking any command that names git" "$HOME/.claude/logs/hook-errors.log"
    assert_output "1"
    run grep -c "SENTINEL-branch-7f3a" "$HOME/.claude/logs/hook-errors.log"
    assert_output "0"
}

# Security round 1 (H1 cheap trigger): ~500 hatched segments (13 KB) used to spawn one
# `git rev-parse` EACH from the audit hooks, ran the REAL guard past its 2 s budget, and a
# trailing filter-branch (absent from the degraded table) was ALLOWED. Memoised, the real guard
# decides it in well under a second.
@test "real guard + 500 hatched pushes then filter-branch → blocked (2) well inside the budget" {
    run python3 -c '
import json, subprocess, sys, time
g = "gi" + "t"
cmd = ("CAST_PUSH_OK=1 " + g + " push x; ") * 500 + g + " filter-branch --index-filter x"
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "gf-hatch500"})
for py in sys.argv[2:]:
    t0 = time.monotonic()
    p = subprocess.run([py, sys.argv[1]], input=payload.encode(), capture_output=True, timeout=30)
    elapsed = time.monotonic() - t0
    print(py, "exit", p.returncode, "in", round(elapsed, 2), "s", p.stderr.decode()[:60])
    if p.returncode != 2 or elapsed >= 1.5 or b"filter-branch" not in p.stderr:
        sys.exit(1)
' "$TMPSCRIPTS/cast-pretool-dispatch.py" python3 $( [[ -x /usr/bin/python3 ]] && echo /usr/bin/python3 )
    assert_success
}

# Security round 2 (HIGH-1): `g\<newline>it` IS git to bash, but the timeout-path naming test saw
# `g it` -- and five 195 KB segments of it (each under the 200 KB per-segment cap) made the guard
# time out (shlex is quadratic per long token), so the raw push at the end was ALLOWED (rc 0 at
# 2.5-3.5 s). Now the bytes handed to shlex are capped cumulatively (the guard refuses up front)
# AND the timeout-path naming test sees through continuations. Built with json.dumps.
@test "real guards + 5 and 8 continuation-spelled git segments of 195 KB then a raw push → blocked (2) in < 4.5 s" {
    run python3 -c '
import json, subprocess, sys, time
for k in (5, 8):
    cmd = ";".join(("g\\\nit" + "x" * 195000) for _ in range(k)) + ";g\\\nit push origin main"
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "gf-high1"})
    for py in sys.argv[2:]:
        t0 = time.monotonic()
        try:
            p = subprocess.run([py, sys.argv[1]], input=payload.encode(), capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            print("TIMEOUT (> 30 s)"); sys.exit(1)
        elapsed = time.monotonic() - t0
        print("k =", k, py, "exit", p.returncode, "in", round(elapsed, 2), "s", p.stderr.decode()[:70])
        if p.returncode != 2 or elapsed >= 4.5:
            sys.exit(1)
' "$TMPSCRIPTS/cast-pretool-dispatch.py" python3 $( [[ -x /usr/bin/python3 ]] && echo /usr/bin/python3 )
    assert_success
}

# Security round 1 (M3): cast-command-guard.py (rm -rf / pkill) runs AFTER the git guard allows and
# was unwatched, so ~1 MB of padding made it outrun the 5 s hook timeout (= ALLOW). It now gets the
# remaining share of a 3.5 s total Bash-guard budget and BLOCKS on expiry.
break_command_guard_slow() {
    printf 'import time\ndef safe_is_blocked(c):\n    try:\n        time.sleep(10)\n    except Exception:\n        pass\n    return False, ""\ndef write_log(*a, **k):\n    pass\n' \
        > "$TMPSCRIPTS/cast-command-guard.py"
}

@test "slow command guard + Bash → blocked (2) with its own message within 4.5 s, never allowed" {
    break_command_guard_slow
    run slow_guard_dispatch python3 "echo hello" 2 "The command guard could not finish checking this command in time" 4.5
    assert_success
    if [[ -x /usr/bin/python3 ]]; then
        run slow_guard_dispatch /usr/bin/python3 "echo hello" 2 "The command guard could not finish checking this command in time" 4.5
        assert_success
    fi
}

@test "real guards + 1.2 MB non-git command ending in a catastrophic rm → decided (2) in < 4.5 s" {
    run python3 -c '
import json, subprocess, sys, time
cmd = "a;" * 600000 + "rm -rf /"
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "gf-1mb"})
for py in sys.argv[2:]:
    t0 = time.monotonic()
    try:
        p = subprocess.run([py, sys.argv[1]], input=payload.encode(), capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        print("TIMEOUT (> 30 s)"); sys.exit(1)
    elapsed = time.monotonic() - t0
    print(py, "exit", p.returncode, "in", round(elapsed, 2), "s", p.stderr.decode()[:70])
    if p.returncode != 2 or elapsed >= 4.5:
        sys.exit(1)
' "$TMPSCRIPTS/cast-pretool-dispatch.py" python3 $( [[ -x /usr/bin/python3 ]] && echo /usr/bin/python3 )
    assert_success
}

# Unparseable Write payload (a REAL RecursionError from 200000-deep nesting in an extra
# tool_input key, as tests/test_cast_git_guard_fail_closed.py builds it) + broken guard.
deep_write_payload_file() {
    python3 -c "
import sys
n = 200000
sys.stdout.write('{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/home/u/secret-x\",\"zz\":'
                 + '[' * n + ']' * n + '}}')
" > "$BATS_TEST_TMPDIR/deep-write.json"
}

@test "broken guard + unparseable Write payload → blocked (2) with the load-failure reason" {
    break_git_guard
    deep_write_payload_file
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" < "$BATS_TEST_TMPDIR/deep-write.json"
    assert_failure 2
    assert_output --partial "failed to load"
    assert_output --partial "CAST_POLICY_OVERRIDE"
    refute_output --partial "secret-x"
    refute_output --partial "[[[["
}

@test "broken guard + unparseable Write payload + CAST_POLICY_OVERRIDE=1 → allowed, override line logged" {
    break_git_guard
    deep_write_payload_file
    export CAST_POLICY_OVERRIDE=1
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" < "$BATS_TEST_TMPDIR/deep-write.json"
    assert_success
    run grep -c "override used while guard unavailable" "$HOME/.claude/logs/hook-errors.log"
    assert_output "1"
    run grep -c "secret-x" "$HOME/.claude/logs/hook-errors.log"
    assert_output "0"
}

# ---------------------------------------------------------------------------
# Security round 1: the degraded scan covers the WHOLE command (no segmentation), is
# case-insensitive, sees through quoting/NUL/redirect glue, and never goes quadratic.
# A hook TIMEOUT is a non-blocking error (= allow), so "slow" is a bypass.
# ---------------------------------------------------------------------------

# bash_literal_exit <expected> <python string literal>: for commands that cannot travel
# through argv (a NUL byte); the literal is parsed with ast.literal_eval.
bash_literal_exit() {
    local expected="$1" payload
    payload="$(python3 -c '
import ast, json, sys
print(json.dumps({"tool_name": "Bash", "session_id": "gf-degraded",
                  "tool_input": {"command": ast.literal_eval(sys.argv[1])}}))
' "$2")"
    run_dispatch "$payload"
    if [ "$status" -ne "$expected" ]; then
        echo "literal [$2] exited $status, wanted $expected: $output" >&2
        return 1
    fi
}

@test "broken guard + Bash → a separator INSIDE a git argument cannot hide the verb" {
    break_git_guard
    local c
    for c in \
        'git -C "$(pwd)" push' \
        'git -C "$(git rev-parse --show-toplevel)" commit -m x' \
        'git -C `pwd` push' \
        'git -c user.name="Ed (K)" commit -m x' \
        'git -c http.extraHeader="X: a&b" push' \
        'git -C "a;b" reset --hard' \
        'git -C "a|b" stash'; do
        bash_exit 2 "$c"
    done
}

@test "broken guard + Bash → case, quoting, redirect and IFS glue cannot hide the verb" {
    break_git_guard
    local c
    for c in \
        'GIT push' \
        'Git COMMIT -m x' \
        '/USR/BIN/Git push' \
        "\$'git' push" \
        '$"git" push' \
        "g\$'it' push" \
        'git push</dev/null' \
        'git commit>/dev/null -m x' \
        'git${IFS}push'; do
        bash_exit 2 "$c"
    done
    bash_literal_exit 2 '"git push\x00"'
    bash_literal_exit 2 '"git\x00push"'
    bash_literal_exit 2 '"g\x00it push"'
    bash_literal_exit 0 '"git status\x00"'
}

@test "broken guard + Bash → branch force-delete over the whole command, d alone still allowed" {
    break_git_guard
    bash_exit 2 'git branch -D foo'
    bash_exit 2 'git branch -d foo && make -f x'
    bash_exit 0 'git branch -d foo'
    bash_exit 0 'git branch -d foo && ls -la'
}

# time_big_dispatch <interpreter>: a 900 KB command of 100000 `git push;` repeats with the
# push hatch at the END, then a reset (no hatch) -> must block, in < 2 s. A per-match hatch
# scan is O(matches x len) (10.8 s on /usr/bin/python3 3.9) and a hook TIMEOUT = allow; the
# hatch at the START of the command would NOT expose that, so it stays at the end.
time_big_dispatch() {
    python3 -c '
import json, subprocess, sys, time
cmd = "git push;" * 100000 + "CAST_PUSH_OK=1;" + "git reset --hard"
assert len(cmd) > 900000
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "gf-big2"})
t0 = time.monotonic()
try:
    p = subprocess.run([sys.argv[2], sys.argv[1]], input=payload.encode(), capture_output=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT (> 30 s)")
    sys.exit(1)
elapsed = time.monotonic() - t0
print(sys.argv[2], "exit", p.returncode, "in", round(elapsed, 2), "s")
sys.exit(0 if p.returncode == 2 and elapsed < 2.0 else 1)
' "$TMPSCRIPTS/cast-pretool-dispatch.py" "$1"
}

# Run under the default python3 and, when present, /usr/bin/python3 (3.9 on macOS -- the
# interpreter a hook's bare `python3` can resolve to). No skip: an absent system python is
# simply not exercised (a new skip call site would also need a skip-ledger entry).
@test "broken guard + 900 KB command of 100000 matches, hatch at the END → blocked in < 2 s" {
    break_git_guard
    run time_big_dispatch python3
    assert_success
    if [[ -x /usr/bin/python3 ]]; then
        run time_big_dispatch /usr/bin/python3
        assert_success
    fi
}

# Unparseable Bash payload: a REAL RecursionError from 200000-deep nesting in an extra
# tool_input key. Neither git guard ran, so the raw text gets the degraded scan -- in
# healthy mode too. deep_bash_payload_file <command> [extra top-level JSON text].
deep_bash_payload_file() {
    python3 -c '
import json, sys
n = 200000
extra = sys.argv[2] if len(sys.argv) > 2 else ""
sys.stdout.write("{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":" + json.dumps(sys.argv[1])
                 + ",\"zz\":" + "[" * n + "]" * n + "}" + extra + "}")
' "$@" > "$BATS_TEST_TMPDIR/deep-bash.json"
}

dispatch_deep_bash() {
    run python3 "$TMPSCRIPTS/cast-pretool-dispatch.py" < "$BATS_TEST_TMPDIR/deep-bash.json"
}

@test "unparseable Bash payload + git push → blocked (2) in degraded mode" {
    break_git_guard
    deep_bash_payload_file 'git push'
    dispatch_deep_bash
    assert_failure 2
    assert_output --partial "git push is blocked in degraded mode"
    assert_output --partial "unparseable payload"
    assert_output --partial "CAST_PUSH_OK=1"
}

@test "unparseable Bash payload + git push → blocked (2) in HEALTHY mode too" {
    deep_bash_payload_file 'git push'
    dispatch_deep_bash
    assert_failure 2
    assert_output --partial "git push is blocked in degraded mode"
}

@test "unparseable Bash payload → git status allowed (0), the verb's hatch allows git push" {
    deep_bash_payload_file 'git status'
    dispatch_deep_bash
    assert_success
    deep_bash_payload_file 'CAST_PUSH_OK=1 git push'
    dispatch_deep_bash
    assert_success
}

@test "unparseable Bash payload → a JSON-escaped newline cannot glue the verb to its neighbour" {
    deep_bash_payload_file $'echo hi\ngit push\nls'
    grep -q 'hi\\ngit push\\nls' "$BATS_TEST_TMPDIR/deep-bash.json"
    dispatch_deep_bash
    assert_failure 2
}

@test "unparseable Bash payload + git push → blocked alone: exit 2, NOTHING on stdout (no Neon ask)" {
    # The raw text also names a Neon tool, which would normally print an ask object.
    deep_bash_payload_file 'git push' ',"tool_name": "mcp__neon__run_sql"'
    run bash -c 'python3 "$0" < "$1" 2>/dev/null' \
        "$TMPSCRIPTS/cast-pretool-dispatch.py" "$BATS_TEST_TMPDIR/deep-bash.json"
    assert_failure 2
    assert_output ""
}

@test "unparseable Bash payload under CLAUDE_SUBPROCESS=1 → still blocked (every context)" {
    export CLAUDE_SUBPROCESS=1
    deep_bash_payload_file 'git push'
    dispatch_deep_bash
    assert_failure 2
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
