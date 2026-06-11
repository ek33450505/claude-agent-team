#!/usr/bin/env bats
# tests/scripts/cast-session-start-hook.bats
# Phase 16 addition tests for cast-session-start-hook.sh:
#   stack banner (CAST_STACK_PROFILE) + preference banner (feedback_*.md).
# All tests use isolated temp HOME — never touch real $HOME or the repo.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-session-start-hook.sh"

make_payload() {
    local session_id="${1:-test-sess-001}"
    local cwd="${2:-/tmp/test-project}"
    python3 -c "
import json, sys
print(json.dumps({'hook_event_name':'SessionStart','session_id':sys.argv[1],'cwd':sys.argv[2]}))
" "$session_id" "$cwd"
}

setup() {
    FAKE_HOME="$BATS_TEST_TMPDIR/fake-home"
    mkdir -p "$FAKE_HOME/.claude/cast"
    export HOME="$FAKE_HOME"
    unset CLAUDE_SUBPROCESS
    unset CAST_STACK_PROFILE
    unset CLAUDE_ENV_FILE
    unset OTEL_EXPORTER_OTLP_ENDPOINT
}

teardown() {
    unset HOME CLAUDE_SUBPROCESS CAST_STACK_PROFILE CLAUDE_ENV_FILE OTEL_EXPORTER_OTLP_ENDPOINT
}

# ── Test 1: No stack profile, no feedback memories → no Phase 16 output ───────
@test "no stack profile and no feedback memories → no systemMessage emitted" {
    # FAKE_HOME has no .claude/projects/ at all
    run bash "$HOOK_SH" <<< "$(make_payload)"
    [ "$status" -eq 0 ]

    # stdout must not contain a JSON object with systemMessage
    OUT="$output" python3 << 'PY'
import json, os, sys
raw = os.environ.get("OUT", "").strip()
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if "systemMessage" in d:
            print("FAIL: unexpected systemMessage: " + d["systemMessage"])
            sys.exit(1)
    except Exception:
        pass
print("ok")
PY
}

# ── Test 2: Stack profile present → banner contains "Stack:" ──────────────────
@test "CAST_STACK_PROFILE set → systemMessage contains Stack:" {
    CAST_STACK_PROFILE='{"fw":"vite-react","test_cmd":"bash tests/run.sh","build_cmd":"vite build"}' \
        run bash "$HOOK_SH" <<< "$(make_payload)"
    [ "$status" -eq 0 ]

    OUT="$output" python3 << 'PY'
import json, os, sys
raw = os.environ.get("OUT", "").strip()
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if "systemMessage" in d:
            sm = d["systemMessage"]
            assert "Stack:" in sm, "Stack: not in systemMessage: " + sm
            assert "vite-react" in sm, "fw missing from systemMessage: " + sm
            print("ok")
            sys.exit(0)
    except Exception:
        pass
print("FAIL: no systemMessage found in output")
sys.exit(1)
PY
}

# ── Test 3: 5 feedback files → only top-3 slugs, total ≤ 500 chars ────────────
@test "5 feedback files → only top-3 by mtime appear, total chars ≤ 500" {
    local proj="$FAKE_HOME/.claude/projects/test-proj/memory"
    mkdir -p "$proj"

    # Create 5 feedback files with long-enough bodies (> 30 chars each)
    for i in 1 2 3 4 5; do
        printf "This is a sufficiently long feedback body for preference number %d used in Phase16 test.\n" \
            "$i" > "$proj/feedback_pref${i}.md"
    done

    # Set distinct mtimes via Python: pref1=100s, pref2=200s, ..., pref5=500s (Unix epoch)
    # Top-3 by mtime descending: pref5 (500), pref4 (400), pref3 (300)
    python3 -c "
import os
base = '${proj}'
names = ['feedback_pref1.md','feedback_pref2.md','feedback_pref3.md','feedback_pref4.md','feedback_pref5.md']
for i, name in enumerate(names):
    t = (i + 1) * 100.0
    os.utime(os.path.join(base, name), (t, t))
"

    run bash "$HOOK_SH" <<< "$(make_payload)"
    [ "$status" -eq 0 ]

    OUT="$output" python3 << 'PY'
import json, os, re, sys
raw = os.environ.get("OUT", "").strip()
sm = None
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if "systemMessage" in d:
            sm = d["systemMessage"]
            break
    except Exception:
        pass

if sm is None:
    print("FAIL: no systemMessage in output")
    sys.exit(1)

slugs = re.findall(r'\[from: ([^\]]+)\]', sm)
assert len(slugs) == 3, "Expected 3 slugs, got " + str(len(slugs)) + ": " + str(slugs)

# pref5 (mtime 500) and pref4 (400) and pref3 (300) should be present
assert "feedback_pref5" in slugs, "Expected pref5 in top-3: " + str(slugs)
assert "feedback_pref4" in slugs, "Expected pref4 in top-3: " + str(slugs)
assert "feedback_pref3" in slugs, "Expected pref3 in top-3: " + str(slugs)
assert "feedback_pref1" not in slugs, "pref1 should NOT be in top-3: " + str(slugs)
assert "feedback_pref2" not in slugs, "pref2 should NOT be in top-3: " + str(slugs)

total = len(sm)
assert total <= 500, "Total chars " + str(total) + " exceeds 500-char cap"
print("ok — slugs: " + str(slugs) + ", chars: " + str(total))
PY
}

# ── Test 4: Feedback file with body < 30 chars is skipped ─────────────────────
@test "feedback file with body < 30 chars is skipped (abstention rule)" {
    local proj="$FAKE_HOME/.claude/projects/test-proj/memory"
    mkdir -p "$proj"

    # Body is 15 chars — under the 30-char abstention threshold
    printf "Too short body." > "$proj/feedback_short.md"

    # No stack profile, only a short-body feedback file → nothing to emit
    run bash "$HOOK_SH" <<< "$(make_payload)"
    [ "$status" -eq 0 ]

    OUT="$output" python3 << 'PY'
import json, os, sys
raw = os.environ.get("OUT", "").strip()
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if "systemMessage" in d:
            print("FAIL: got systemMessage from short-body feedback: " + d["systemMessage"])
            sys.exit(1)
    except Exception:
        pass
print("ok")
PY
}
