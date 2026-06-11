#!/usr/bin/env bats
# cast-ci-watch.bats — tests for scripts/cast-ci-watch.sh
# All tests use an isolated temp HOME for the state dir.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-ci-watch.sh"

# ---------------------------------------------------------------------------
# Stub gh binary — written per-test suite into $TEST_TMPDIR/stub-gh
# ---------------------------------------------------------------------------

# We write a single standalone stub script and set CAST_CI_WATCH_GH_CMD to it.
# Each test sets GH_STUB_MODE to control what the stub emits.

setup() {
  load 'helpers/setup'
  setup_temp_home   # isolates ~/.claude/cast/ci-watch/ to a temp HOME

  export TEST_TMPDIR
  TEST_TMPDIR="$(mktemp -d /tmp/cast-ci-watch-test.XXXXXXXX)"
  export STUB_GH="$TEST_TMPDIR/stub-gh"
  export CAST_CI_WATCH_GH_CMD="$STUB_GH"

  cat > "$STUB_GH" << 'STUBEOF'
#!/bin/bash
# Stub gh — branches on GH_STUB_MODE
# Handles: probe call (--json number), full call (--json mergeable,...),
#          repo view, and api graphql.

MODE="${GH_STUB_MODE:-green}"

# Detect if this is the probe call (--json number only)
is_probe=false
for arg in "$@"; do
  if [[ "$arg" == "number" ]]; then
    is_probe=true
    break
  fi
done

case "$1" in
  pr)
    case "$2" in
      view)
        case "$MODE" in
          no_pr)
            # Simulate "no PR" — exit non-zero, empty stdout, "no pull request" to stderr
            echo "no pull requests found for branch" >&2
            exit 1
            ;;
          gh_error)
            # Transient error — exit non-zero with non-empty stderr
            echo "error connecting to github.com: timeout" >&2
            exit 1
            ;;
        esac
        # Regression guard: reviewThreads was dropped from the gh pr view call.
        # If anyone re-adds it, real gh rejects it — this stub enforces the same.
        for arg in "$@"; do
          if [[ "$arg" == *"reviewThreads"* ]]; then
            echo 'Unknown JSON field: "reviewThreads"' >&2
            exit 1
          fi
        done
        # For all non-error modes: probe returns just {number} or full JSON
        if $is_probe; then
          echo '{"number":42}'
        else
          case "$MODE" in
            green | graphql_error)
              echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED","name":"ci/test"},{"conclusion":"SUCCESS","status":"COMPLETED","name":"ci/lint"}]}'
              ;;
            pending)
              echo '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS","name":"ci/test"},{"conclusion":"SUCCESS","status":"COMPLETED","name":"ci/lint"}]}'
              ;;
            unresolved)
              # green checks; unresolved thread count comes from the api/graphql branch below
              echo '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED","name":"ci/test"}]}'
              ;;
            conflicting)
              # green checks, 0 unresolved threads, but CONFLICTING
              echo '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED","name":"ci/test"}]}'
              ;;
            failed)
              echo '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED","name":"ci/test"},{"conclusion":"SUCCESS","status":"COMPLETED","name":"ci/lint"}]}'
              ;;
            merge_state_blocked)
              # green checks + 0 threads + MERGEABLE but mergeStateStatus=BLOCKED (branch protection)
              echo '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED","name":"ci/test"}]}'
              ;;
            malformed_json)
              # Return unparseable output to exercise the parse-status PARSE_ERROR path
              echo 'not valid json {incomplete'
              ;;
          esac
        fi
        ;;
      merge)
        echo '{"merged":true}'
        ;;
    esac
    ;;
  repo)
    # gh repo view --json owner,name
    echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
    ;;
  api)
    # gh api graphql — mode-aware thread response
    case "$MODE" in
      graphql_error)
        echo "error: GraphQL request failed" >&2
        exit 1
        ;;
      unresolved)
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false}]}}}}}'
        ;;
      *)
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        ;;
    esac
    ;;
esac
STUBEOF
  chmod +x "$STUB_GH"
}

teardown() {
  teardown_temp_home
  [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper: check JSON field value using python3
# ---------------------------------------------------------------------------
_json_field() {
  local json="$1" field="$2"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('${field}',''))" "$json"
}

# ---------------------------------------------------------------------------
# start: writes state file on first call
# ---------------------------------------------------------------------------

@test "start: creates state file and returns started=true" {
  run bash "$SCRIPT" start 42
  assert_success
  local started
  started="$(_json_field "$output" started)"
  [ "$started" = "True" ]
  # State file must exist
  [ -f "$HOME/.claude/cast/ci-watch/42.json" ]
}

# ---------------------------------------------------------------------------
# start: refuses a second concurrent loop (deadline still in future)
# ---------------------------------------------------------------------------

@test "start: refuses second start while loop is active" {
  # First start
  run bash "$SCRIPT" start 42
  assert_success

  # Second start immediately (deadline is still in future)
  run bash "$SCRIPT" start 42
  assert_success
  local started
  started="$(_json_field "$output" started)"
  [ "$started" = "False" ]
  local reason
  reason="$(_json_field "$output" reason)"
  [ "$reason" = "loop already running" ]
}

# ---------------------------------------------------------------------------
# status → MERGE (green + 0 threads + MERGEABLE)
# ---------------------------------------------------------------------------

@test "status: returns MERGE when green + 0 threads + MERGEABLE" {
  export GH_STUB_MODE="green"
  # Write a state file with a future deadline
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "MERGE" ]
  local checks
  checks="$(_json_field "$output" checks)"
  [ "$checks" = "green" ]
}

# ---------------------------------------------------------------------------
# status → WAIT (pending checks)
# ---------------------------------------------------------------------------

@test "status: returns WAIT when checks are pending" {
  export GH_STUB_MODE="pending"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "WAIT" ]
  local checks
  checks="$(_json_field "$output" checks)"
  [ "$checks" = "pending" ]
}

# ---------------------------------------------------------------------------
# status → WAIT (green but unresolved_threads > 0)
# ---------------------------------------------------------------------------

@test "status: returns WAIT when green but unresolved review threads exist" {
  export GH_STUB_MODE="unresolved"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "WAIT" ]
}

# ---------------------------------------------------------------------------
# status → WAIT (green + 0 threads but CONFLICTING)
# ---------------------------------------------------------------------------

@test "status: returns WAIT when green + 0 threads but mergeable=CONFLICTING" {
  export GH_STUB_MODE="conflicting"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "WAIT" ]
  local mergeable
  mergeable="$(_json_field "$output" mergeable)"
  [ "$mergeable" = "CONFLICTING" ]
}

# ---------------------------------------------------------------------------
# status → FAIL (a check with FAILURE conclusion)
# ---------------------------------------------------------------------------

@test "status: returns FAIL when a check has FAILURE conclusion" {
  export GH_STUB_MODE="failed"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "FAIL" ]
  local checks
  checks="$(_json_field "$output" checks)"
  [ "$checks" = "failed" ]
}

# ---------------------------------------------------------------------------
# status → EXPIRED (state file with deadline in the past)
# ---------------------------------------------------------------------------

@test "status: returns EXPIRED when deadline is in the past" {
  export GH_STUB_MODE="green"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local past=$(( $(date +%s) - 100 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${past}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "EXPIRED" ]
}

# ---------------------------------------------------------------------------
# status → NO_PR (stub simulates no PR / gh exits non-zero)
# ---------------------------------------------------------------------------

@test "status: returns NO_PR when gh reports no PR" {
  export GH_STUB_MODE="no_pr"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 99, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/99.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 99
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "NO_PR" ]
}

# ---------------------------------------------------------------------------
# gh probe error → ERROR (transient failure must NOT produce FAIL or WAIT)
# ---------------------------------------------------------------------------

@test "status: returns ERROR on transient gh probe failure (never FAIL)" {
  export GH_STUB_MODE="gh_error"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "ERROR" ]
}

# ---------------------------------------------------------------------------
# status → WAIT (green + 0 threads + MERGEABLE but mergeStateStatus=BLOCKED)
# ---------------------------------------------------------------------------

@test "status: returns WAIT when mergeStateStatus=BLOCKED despite green checks and MERGEABLE" {
  export GH_STUB_MODE="merge_state_blocked"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "WAIT" ]
  # merge_state must be BLOCKED in the output
  local merge_state
  merge_state="$(_json_field "$output" merge_state)"
  [ "$merge_state" = "BLOCKED" ]
}

# ---------------------------------------------------------------------------
# non-numeric PR arg → error JSON, exit 0
# ---------------------------------------------------------------------------

@test "status: non-numeric PR arg emits error JSON and exits 0" {
  run bash "$SCRIPT" status abc
  assert_success
  [[ "$output" == *'"error"'* ]]
  [[ "$output" == *'numeric'* ]]
}

# ---------------------------------------------------------------------------
# stop: removes state file (idempotent)
# ---------------------------------------------------------------------------

@test "stop: removes state file and returns stopped=true" {
  # create a state file
  bash "$SCRIPT" start 42 > /dev/null
  [ -f "$HOME/.claude/cast/ci-watch/42.json" ]

  run bash "$SCRIPT" stop 42
  assert_success
  local stopped
  stopped="$(_json_field "$output" stopped)"
  [ "$stopped" = "True" ]
  [ ! -f "$HOME/.claude/cast/ci-watch/42.json" ]
}

@test "stop: idempotent when state file is absent" {
  run bash "$SCRIPT" stop 999
  assert_success
  local stopped
  stopped="$(_json_field "$output" stopped)"
  [ "$stopped" = "True" ]
}

# ---------------------------------------------------------------------------
# GraphQL api call fails → verdict ERROR with error code
# ---------------------------------------------------------------------------

@test "status: returns ERROR when GraphQL api call fails" {
  export GH_STUB_MODE="graphql_error"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "ERROR" ]
}

# ---------------------------------------------------------------------------
# Full fetch returns malformed JSON → verdict ERROR (never "pending" swallow)
# ---------------------------------------------------------------------------

@test "status: returns ERROR (not pending) when full fetch returns malformed JSON" {
  export GH_STUB_MODE="malformed_json"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local verdict
  verdict="$(_json_field "$output" verdict)"
  [ "$verdict" = "ERROR" ]
}

# ---------------------------------------------------------------------------
# ERROR JSON shape must contain an 'error' field with a non-empty reason code
# ---------------------------------------------------------------------------

@test "status: ERROR verdict JSON contains an 'error' field with a reason code" {
  export GH_STUB_MODE="graphql_error"
  mkdir -p "$HOME/.claude/cast/ci-watch"
  local future=$(( $(date +%s) + 5000 ))
  python3 -c "
import json
d = {'pr': 42, 'start_epoch': $(date +%s), 'deadline_epoch': ${future}}
with open('$HOME/.claude/cast/ci-watch/42.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$SCRIPT" status 42
  assert_success
  local error_field
  error_field="$(_json_field "$output" error)"
  [ -n "$error_field" ]
}
